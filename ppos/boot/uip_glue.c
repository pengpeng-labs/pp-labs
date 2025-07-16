/* uip_glue.c：uIP 胶水层——连接 pp-os（e1000/应用）与 uIP 协议栈。
   pp 侧调用：
     uip_glue_init()         初始化 uIP + 配置本机 IP/MAC
     uip_glue_connect(ip,port)  发起 TCP 连接（返回 0 开始）
     uip_glue_send(buf,len)  发送数据（经 uip_send）
     uip_glue_poll()         主轮询：收帧喂 uIP + 驱动周期 + 发送输出帧
                             （每次调用处理一帧或一个周期，返回 1 有事件）
     uip_glue_recv(buf,cap)  取接收缓冲数据（返回长度）
     uip_glue_closed()       连接是否已关闭
     uip_glue_connected()    连接是否已建立
   e1000 收发由 pp 侧提供（e1000_recv/e1000_send extern）。
   本文件是"胶水"：所有 uIP 细节（重传/窗口/MSS/状态机）由 uip.c 处理。 */

#include <stdint.h>
#include <string.h>
#include "uip.h"
#include "uip_arp.h"

/* ---- pp 侧提供的函数（链接时解析） ---- */
extern int pp_e1000_recv(uint8_t *dst);   /* 返回帧长，0=无帧 */
extern void pp_e1000_send(uint8_t *buf, int len);
extern void pp_udp_frame(uint8_t *buf, int len);   /* UDP 帧暂存（DNS） */

/* ---- 本机配置（pp 侧设置） ---- */
static uint8_t my_ip[4] = {10, 0, 2, 15};
static uint8_t my_mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};

/* ---- 接收字节流缓冲（uIP 数据到达 → 这里，pp 读走） ---- */
#define RXBUF_CAP 16384
static uint8_t rxbuf[RXBUF_CAP];
static int rxbuf_head = 0;   /* 写入位置 */
static int rxbuf_tail = 0;   /* 读取位置 */
static int rxbuf_full = 0;

/* ---- 连接状态跟踪 ---- */
static volatile int conn_established = 0;
static volatile int conn_closed = 0;
static volatile int conn_timedout = 0;

/* TCP 发送缓冲（uIP 模型：数据在 appcall 的 POLL 里 uip_send） */
static uint8_t tcp_pending[2048];
static int tcp_pending_len = 0;

/* DNS 发送缓冲（UDP appcall 里 uip_send） */
static uint8_t dns_pending[512];
static int dns_pending_len = 0;

/* 应用层回调（UIP_APPCALL 宏被 uip.h 展开调用） */
void uip_appcall(void)
{
    if (uip_connected()) {
        conn_established = 1;
    }
    if (uip_aborted() || uip_closed() || uip_timedout()) {
        conn_closed = 1;
        if (uip_timedout()) {
            conn_timedout = 1;
        }
    }
    /* 新数据：从 uip_appdata 拷到接收缓冲 */
    if (uip_newdata()) {
        int n = uip_datalen();
        if (n > 0 && n <= (int)sizeof(rxbuf)) {
            int space = rxbuf_full ? 0 : (int)sizeof(rxbuf) - rxbuf_head;
            if (n > space) {
                n = space;   /* 截断（不会发生：窗口 ≤ 缓冲） */
            }
            memcpy(&rxbuf[rxbuf_head], uip_appdata, n);
            rxbuf_head += n;
            if (rxbuf_head >= (int)sizeof(rxbuf)) {
                rxbuf_head = 0;
            }
            if (rxbuf_head == rxbuf_tail) {
                rxbuf_full = 1;
            }
        }
    }
    /* UIP_POLL（周期/可发送）：发出待发 TCP 数据 */
    if (uip_poll() && tcp_pending_len > 0) {
        uip_send(tcp_pending, tcp_pending_len);
        tcp_pending_len = 0;
    }
}

void uip_glue_init(void)
{
    struct uip_eth_addr ea;
    uip_init();
    uip_arp_init();
    ea.addr[0] = my_mac[0]; ea.addr[1] = my_mac[1];
    ea.addr[2] = my_mac[2]; ea.addr[3] = my_mac[3];
    ea.addr[4] = my_mac[4]; ea.addr[5] = my_mac[5];
    uip_setethaddr(ea);
    uip_sethostaddr(my_ip);
    rxbuf_head = rxbuf_tail = 0;
    rxbuf_full = 0;
    conn_established = conn_closed = conn_timedout = 0;
}

void uip_glue_set_ip(int b0, int b1, int b2, int b3)
{
    my_ip[0] = b0; my_ip[1] = b1; my_ip[2] = b2; my_ip[3] = b3;
    uip_sethostaddr(my_ip);
}

/* 发起连接：ip 指向 4 字节 IP（大端网络序转 uIP 格式） */
int uip_glue_connect(uint8_t *ip, uint16_t port)
{
    uip_ipaddr_t a;
    uip_ipaddr(&a, ip[0], ip[1], ip[2], ip[3]);
    conn_established = conn_closed = conn_timedout = 0;
    tcp_pending_len = 0;
    dns_pending_len = 0;
    struct uip_conn *c = uip_connect(&a, htons(port));
    if (c == NULL) {
        return -1;
    }
    return 0;
}

/* 发送数据（存 pending，TCP POLL 时发出） */
int uip_glue_send(uint8_t *buf, int len)
{
    if (len > (int)sizeof(tcp_pending)) {
        len = sizeof(tcp_pending);
    }
    memcpy(tcp_pending, buf, len);
    tcp_pending_len = len;
    return len;
}

/* 取接收数据，返回长度 */
int uip_glue_recv(uint8_t *buf, int cap)
{
    int n = 0;
    while (n < cap && !(rxbuf_head == rxbuf_tail && !rxbuf_full)) {
        buf[n++] = rxbuf[rxbuf_tail++];
        if (rxbuf_tail >= (int)sizeof(rxbuf)) {
            rxbuf_tail = 0;
        }
        rxbuf_full = 0;
    }
    return n;
}

int uip_glue_closed(void)
{
    return conn_closed;
}

int uip_glue_connected(void)
{
    return conn_established;
}

int uip_glue_timedout(void)
{
    return conn_timedout;
}

/* UDP 应用回调（DNS 响应 + 发送请求）：uIP 周期/UDP 数据到达时调用 */
void uip_udp_appcall(void)
{
    if (uip_newdata()) {
        int n = uip_datalen();
        extern void pp_dns_recv(uint8_t *buf, int len);
        if (n > 0) {
            pp_dns_recv(uip_appdata, n);
        }
    }
    /* UIP_POLL（周期）：发送待发 DNS 查询——若被 ARP drop（uip_len 变 0）则保留下轮重试 */
    if (uip_poll() && dns_pending_len > 0) {
        uip_send(dns_pending, dns_pending_len);
        if (uip_len > 0) {
            dns_pending_len = 0;
        }
    }
}

/* DNS 查询：数据存 pending，UDP 周期时发出（经 uIP UDP 到 10.0.2.3:53） */
int uip_glue_dns_send(uint8_t *buf, int len)
{

    uip_ipaddr_t dnsip;
    static struct uip_udp_conn *dns_conn = NULL;
    uip_ipaddr(&dnsip, 10, 0, 2, 3);
    if (dns_conn == NULL) {
        dns_conn = uip_udp_new(&dnsip, HTONS(53));
        if (dns_conn == NULL) {
            return -1;
        }
    }
    uip_udp_bind(dns_conn, HTONS(12345));
    if (len > (int)sizeof(dns_pending)) {
        len = sizeof(dns_pending);
    }
    memcpy(dns_pending, buf, len);
    dns_pending_len = len;
    return 0;
}

/* 主轮询（uIP unix 示例 main.c 模板）：
   1. 收帧 → 按以太网类型分类：IP 帧 arp_ipin+input，ARP 帧 arpin
   2. 周期定时（0.5s）→ uip_periodic（TCP 重传）+ uip_udp_periodic
   3. ARP 老化（10s）→ uip_arp_timer
   返回 1 = 有事件 */
int uip_glue_poll(void)
{
    static uint8_t frame[1600];
    int handled = 0;
    extern uint32_t pp_ticks(void);
    static uint32_t last_periodic = 0;
    static uint32_t last_arp = 0;
    uint32_t now = pp_ticks() / 100;   /* 秒 */

    /* 1. 收帧 → uIP */
    int len = pp_e1000_recv(frame);
    if (len > 0) {
        if (len > (int)sizeof(uip_buf)) {
            len = sizeof(uip_buf);
        }
        memcpy(uip_buf, frame, len);
        uip_len = len;
        if (frame[12] == 0x08 && frame[13] == 0x00) {
            /* IPv4 帧 */
            uip_arp_ipin();
            if (uip_len > 0) {
                uip_input();
                if (uip_len > 0) {
                    uip_arp_out();
                    if (uip_len > 0) {
                        pp_e1000_send(uip_buf, uip_len);
                    }
                }
            }
        } else if (frame[12] == 0x08 && frame[13] == 0x06) {
            /* ARP 帧 */
            uip_arp_arpin();
            if (uip_len > 0) {
                pp_e1000_send(uip_buf, uip_len);
            }
        }
        handled = 1;
    }

    /* 2. 周期驱动（0.5s 节拍，uIP 重传/RTO 依赖此节拍） */
    if (now - last_periodic >= 1 || (last_periodic == 0 && now >= 1)) {
        last_periodic = now;
        extern void pp_dbg(const char *s);
        pp_dbg("[g]tick ");
        int i;
        for (i = 0; i < UIP_CONNS; ++i) {
            if (uip_conn_active(i)) {
                uip_periodic(i);
                if (uip_len > 0) {
                    uip_arp_out();
                    if (uip_len > 0) {
                        pp_e1000_send(uip_buf, uip_len);
                    }
                }
                handled = 1;
            }
        }
#if UIP_UDP
        for (i = 0; i < UIP_UDP_CONNS; ++i) {
            if (uip_udp_conns[i].rport != 0) {
                uip_udp_periodic(i);
                if (uip_len > 0) {
                    uip_arp_out();
                    if (uip_len > 0) {
                        pp_e1000_send(uip_buf, uip_len);
                    }
                }
                handled = 1;
            }
        }
#endif
        /* 3. ARP 老化（10s） */
        if (now - last_arp >= 10 || (last_arp == 0 && now >= 10)) {
            last_arp = now;
            uip_arp_timer();
        }
    }

    return handled;
}

/* uIP 需要的时钟（周期驱动用；返回秒）——由 pp 侧 tick 提供 */
uint32_t uip_clock(void)
{
    extern uint32_t pp_ticks(void);
    return pp_ticks() / 100;   /* 100Hz tick → 秒 */
}

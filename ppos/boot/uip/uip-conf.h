/* uip-conf.h：pp-os 的 uIP 配置（UIP_CONF_* 覆盖 uipopt.h 默认值）
   - 大缓冲：MSS 1460（TLS 记录需要）
   - 主动打开（客户端）
   - 无 UDP（DNS 仍用手写 net.pp）
   - 类型定义：u8_t/u16_t 等（原由平台 uip-conf.h 提供） */

#ifndef __UIP_CONF_H__
#define __UIP_CONF_H__

#include <stdint.h>

typedef uint8_t  u8_t;
typedef uint16_t u16_t;
typedef unsigned short uip_stats_t;

/* 应用状态（无状态——胶水层用全局缓冲） */
typedef struct { unsigned char _unused; } uip_tcp_appstate_t;
typedef struct { unsigned char _unused; } uip_udp_appstate_t;

/* 应用回调（胶水层 uip_glue.c 实现 uip_appcall / uip_udp_appcall） */
#define UIP_APPCALL uip_appcall
#define UIP_UDP_APPCALL uip_udp_appcall
void uip_appcall(void);
void uip_udp_appcall(void);

#define UIP_CONF_IPV6 0

#define UIP_CONF_BUFFER_SIZE       1526   /* 以太网 MTU 1500 + 头 */
#define UIP_CONF_RECEIVE_WINDOW    2920   /* 2 × MSS（简单窗口） */
#define UIP_CONF_MAX_CONNECTIONS   4
#define UIP_CONF_MAX_LISTENPORTS   2
#define UIP_CONF_UDP               1
#define UIP_CONF_UDP_CHECKSUMS     1
#define UIP_CONF_UDP_CONNS         2
#define UIP_CONF_LLH_LEN           14     /* 以太网头 */
#define UIP_CONF_BYTE_ORDER        UIP_LITTLE_ENDIAN
#define UIP_CONF_LOGGING           0
#define UIP_CONF_STATISTICS        0

/* 固定地址（UIP_FIXEDADDR）：本机 10.0.2.15，网关 10.0.2.2，掩码 255.255.255.0 */
#define UIP_IPADDR0   10
#define UIP_IPADDR1   0
#define UIP_IPADDR2   2
#define UIP_IPADDR3   15
#define UIP_DRIPADDR0 10
#define UIP_DRIPADDR1 0
#define UIP_DRIPADDR2 2
#define UIP_DRIPADDR3 2
#define UIP_NETMASK0  255
#define UIP_NETMASK1  255
#define UIP_NETMASK2  255
#define UIP_NETMASK3  0

#endif /* __UIP_CONF_H__ */

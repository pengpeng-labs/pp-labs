/* uip-conf.h：pp-os 的 uIP 配置（UIP_CONF_* 覆盖 uipopt.h 默认值）
   - 大缓冲：MSS 1460（TLS 记录需要）
   - 主动打开（客户端）
   - 无 UDP（DNS 仍用手写 net.pp）
   - 无时钟节拍依赖的自动周期（由 glue 显式驱动） */

#ifndef __UIP_CONF_H__
#define __UIP_CONF_H__

#define UIP_CONF_BUFFER_SIZE       1526   /* 以太网 MTU 1500 + 头 */
#define UIP_CONF_RECEIVE_WINDOW    2920   /* 2 × MSS（简单窗口） */
#define UIP_CONF_MAX_CONNECTIONS   4
#define UIP_CONF_MAX_LISTENPORTS   2
#define UIP_CONF_UDP               0
#define UIP_CONF_UDP_CHECKSUMS     0
#define UIP_CONF_LLH_LEN           14     /* 以太网头 */
#define UIP_CONF_BYTE_ORDER        UIP_LITTLE_ENDIAN
#define UIP_CONF_LOGGING           0
#define UIP_CONF_STATISTICS        0

#endif /* __UIP_CONF_H__ */

#ifndef PP_GLUE_H
#define PP_GLUE_H

#include <stdint.h>

/* Shared pp <-> C ABI. Addresses are native 64-bit pointers; sizes are int32. */
_Static_assert(sizeof(void *) == 8, "ppos glue requires a 64-bit pointer ABI");
_Static_assert(sizeof(int32_t) == 4, "ppos glue requires 32-bit lengths");

enum {
    PP_GLUE_EINVAL = -1,
    PP_GLUE_EBUSY = -2,
    PP_GLUE_EOVERFLOW = -3
};

/* Synchronous callbacks. C retains no pp-owned pointer after the call returns. */
int32_t pp_e1000_recv(uint8_t *dst, int32_t capacity);
int32_t pp_e1000_send(const uint8_t *src, int32_t length);
void pp_dns_recv(const uint8_t *src, int32_t length);
uint32_t pp_ticks(void);
void pp_dbg(const uint8_t *src, int32_t length);

/* uIP owns all returned state and copies caller buffers before returning. */
void uip_glue_init(void);
int32_t uip_glue_connect(const uint8_t *ip, int32_t port);
int32_t uip_glue_send(const uint8_t *src, int32_t length);
int32_t uip_glue_recv(uint8_t *dst, int32_t capacity);
int32_t uip_glue_dns_send(const uint8_t *src, int32_t length);
int32_t uip_glue_poll(void);
int32_t uip_glue_closed(void);
int32_t uip_glue_connected(void);
int32_t uip_glue_timedout(void);
int32_t uip_glue_last_error(void);
int32_t uip_glue_contract_selftest(void);

/* BearSSL uses one static known-key context, guarded as a single session. */
int32_t pp_tls_contract_check(int32_t sc_capacity, int32_t xc_capacity,
    int32_t io_capacity);
int32_t pp_tls_session_begin(void);
void pp_tls_session_end(void);

#endif

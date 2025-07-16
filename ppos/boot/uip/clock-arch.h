/* clock-arch.h：uIP 时钟架构实现——pp-os PIT 100Hz tick（由 glue 提供 pp_ticks） */

#ifndef __CLOCK_ARCH_H__
#define __CLOCK_ARCH_H__

#include <stdint.h>

typedef uint32_t clock_time_t;

/* PIT 100Hz：每 tick = 10ms；uIP 周期驱动粒度 */
#define CLOCK_CONF_SECOND 100

extern uint32_t pp_ticks(void);

static inline clock_time_t clock_time(void)
{
    return pp_ticks();
}

#endif /* __CLOCK_ARCH_H__ */

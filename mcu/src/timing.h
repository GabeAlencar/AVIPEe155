// timing.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Microsecond clock from TIM2 (32-bit, free running at 1 MHz).

#ifndef TIMING_H
#define TIMING_H

#include <stdint.h>

void     timing_init(void);         // call after configureClock()
uint32_t micros(void);
void     delay_ms(uint32_t ms);

#endif

// timing.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26

#include "STM32L432KC.h"
#include "timing.h"

void timing_init(void) {
    RCC->APB1ENR1 |= RCC_APB1ENR1_TIM2EN;
    TIM2->PSC = SystemCoreClock / 1000000 - 1;    // 1 MHz count
    TIM2->ARR = 0xFFFFFFFF;
    TIM2->EGR = TIM_EGR_UG;                       // load the prescaler
    TIM2->CR1 |= TIM_CR1_CEN;
}

uint32_t micros(void) {
    return TIM2->CNT;
}

void delay_ms(uint32_t ms) {
    uint32_t start = micros();
    while (micros() - start < ms * 1000u);
}

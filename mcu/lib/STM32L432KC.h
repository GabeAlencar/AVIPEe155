// STM32L432KC.h
// Header to include all other STM32L432KC libraries.
// From the E155 lab libraries; the SPI, TIM and USART libraries are left
// out because fpga_link.c, it8951.c and timing.c set up those peripherals.

#ifndef STM32L4_H
#define STM32L4_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stm32l432xx.h>

// Include other peripheral libraries

#include "STM32L432KC_GPIO.h"
#include "STM32L432KC_RCC.h"
#include "STM32L432KC_FLASH.h"

// Global defines

#define HSI_FREQ 16000000 // HSI clock is 16 MHz
#define MSI_FREQ 4000000  // MSI clock is 4 MHz

#endif

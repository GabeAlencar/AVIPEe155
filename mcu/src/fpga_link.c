// fpga_link.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// FFT frames from the FPGA. The FPGA is the SPI master (spi_frame_tx.sv): it
// sends a 514-word frame every 20 ms in mode 0, 16-bit words, MSB first, at
// 3 MHz, with cs_b low for the whole frame (about 2.7 ms).
//
// SPI3 runs as a receive-only slave with software NSS. To stay aligned to
// word boundaries it is reset and armed only in the gap between frames: wait
// for cs_b to rise (end of a frame), then reset SPI3, start DMA and enable it.
// DMA2 channel 1 (request 3 = SPI3_RX) copies the 514 words to memory.

#include "STM32L432KC.h"
#include "config.h"
#include "fpga_link.h"
#include "timing.h"

#define CS_TIMEOUT_US    50000      // a frame starts every 20 ms
#define FRAME_TIMEOUT_US 50000      // a frame takes about 3 ms

static void pin_af(int pin, int af) {
    GPIO_TypeDef *port = gpioPinToBase(pin);
    int n = gpioPinOffset(pin);
    pinMode(pin, GPIO_ALT);
    port->AFR[n >> 3] &= ~(0xFu << (4 * (n & 7)));
    port->AFR[n >> 3] |= (uint32_t)af << (4 * (n & 7));
}

void fpga_link_init(void) {
    gpioEnable(GPIO_PORT_A);
    gpioEnable(GPIO_PORT_B);
    RCC->APB1ENR1 |= RCC_APB1ENR1_SPI3EN;
    RCC->AHB1ENR  |= RCC_AHB1ENR_DMA2EN;

    pin_af(FPGA_SCK, 6);
    pin_af(FPGA_MOSI, 6);

    // cs_b as a plain input with a pull-up, so it reads idle if unplugged
    pinMode(FPGA_CS, GPIO_INPUT);
    GPIO_TypeDef *cs_port = gpioPinToBase(FPGA_CS);
    int cs_n = gpioPinOffset(FPGA_CS);
    cs_port->PUPDR = (cs_port->PUPDR & ~(3u << (2 * cs_n))) | (1u << (2 * cs_n));

    // DMA2 channel 1: SPI3->DR to memory, 16-bit both sides
    DMA2_CSELR->CSELR = (DMA2_CSELR->CSELR & ~DMA_CSELR_C1S) | (3u << DMA_CSELR_C1S_Pos);
    DMA2_Channel1->CCR  = 0;
    DMA2_Channel1->CPAR = (uint32_t)&SPI3->DR;
    DMA2_Channel1->CCR  = DMA_CCR_MINC | DMA_CCR_PSIZE_0 | DMA_CCR_MSIZE_0;
}

static int wait_cs(int level) {
    uint32_t start = micros();
    while (digitalRead(FPGA_CS) != level)
        if (micros() - start > CS_TIMEOUT_US) return 0;
    return 1;
}

int fpga_link_receive(uint16_t *words) {
    // find the end of a frame: cs_b low, then high
    if (!wait_cs(0) || !wait_cs(1)) return 0;

    // reset SPI3 so no half-received word is left in it
    RCC->APB1RSTR1 |=  RCC_APB1RSTR1_SPI3RST;
    RCC->APB1RSTR1 &= ~RCC_APB1RSTR1_SPI3RST;

    // slave, mode 0, MSB first, receive only, software NSS held low (selected)
    SPI3->CR1 = SPI_CR1_RXONLY | SPI_CR1_SSM;
    SPI3->CR2 = (0xFu << SPI_CR2_DS_Pos) | SPI_CR2_RXDMAEN;   // 16-bit, RXNE per word

    DMA2_Channel1->CCR  &= ~DMA_CCR_EN;
    DMA2_Channel1->CMAR  = (uint32_t)words;
    DMA2_Channel1->CNDTR = FRAME_WORDS;
    DMA2->IFCR = DMA_IFCR_CGIF1;
    DMA2_Channel1->CCR  |= DMA_CCR_EN;

    SPI3->CR1 |= SPI_CR1_SPE;

    uint32_t start = micros();
    int ok = 1;
    while (!(DMA2->ISR & DMA_ISR_TCIF1))
        if (micros() - start > FRAME_TIMEOUT_US) { ok = 0; break; }

    SPI3->CR1 &= ~SPI_CR1_SPE;
    DMA2_Channel1->CCR &= ~DMA_CCR_EN;
    DMA2->IFCR = DMA_IFCR_CGIF1;

    return ok && words[0] == FRAME_SYNC;
}

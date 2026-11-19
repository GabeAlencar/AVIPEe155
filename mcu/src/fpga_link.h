// fpga_link.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Receives FFT frames from the FPGA on SPI3 (slave) with DMA2 channel 1.

#ifndef FPGA_LINK_H
#define FPGA_LINK_H

#include <stdint.h>
#include "spectrum.h"

void fpga_link_init(void);

// Waits for the end of the frame on the wire, then receives the next whole
// frame into words[FRAME_WORDS]. Returns 1 on success, 0 on a timeout or a
// bad sync word.
int fpga_link_receive(uint16_t *words);

#endif

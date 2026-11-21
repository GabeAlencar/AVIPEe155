// fpga_link.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Receives FFT frames from the FPGA on SPI3 (slave) with DMA2 channel 1.

#ifndef FPGA_LINK_H
#define FPGA_LINK_H

#include <stdint.h>
#include "spectrum.h"

// Why the last receive failed: stage 1 cs_b never went low, 2 never went
// high, 3 DMA timed out (left = words not received), 4 bad sync word.
typedef struct { int stage; unsigned left, sr, w0, w1; } fpga_link_debug_t;
extern fpga_link_debug_t fpga_link_debug;

void fpga_link_init(void);

// Waits for the end of the frame on the wire, then receives the next whole
// frame into words[FRAME_WORDS]. Returns 1 on success, 0 on a timeout or a
// bad sync word.
int fpga_link_receive(uint16_t *words);

// Receive every frame in the background. cb runs in the cs_b interrupt for
// each frame that starts with FRAME_SYNC; keep it short (well under 15 ms).
typedef void (*frame_callback)(const uint16_t *words);
void fpga_link_start_async(frame_callback cb);
extern volatile uint32_t fpga_link_good, fpga_link_bad;

#endif

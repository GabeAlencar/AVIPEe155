// spectrum.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Turns one FFT frame from the FPGA into dB magnitudes and a peak, the same
// math as magnitude_db() in fpga/model/fft_live.py.

#ifndef SPECTRUM_H
#define SPECTRUM_H

#include <stdint.h>
#include "config.h"

// Frame from spi_frame_tx.sv: 514 16-bit words,
//   A55A | {frame number, STAGE_SHIFT} | re X[0], im X[0], ..., re X[255], im X[255]
#define FRAME_WORDS (2 + 2 * BINS)
#define FRAME_SYNC  0xA55A

typedef struct {
    float   db[BINS];   // |X[k]| in dB, 0 dB = full-scale sine at STAGE_SHIFT 1
    int     peak_bin;   // largest bin in 1..255
    float   peak_hz;
    float   peak_db;
    uint8_t frame;      // frame number from the header
    uint8_t shift;      // STAGE_SHIFT from the header
} spectrum_t;

// Returns 0 if the frame does not start with FRAME_SYNC.
int spectrum_from_frame(const uint16_t *words, spectrum_t *s);

#endif

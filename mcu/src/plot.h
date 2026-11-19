// plot.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Draws the spectrum plot as a 1-bit image, one band of rows at a time,
// because the whole IMG_W x IMG_H image (about 190 KB) does not fit in SRAM.
// The plot matches fft_live.py: |X[k]| in dB from -100 to 0 against frequency
// from 0 to FS/2, with the peak frequency in the title.
//
// Band buffer layout: BAND_ROWS rows of ROW_BYTES bytes, 1 = black ink.

#ifndef PLOT_H
#define PLOT_H

#include <stdint.h>
#include "spectrum.h"

// Compute everything that does not depend on the band (curve, labels).
void plot_prepare(const spectrum_t *s);

// Draw rows y0 .. y0+rows-1 of the prepared plot into buf.
void plot_render_band(uint8_t *buf, int y0, int rows);

// Test screen for display bring-up: border, diagonal, corner labels.
void plot_render_test_band(uint8_t *buf, int y0, int rows);

#endif

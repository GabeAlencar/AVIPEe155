// it8951.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Driver for the IT8951 controller on the Waveshare 6inch HD e-Paper HAT
// (1448 x 1072), over SPI1 with DMA1 channel 3 for image data. Set the HAT's
// interface switch to SPI.

#ifndef IT8951_H
#define IT8951_H

#include <stdint.h>

typedef struct {
    uint16_t width, height;     // panel size
    uint32_t img_buf_addr;      // image buffer in the IT8951's memory
    char     fw_version[17];
    char     lut_version[17];
} it8951_info_t;

// Draws one band: fills buf (BAND_ROWS * ROW_BYTES bytes) with rows y0..y0+rows-1.
typedef void (*band_fn)(uint8_t *buf, int y0, int rows);

// Reset, read the panel info, set VCOM, clear the screen. Returns 0 on a timeout.
int  it8951_init(it8951_info_t *info);

// Draw the whole IMG_W x IMG_H image, one band at a time, and show it with
// the given waveform mode (EPD_MODE_*). Returns 0 on a timeout.
int  it8951_draw(band_fn draw_band, int mode);

// 1 while the panel is still updating.
int  it8951_busy(void);

#endif

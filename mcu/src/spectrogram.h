// spectrogram.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/20/26
//
// Sweeping spectrogram: time runs left to right across the plot (one sweep
// is SWEEP_SECONDS), frequency runs bottom to top, and loudness is dithered
// black on white. Only the strip at the scan line is redrawn each update, so
// the e-paper can refresh it quickly with the A2 waveform.

#ifndef SPECTROGRAM_H
#define SPECTROGRAM_H

#include <stdint.h>
#include "config.h"
#include "spectrum.h"

// ---- layout, in drawing coordinates (before ROTATE_180) ----
// The plot's left and right edges are multiples of 32 so strips line up with
// the 32-pixel steps that 1-bpp partial updates need.
#define SG_X0        160                    // plot left
#define SG_X1        1344                   // plot right (exclusive)
#define SG_Y0        117                    // plot top (highest frequency)
#define SG_Y1        937                    // plot bottom (exclusive, 0 Hz)
#define SG_W         (SG_X1 - SG_X0)
#define SG_H         (SG_Y1 - SG_Y0)
#define SG_TITLE_Y0  16                     // rows redrawn for the peak readout
#define SG_TITLE_Y1  112

#define SWEEP_SECONDS 10
#define FRAME_RATE    (FS_HZ / 312.0f)      // a new frame every 312 samples
#define SWEEP_FRAMES  ((int)(SWEEP_SECONDS * FRAME_RATE + 0.5f))

// Loudness range mapped from white to black.
#define SG_DB_MIN    (-67.0f)
#define SG_DB_MAX    (-24.5f)

#define SG_CURSOR_W  8                      // scan line width
#define SG_GAP_W     28                     // cleared ahead of the scan line
#define SG_RING      128                    // frames kept: covers the ~1.2 s sweep-end clear

// Store one frame (call from the receive interrupt).
void spectrogram_push(const uint16_t *words);

// Frames stored so far (sequence number of the newest).
uint32_t spectrogram_count(void);

// Plan the strip that draws frames up to `newest`, starting after `drawn`.
// Returns the last frame the strip covers (it stops at the end of a sweep)
// and sets the panel area to update.
uint32_t spectrogram_plan_strip(uint32_t drawn, uint32_t newest,
                                int *px, int *py, int *pw, int *ph);

// Plan a blank plot area (grid only), for clearing ghosts after a sweep.
void spectrogram_plan_clear(int *px, int *py, int *pw, int *ph);

// Start a new sweep at the left edge with the frame after `last`.
void spectrogram_start_sweep(uint32_t last);

// 1 if frame `s` is the last one of the current sweep.
int spectrogram_sweep_done(uint32_t s);

// Time between scan steps. Every step waits for this tick, so each one moves
// the scan line by the same amount (about STEP / 20 ms frames). It is a
// little longer than one A2 strip update (about 185 ms on this panel).
#define SG_STEP_US   200000

// band_fn for the planned strip (panel rows, ROW stride = strip width / 8).
void spectrogram_strip_band(uint8_t *buf, int y0, int rows);

// Loudest bin since the last call, as Hz and dB; returns 0 if no frames.
int spectrogram_take_peak(int *hz, int *db);

#endif

// spectrogram.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/20/26
//
// Sweeping spectrogram strips (see spectrogram.h).
//
// Frame number s (counting from 1) is drawn in sweep column c = (s - 1) %
// SWEEP_FRAMES, which covers x from col_x(c) to col_x(c + 1). Each update
// draws the frames that arrived since the last one, plus the scan line and a
// cleared gap just ahead of them, rounded out to 32-pixel steps.

#include <math.h>
#include <string.h>
#include "spectrogram.h"

typedef struct {
    uint32_t seq;           // frame number stored here, 0 = empty
    uint8_t  lvl[BINS];     // loudness 0 (white) .. 255 (black)
} column_t;

static column_t          ring[SG_RING];
static volatile uint32_t count;
static volatile int      peak_bin, peak_lvl = -1;

static uint32_t          sweep_base;     // frame before the first one of this sweep

void spectrogram_start_sweep(uint32_t last) {
    sweep_base = last;
}

int spectrogram_sweep_done(uint32_t s) {
    return s > sweep_base && (s - sweep_base) % SWEEP_FRAMES == 0;
}

static const uint8_t bayer4[4][4] = {
    { 0,  8,  2, 10},
    {12,  4, 14,  6},
    { 3, 11,  1,  9},
    {15,  7, 13,  5},
};

static int col_x(int c) {
    return SG_X0 + (int)((long)c * SG_W / SWEEP_FRAMES);
}

void spectrogram_push(const uint16_t *words) {
    uint32_t s = count + 1;
    column_t *col = &ring[s % SG_RING];
    const int16_t *x = (const int16_t *)&words[2];
    int best = -1, best_k = 1;
    for (int k = 0; k < BINS; k++) {
        float re = x[2 * k], im = x[2 * k + 1];
        float p = re * re + im * im;
        float db = 10.0f * log10f(p + 0.25f) - 20.0f * log10f(32767.0f / 2.0f);
        float t = (db - SG_DB_MIN) * (255.0f / (SG_DB_MAX - SG_DB_MIN));
        int lvl = t < 0 ? 0 : t > 255 ? 255 : (int)t;
        col->lvl[k] = (uint8_t)lvl;
        if (k > 0 && lvl > best) { best = lvl; best_k = k; }
    }
    col->seq = s;
    if (best > peak_lvl) { peak_lvl = best; peak_bin = best_k; }
    count = s;
}

uint32_t spectrogram_count(void) {
    return count;
}

int spectrogram_take_peak(int *hz, int *db) {
    int lvl = peak_lvl, bin = peak_bin;
    peak_lvl = -1;
    if (lvl < 0) return 0;
    *hz = (int)(bin * FS_HZ / FFT_N + 0.5f);
    *db = (int)(SG_DB_MIN + lvl * (SG_DB_MAX - SG_DB_MIN) / 255.0f - 0.5f);
    return 1;
}

// ---- the planned strip ----
static int      sx0, sx1;        // strip x range in drawing coordinates
static int      bar_x0, bar_x1;  // scan line
static uint32_t last_seq;        // newest frame drawn in this strip
static int      last_col;        // its sweep column
static const column_t *xcol[SG_W];   // frame for each x of the strip, or 0

uint32_t spectrogram_plan_strip(uint32_t drawn, uint32_t newest,
                                int *px, int *py, int *pw, int *ph) {
    if (drawn < sweep_base) drawn = sweep_base;
    int c_first = (int)((drawn - sweep_base) % SWEEP_FRAMES);       // column of frame drawn+1
    int c_last  = (int)((newest - 1 - sweep_base) % SWEEP_FRAMES);
    if (c_last < c_first) {                              // stop at the end of the sweep
        newest = drawn + (uint32_t)(SWEEP_FRAMES - c_first);
        c_last = SWEEP_FRAMES - 1;
    }
    last_seq = newest;
    last_col = c_last;

    int xa = col_x(c_first), xb = col_x(c_last + 1);
    bar_x0 = xb;
    bar_x1 = xb + SG_CURSOR_W;
    int xe = xb + SG_GAP_W;
    sx0 = SG_X0 + ((xa - SG_X0) / 32) * 32;
    sx1 = SG_X0 + ((xe - SG_X0 + 31) / 32) * 32;
    if (sx1 > SG_X1) sx1 = SG_X1;

    // frame for each column of the strip (columns ahead of the newest are cleared)
    for (int x = sx0; x < sx1; x++) {
        int c = (int)((long)(x - SG_X0) * SWEEP_FRAMES / SG_W);
        while (c > 0 && col_x(c) > x) c--;
        while (c + 1 < SWEEP_FRAMES && col_x(c + 1) <= x) c++;
        const column_t *p = 0;
        if (c <= c_last) {
            uint32_t s = last_seq - (uint32_t)(c_last - c);
            const column_t *e = &ring[s % SG_RING];
            if (s > 0 && e->seq == s) p = e;
        }
        xcol[x - sx0] = p;
    }

#if ROTATE_180
    *px = IMG_W - sx1;
    *py = IMG_H - SG_Y1;
#else
    *px = sx0;
    *py = SG_Y0;
#endif
    *pw = sx1 - sx0;
    *ph = SG_H;
    return newest;
}

void spectrogram_plan_clear(int *px, int *py, int *pw, int *ph) {
    sx0 = SG_X0;
    sx1 = SG_X1;
    bar_x0 = bar_x1 = -1;
    for (int x = sx0; x < sx1; x++) xcol[x - sx0] = 0;
#if ROTATE_180
    *px = IMG_W - sx1;
    *py = IMG_H - SG_Y1;
#else
    *px = sx0;
    *py = SG_Y0;
#endif
    *pw = sx1 - sx0;
    *ph = SG_H;
}

void spectrogram_strip_band(uint8_t *buf, int y0, int rows) {
    const int w = sx1 - sx0, stride = w / 8;
    memset(buf, 0, (size_t)rows * stride);
    for (int r = 0; r < rows; r++) {
        int py = y0 + r;                                 // panel row
#if ROTATE_180
        int y = IMG_H - 1 - py;
#else
        int y = py;
#endif
        int from_bottom = SG_Y1 - 1 - y;                 // 0 at 0 Hz
        int bin = 1 + from_bottom * (BINS - 1) / SG_H;
        int hz = (int)(bin * FS_HZ / FFT_N);
        int grid = 0;                                    // within 1 row of a kHz line
        for (int d = 0; d <= 1 && !grid; d++) {
            int fb = from_bottom - d;
            if (fb <= 0) break;
            int b = 1 + fb * (BINS - 1) / SG_H, bp = 1 + (fb - 1) * (BINS - 1) / SG_H;
            grid = (int)(b * FS_HZ / FFT_N) / 1000 != (int)(bp * FS_HZ / FFT_N) / 1000;
        }
        uint8_t *row = buf + r * stride;
        for (int i = 0; i < w; i++) {
#if ROTATE_180
            int x = sx1 - 1 - i;                         // panel column i, left to right
#else
            int x = sx0 + i;
#endif
            int ink;
            if (x >= bar_x0 && x < bar_x1) {
                ink = 1;
            } else {
                const column_t *p = xcol[x - sx0];
                ink = p && p->lvl[bin] > bayer4[(y * 2 / 3) & 3][(x * 2 / 3) & 3] * 16 + 8;
                if (grid && x % 12 < 4) ink = 1;          // dashed line every 1 kHz
            }
            if (ink) {
#if EPD_LSB_FIRST
                row[i >> 3] |= (uint8_t)(1u << (i & 7));
#else
                row[i >> 3] |= (uint8_t)(0x80u >> (i & 7));
#endif
            }
        }
    }
}

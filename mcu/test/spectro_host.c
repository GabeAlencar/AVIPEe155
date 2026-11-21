// spectro_host.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/20/26
//
// Runs the spectrogram code on a PC: reads frames (514 hex words each) from
// stdin, pushes them, and draws strips the way main.c does, STEP frames per
// update. Writes the panel image as PGM, turned back upright if ROTATE_180.
//
//   gcc -O2 -I../src spectro_host.c ../src/spectrogram.c ../src/plot.c ../src/spectrum.c -lm -o spectro_host
//   python frame_from_capture.py CAPTURE.bin --all | ./spectro_host > spectro.pgm

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "plot.h"
#include "spectrogram.h"

#define STEP 6

typedef void (*band_fn)(uint8_t *buf, int y0, int rows);

static uint8_t panel[IMG_H][IMG_W];

static int bit_at(const uint8_t *row, int i) {
    return EPD_LSB_FIRST ? (row[i >> 3] >> (i & 7)) & 1 : (row[i >> 3] >> (7 - (i & 7))) & 1;
}

static void blit(int x, int y, int w, int h, band_fn fn) {
    static uint8_t buf[IMG_H * ROW_BYTES];
    fn(buf, y, h);
    for (int r = 0; r < h; r++)
        for (int i = 0; i < w; i++)
            panel[y + r][x + i] = bit_at(buf + r * (w / 8), i) ? 0 : 255;
}

int main(void) {
    static uint16_t words[FRAME_WORDS];
    plot_spectro_set_peak(0, 0);
    blit(0, 0, IMG_W, IMG_H, plot_render_spectro_bg_band);

    uint32_t drawn = 0;
    int n = 0;
    unsigned w;
    while (1) {
        int i;
        for (i = 0; i < FRAME_WORDS && scanf("%x", &w) == 1; i++) words[i] = (uint16_t)w;
        if (i < FRAME_WORDS) break;
        spectrogram_push(words);
        if (++n % STEP == 0) {
            int x, y, ww, h;
            while (drawn != spectrogram_count()) {
                drawn = spectrogram_plan_strip(drawn, spectrogram_count(), &x, &y, &ww, &h);
                blit(x, y, ww, h, spectrogram_strip_band);
            }
        }
    }
    int hz, db;
    if (spectrogram_take_peak(&hz, &db)) plot_spectro_set_peak(hz, db);
    // redraw only the title rows, as main.c does
    int ty = ROTATE_180 ? IMG_H - SG_TITLE_Y1 : SG_TITLE_Y0;
    blit(0, ty, IMG_W, SG_TITLE_Y1 - SG_TITLE_Y0, plot_render_spectro_bg_band);
    fprintf(stderr, "%d frames, sweep %d frames\n", n, SWEEP_FRAMES);

    printf("P5\n%d %d\n255\n", IMG_W, IMG_H);
    for (int y = 0; y < IMG_H; y++)
        for (int x = 0; x < IMG_W; x++)
            putchar(ROTATE_180 ? panel[IMG_H - 1 - y][IMG_W - 1 - x] : panel[y][x]);
    return 0;
}

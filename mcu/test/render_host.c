// render_host.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Runs the MCU's spectrum and plot code on a PC and saves the image the
// display would show, as a PGM file. Reads the 514 frame words (hex, one per
// line) from stdin, or draws the test screen with -t.
//
//   gcc -O2 -I../src render_host.c ../src/plot.c ../src/spectrum.c -lm -o render_host
//   python frame_from_capture.py CAPTURE.bin | ./render_host > plot.pgm

#include <stdio.h>
#include <string.h>
#include "plot.h"

static uint8_t img[IMG_H][IMG_W];

int main(int argc, char **argv) {
    static uint8_t band[BAND_ROWS * ROW_BYTES];
    int test = argc > 1 && strcmp(argv[1], "-t") == 0;

    if (!test) {
        uint16_t words[FRAME_WORDS];
        unsigned w;
        for (int i = 0; i < FRAME_WORDS; i++) {
            if (scanf("%x", &w) != 1) { fprintf(stderr, "need %d words\n", FRAME_WORDS); return 1; }
            words[i] = (uint16_t)w;
        }
        spectrum_t s;
        if (!spectrum_from_frame(words, &s)) { fprintf(stderr, "bad sync word\n"); return 1; }
        fprintf(stderr, "frame %d shift %d peak bin %d = %.0f Hz, %.1f dB\n",
                s.frame, s.shift, s.peak_bin, s.peak_hz, s.peak_db);
        plot_prepare(&s);
    }

    for (int y0 = 0; y0 < IMG_H; y0 += BAND_ROWS) {
        if (test) plot_render_test_band(band, y0, BAND_ROWS);
        else      plot_render_band(band, y0, BAND_ROWS);
        for (int r = 0; r < BAND_ROWS; r++)
            for (int x = 0; x < IMG_W; x++) {
                uint8_t byte = band[r * ROW_BYTES + ((x >> 3) ^ (EPD_SWAP_BYTES ? 1 : 0))];
                int bit = EPD_LSB_FIRST ? (byte >> (x & 7)) & 1 : (byte >> (7 - (x & 7))) & 1;
                img[y0 + r][x] = bit ? 0 : 255;
            }
    }

    printf("P5\n%d %d\n255\n", IMG_W, IMG_H);
    fwrite(img, 1, sizeof img, stdout);
    return 0;
}

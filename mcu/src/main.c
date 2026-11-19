// main.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// AVIPE display MCU: receives FFT frames from the FPGA on SPI3 and draws the
// spectrum on the 6-inch e-paper display, the same plot as
// fpga/model/fft_live.py. Each update takes the newest frame; frames that
// arrive while the display is drawing are dropped.
//
// printf goes to the SEGGER Embedded Studio debug terminal (RTT).

#include <stdio.h>
#include "STM32L432KC.h"
#include "config.h"
#include "fpga_link.h"
#include "it8951.h"
#include "plot.h"
#include "spectrum.h"
#include "timing.h"

static uint16_t   frame_words[FRAME_WORDS];
static spectrum_t spec;

int main(void) {
    configureFlash();
    configureClock();       // 80 MHz
    timing_init();

    it8951_info_t info;
    if (!it8951_init(&info)) {
        printf("IT8951 timed out: check power, wiring, the SPI switch, and HRDY\n");
        while (1);
    }
    printf("IT8951 %u x %u, buffer 0x%08lX, FW %s, LUT %s\n", info.width, info.height,
           (unsigned long)info.img_buf_addr, info.fw_version, info.lut_version);

#if TEST_SCREEN_ONLY
    uint32_t t = micros();
    it8951_draw(plot_render_test_band, EPD_MODE_GC16);
    printf("test screen drawn in %lu ms\n", (unsigned long)((micros() - t) / 1000));
    while (1);
#endif

    fpga_link_init();

    int updates = 0, misses = 0;
    while (1) {
        if (!fpga_link_receive(frame_words)) {
            if (++misses % 50 == 1)
                printf("no frame from the FPGA (%d misses); check cs_b, sck, mosi\n", misses);
            continue;
        }
        spectrum_from_frame(frame_words, &spec);
        plot_prepare(&spec);

        uint32_t t = micros();
        int mode = (updates % EPD_FULL_EVERY == 0) ? EPD_MODE_GC16 : EPD_MODE_FAST;
        if (!it8951_draw(plot_render_band, mode))
            printf("IT8951 timed out during an update\n");
        updates++;

        printf("frame %u: peak %d Hz, %d.%d dB, update %lu ms\n", spec.frame,
               (int)(spec.peak_hz + 0.5f), (int)spec.peak_db,
               (int)(spec.peak_db < 0 ? -spec.peak_db * 10 : spec.peak_db * 10) % 10,
               (unsigned long)((micros() - t) / 1000));
    }
}

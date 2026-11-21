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
#include "spectrogram.h"
#include "spectrum.h"
#include "timing.h"

static uint16_t   frame_words[FRAME_WORDS];
static spectrum_t spec;

#if SPECTROGRAM
// Sweeping spectrogram: frames arrive in the background, and each pass of the
// loop draws the strip for the frames that came in since the last one.
static void run_spectrogram(void) {
    // title rows, as a panel area
#if ROTATE_180
    const int title_y = IMG_H - SG_TITLE_Y1;
#else
    const int title_y = SG_TITLE_Y0;
#endif
    const int title_h = SG_TITLE_Y1 - SG_TITLE_Y0;

    plot_spectro_set_peak(0, 0);
    it8951_draw(plot_render_spectro_bg_band, EPD_MODE_GC16);
    fpga_link_start_async(spectrogram_push);

    uint32_t drawn = 0, strips = 0, t_title = micros(), t_log = micros();
    uint32_t t_next = micros();
    unsigned busy_ms = 0;
    spectrogram_start_sweep(0);
    while (1) {
        // one step per SG_STEP_US, so every step moves the scan line the same distance
        while ((int32_t)(micros() - t_next) < 0);
        t_next += SG_STEP_US;
        if ((int32_t)(micros() - t_next) > 0) t_next = micros() + SG_STEP_US;   // fell behind

        uint32_t newest = spectrogram_count();
        if (newest - drawn > SG_RING - 8) drawn = newest - (SG_RING - 8);
        if (newest == drawn) continue;

        // the strip at the scan line, and once a second the peak readout in the
        // title at the same time (separate areas refresh together, so the scan
        // does not stall)
        int x, y, w, h, hz, db;
        uint32_t t = micros();
        drawn = spectrogram_plan_strip(drawn, newest, &x, &y, &w, &h);
        it8951_draw_area_flags(x, y, w, h, spectrogram_strip_band, EPD_MODE_FAST, IT8951_NO_WAIT_AFTER);
        if (micros() - t_title > 1000000 && spectrogram_take_peak(&hz, &db)) {
            t_title = micros();
            plot_spectro_set_peak(hz, db);
            it8951_draw_area_flags(0, title_y, IMG_W, title_h, plot_render_spectro_bg_band,
                                   EPD_MODE_FAST, IT8951_NO_WAIT_BEFORE | IT8951_NO_WAIT_AFTER);
        }
        if (spectrogram_sweep_done(drawn)) {
            // end of a pass: clear the whole screen, then start the next sweep
            // at 0 s with the frames that arrive after the clear
            it8951_draw(plot_render_spectro_bg_band, EPD_MODE_GC16);
            drawn = spectrogram_count();
            spectrogram_start_sweep(drawn);
            t_next = micros() + SG_STEP_US;
        }
        busy_ms += (micros() - t) / 1000;
        strips++;
        if (micros() - t_log > 5000000) {
            t_log = micros();
            printf("%u frames ok, %u bad, %u strips, %u ms per strip\n", (unsigned)fpga_link_good,
                   (unsigned)fpga_link_bad, (unsigned)strips, strips ? busy_ms / (unsigned)strips : 0u);
            strips = 0;
            busy_ms = 0;
        }
    }
}
#endif

int main(void) {
    configureFlash();
    configureClock();       // 80 MHz
    timing_init();

    it8951_info_t info;
    printf("AVIPE display boot\n");
    if (!it8951_init(&info)) {
        printf("IT8951 timed out: check power, wiring, the SPI switch, and HRDY\n");
        while (1);
    }
    // the default SEGGER printf has no long or width support, so keep to plain %u %x %s
    printf("IT8951 %u x %u, buffer 0x%x, VCOM -%u mV\n", (unsigned)info.width, (unsigned)info.height,
           (unsigned)info.img_buf_addr, (unsigned)info.vcom_mv);
    printf("FW %s, LUT %s\n", info.fw_version, info.lut_version);

#if SHOW_IMAGE
    it8951_draw(plot_render_image_band, EPD_MODE_GC16);
    printf("image drawn\n");
    while (1);
#endif

#if TEST_SCREEN_ONLY
    uint32_t t = micros();
    it8951_draw(plot_render_test_band, EPD_MODE_GC16);
    printf("test screen drawn in %u ms\n", (unsigned)((micros() - t) / 1000));
    while (1);
#endif

    fpga_link_init();

#if SPECTROGRAM
    run_spectrogram();
#endif

    int updates = 0, misses = 0;
    while (1) {
        if (!fpga_link_receive(frame_words)) {
            if (++misses % 50 == 1)
                printf("no frame (%d misses): stage %d, %u words left, SR 0x%x, w0 0x%x w1 0x%x\n",
                       misses, fpga_link_debug.stage, fpga_link_debug.left, fpga_link_debug.sr,
                       fpga_link_debug.w0, fpga_link_debug.w1);
            continue;
        }
        spectrum_from_frame(frame_words, &spec);
        plot_prepare(&spec);

        uint32_t t = micros();
        int mode = (updates % EPD_FULL_EVERY == 0) ? EPD_MODE_GC16 : EPD_MODE_FAST;
        if (!it8951_draw(plot_render_band, mode))
            printf("IT8951 timed out during an update\n");
        updates++;

        printf("frame %u: peak %d Hz, %d.%d dB, update %u ms\n", spec.frame,
               (int)(spec.peak_hz + 0.5f), (int)spec.peak_db,
               (int)(spec.peak_db < 0 ? -spec.peak_db * 10 : spec.peak_db * 10) % 10,
               (unsigned)((micros() - t) / 1000));
    }
}

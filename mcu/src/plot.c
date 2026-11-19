// plot.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Spectrum plot drawn one band of rows at a time (see plot.h).

#include <stdio.h>
#include <string.h>
#include "plot.h"
#include "font5x7.h"

// ---- layout (pixels) ----
#define PX0      170            // plot area left
#define PX1      1400           // plot area right
#define PY0      120            // plot area top    (0 dB)
#define PY1      940            // plot area bottom (-100 dB)
#define PW       (PX1 - PX0)
#define PH       (PY1 - PY0)
#define DB_TOP   0.0f
#define DB_BOT   (-100.0f)
#define FRAME_T  3              // plot border thickness
#define LINE_T   1              // extra curve thickness on each side

#define MAX_TEXT 24
#define TEXT_LEN 24

typedef struct {
    int  x, y, scale;
    char str[TEXT_LEN];
} text_t;

static int16_t col_top[IMG_W];  // curve span in each column, top > bot means none
static int16_t col_bot[IMG_W];
static int     peak_x, peak_y;
static text_t  texts[MAX_TEXT];
static int     n_texts;

// ---- band being drawn ----
static uint8_t *band;
static int      band_y0, band_y1;   // rows band_y0 .. band_y1-1

static inline void set_px(int x, int y) {
    if (y < band_y0 || y >= band_y1 || x < 0 || x >= IMG_W) return;
#if EPD_LSB_FIRST
    band[(y - band_y0) * ROW_BYTES + (x >> 3)] |= (uint8_t)(1u << (x & 7));
#else
    band[(y - band_y0) * ROW_BYTES + (x >> 3)] |= (uint8_t)(0x80u >> (x & 7));
#endif
}

static void fill_rect(int x, int y, int w, int h) {
    int ya = y < band_y0 ? band_y0 : y;
    int yb = y + h > band_y1 ? band_y1 : y + h;
    for (int yy = ya; yy < yb; yy++)
        for (int xx = x; xx < x + w; xx++)
            set_px(xx, yy);
}

static void begin_band(uint8_t *buf, int y0, int rows) {
    band = buf;
    band_y0 = y0;
    band_y1 = y0 + rows;
    memset(buf, 0, (size_t)rows * ROW_BYTES);
}

static void end_band(int rows) {
#if EPD_SWAP_BYTES
    for (int i = 0; i < rows * ROW_BYTES; i += 2) {
        uint8_t t = band[i];
        band[i] = band[i + 1];
        band[i + 1] = t;
    }
#else
    (void)rows;
#endif
}

// ---- text ----
static int text_width(const char *s, int scale) {
    int n = (int)strlen(s);
    return n ? n * 6 * scale - scale : 0;
}

static void add_text(int x, int y, int scale, const char *s) {
    if (n_texts >= MAX_TEXT) return;
    text_t *t = &texts[n_texts++];
    t->x = x;
    t->y = y;
    t->scale = scale;
    strncpy(t->str, s, TEXT_LEN - 1);
    t->str[TEXT_LEN - 1] = 0;
}

static void draw_text(int x, int y, int scale, const char *s) {
    if (y + 7 * scale <= band_y0 || y >= band_y1) return;   // not in this band
    for (; *s; s++, x += 6 * scale) {
        const uint8_t *g = font_glyph(*s);
        for (int c = 0; c < 5; c++)
            for (int r = 0; r < 7; r++)
                if (g[c] & (1 << r))
                    fill_rect(x + c * scale, y + r * scale, scale, scale);
    }
}

// ---- spectrum to pixels ----
static int db_to_y(float db) {
    if (db > DB_TOP) db = DB_TOP;
    if (db < DB_BOT) db = DB_BOT;
    return PY0 + (int)((DB_TOP - db) / (DB_TOP - DB_BOT) * PH + 0.5f);
}

// x position of frequency f (Hz); the axis runs from 0 to FS/2
static int hz_to_x(float f) {
    return PX0 + (int)(f / (FS_HZ / 2.0f) * PW + 0.5f);
}

void plot_prepare(const spectrum_t *s) {
    static int16_t yv[IMG_W];
    char buf[TEXT_LEN];

    // curve height in each column, interpolating between bins. Bin k sits at
    // k * FS / 512 Hz, so column x is at bin (x - PX0) * 256 / PW.
    for (int x = PX0; x <= PX1; x++) {
        float k  = (float)(x - PX0) * BINS / PW;
        int   k0 = (int)k;
        if (k0 >= BINS - 1) {
            yv[x] = (int16_t)db_to_y(s->db[BINS - 1]);
        } else {
            float t = k - k0;
            yv[x] = (int16_t)db_to_y(s->db[k0] * (1.0f - t) + s->db[k0 + 1] * t);
        }
    }

    // each column covers the span to its neighbors, so steep edges stay joined
    for (int x = 0; x < IMG_W; x++) {
        col_top[x] = 1;
        col_bot[x] = 0;
    }
    for (int x = PX0; x <= PX1; x++) {
        int lo = yv[x], hi = yv[x];
        if (x > PX0) { if (yv[x - 1] < lo) lo = yv[x - 1]; if (yv[x - 1] > hi) hi = yv[x - 1]; }
        if (x < PX1) { if (yv[x + 1] < lo) lo = yv[x + 1]; if (yv[x + 1] > hi) hi = yv[x + 1]; }
        // the span to a neighbor only needs to reach halfway
        int mid_lo = (lo + yv[x]) / 2, mid_hi = (hi + yv[x] + 1) / 2;
        col_top[x] = (int16_t)(mid_lo - LINE_T);
        col_bot[x] = (int16_t)(mid_hi + LINE_T);
    }

    peak_x = hz_to_x(s->peak_hz);
    peak_y = db_to_y(s->peak_db);

    // ---- labels ----
    n_texts = 0;
    snprintf(buf, sizeof buf, "PEAK %d HZ", (int)(s->peak_hz + 0.5f));
    add_text(PX0, 28, 7, buf);

    int db10 = (int)(s->peak_db * 10.0f + (s->peak_db < 0 ? -0.5f : 0.5f));
    snprintf(buf, sizeof buf, "%s%d.%d DB", db10 < 0 ? "-" : "", (db10 < 0 ? -db10 : db10) / 10,
             (db10 < 0 ? -db10 : db10) % 10);
    add_text(PX1 - text_width(buf, 4), 28, 4, buf);
    snprintf(buf, sizeof buf, "FRAME %d", s->frame);
    add_text(PX1 - text_width(buf, 3), 70, 3, buf);

    // y axis: every 20 dB
    for (int db = 0; db >= -100; db -= 20) {
        snprintf(buf, sizeof buf, "%d", db);
        add_text(PX0 - 16 - text_width(buf, 4), db_to_y((float)db) - 14, 4, buf);
    }
    add_text(PX0 - 16 - text_width("DB", 4), PY0 - 60, 4, "DB");

    // x axis: every 1 kHz
    for (int khz = 0; khz * 1000 <= FS_HZ / 2; khz++) {
        if (khz == 0) snprintf(buf, sizeof buf, "0");
        else          snprintf(buf, sizeof buf, "%dK", khz);
        add_text(hz_to_x(khz * 1000.0f) - text_width(buf, 4) / 2, PY1 + 20, 4, buf);
    }
    add_text((PX0 + PX1) / 2 - text_width("FREQUENCY (HZ)", 4) / 2, PY1 + 80, 4, "FREQUENCY (HZ)");
}

void plot_render_band(uint8_t *buf, int y0, int rows) {
    begin_band(buf, y0, rows);

    // dotted grid: every 10 dB and every 1 kHz
    for (int db = -10; db > -100; db -= 10) {
        int y = db_to_y((float)db);
        if (y >= band_y0 && y < band_y1)
            for (int x = PX0; x <= PX1; x += 8) { set_px(x, y); set_px(x + 1, y); }
    }
    for (int khz = 1; khz * 1000 < FS_HZ / 2; khz++) {
        int x = hz_to_x(khz * 1000.0f);
        for (int y = band_y0; y < band_y1; y++)
            if (y > PY0 && y < PY1 && (y & 7) < 2) set_px(x, y);
    }

    // dashed line from the top of the plot down to the peak
    for (int y = band_y0; y < band_y1; y++)
        if (y > PY0 && y < peak_y && (y & 15) < 8) { set_px(peak_x - 1, y); set_px(peak_x, y); set_px(peak_x + 1, y); }

    // border
    fill_rect(PX0 - FRAME_T, PY0 - FRAME_T, PW + 2 * FRAME_T + 1, FRAME_T);
    fill_rect(PX0 - FRAME_T, PY1 + 1, PW + 2 * FRAME_T + 1, FRAME_T);
    fill_rect(PX0 - FRAME_T, PY0, FRAME_T, PH + 1);
    fill_rect(PX1 + 1, PY0, FRAME_T, PH + 1);

    // tick marks under the axis
    for (int khz = 0; khz * 1000 <= FS_HZ / 2; khz++)
        fill_rect(hz_to_x(khz * 1000.0f) - 1, PY1 + 1, 3, 12);

    // spectrum curve, 3 columns wide so steep edges are as thick as flat parts
    for (int x = PX0; x <= PX1; x++) {
        int a = col_top[x], b = col_bot[x];
        if (x > PX0) { if (col_top[x - 1] < a) a = col_top[x - 1]; if (col_bot[x - 1] > b) b = col_bot[x - 1]; }
        if (x < PX1) { if (col_top[x + 1] < a) a = col_top[x + 1]; if (col_bot[x + 1] > b) b = col_bot[x + 1]; }
        if (a < band_y0) a = band_y0;
        if (b >= band_y1) b = band_y1 - 1;
        if (a < PY0) a = PY0;
        if (b > PY1) b = PY1;
        for (int y = a; y <= b; y++) set_px(x, y);
    }

    for (int i = 0; i < n_texts; i++)
        draw_text(texts[i].x, texts[i].y, texts[i].scale, texts[i].str);

    end_band(rows);
}

void plot_render_test_band(uint8_t *buf, int y0, int rows) {
    begin_band(buf, y0, rows);

    fill_rect(0, 0, IMG_W, 6);                  // border
    fill_rect(0, IMG_H - 6, IMG_W, 6);
    fill_rect(0, 0, 6, IMG_H);
    fill_rect(IMG_W - 6, 0, 6, IMG_H);

    for (int y = band_y0; y < band_y1; y++) {   // diagonal, top left to bottom right
        int x = (int)((long)y * IMG_W / IMG_H);
        fill_rect(x - 2, y, 5, 1);
    }

    draw_text(40, 40, 8, "TOP LEFT");
    draw_text(40, 140, 4, "AVIPE DISPLAY TEST 0123456789");
    draw_text(IMG_W - 40 - text_width("BOTTOM RIGHT", 8), IMG_H - 40 - 56, 8, "BOTTOM RIGHT");

    // 1-pixel ruler: a mark every 8 pixels, longer every 64. The marks are
    // evenly spaced only if the bit order is right.
    for (int x = 0; x < IMG_W; x += 8)
        fill_rect(x, 400, 1, (x % 64) ? 30 : 60);

    end_band(rows);
}

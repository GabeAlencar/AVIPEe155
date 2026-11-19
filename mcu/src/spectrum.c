// spectrum.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// dB magnitude and peak of one FFT frame. Matches fft_live.py:
//   m  = hypot(re, im)
//   dB = 20 log10(max(m, 0.5) / (32767 / 2))
//   peak = argmax(dB[1:]) + 1, at peak * FS / 512 Hz

#include <math.h>
#include "spectrum.h"

int spectrum_from_frame(const uint16_t *words, spectrum_t *s) {
    if (words[0] != FRAME_SYNC) return 0;
    s->frame = (uint8_t)(words[1] >> 8);
    s->shift = (uint8_t)(words[1] & 0xFF);

    const int16_t *x = (const int16_t *)&words[2];   // re, im, re, im, ...

    for (int k = 0; k < BINS; k++) {
        float re = x[2 * k];
        float im = x[2 * k + 1];
#if USE_HAMMING
        // Hamming window after the FFT (Lyons 13.3):
        //   Xw[k] = 0.54 X[k] - 0.23 (X[k-1] + X[k+1])
        // X[-1] is conj(X[1]) for real input. X[256] is not sent; it is
        // taken as 0, which only changes the last bin.
        float lre = (k > 0) ? x[2 * (k - 1)]     : x[2];
        float lim = (k > 0) ? x[2 * (k - 1) + 1] : -x[3];
        float rre = (k < BINS - 1) ? x[2 * (k + 1)]     : 0.0f;
        float rim = (k < BINS - 1) ? x[2 * (k + 1) + 1] : 0.0f;
        re = 0.54f * re - 0.23f * (lre + rre);
        im = 0.54f * im - 0.23f * (lim + rim);
#endif
        float m = sqrtf(re * re + im * im);
        if (m < 0.5f) m = 0.5f;
        s->db[k] = 20.0f * log10f(m / (32767.0f / 2.0f));
    }

    int best = 1;
    for (int k = 2; k < BINS; k++)
        if (s->db[k] > s->db[best]) best = k;
    s->peak_bin = best;
    s->peak_db  = s->db[best];
    s->peak_hz  = best * FS_HZ / FFT_N;
    return 1;
}

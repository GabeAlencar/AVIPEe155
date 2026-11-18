"""Bit-exact Python model of Katie's FFT (fpga/src/fft.sv and friends).

Copies what the RTL does step by step, so its output should equal the
hardware's word for word:

  load      x[i] goes to RAM address bitrev(i)
  levels    for level L = 0..M-1 and butterfly j = 0..N/2-1 (fft_agu):
              A = rotl(2j, L), B = rotl(2j+1, L)   (M-bit rotate left)
              twiddle address = top L bits of j (as an M-1 bit number)
              A, B <- butterfly(RAM[A], RAM[B], twiddle)
  read-out  X[k] = RAM[k]

  mult          (a * b + 2^14) >> 15, kept to 16 bits   (math.sv: mult)
  complex_mult  re = rr - ii, im = ri + ir, each kept to 16 bits
  butterfly     (a + b*w) >>> STAGE_SHIFT and (a - b*w) >>> STAGE_SHIFT,
                summed in 17 bits, kept to 16 bits

With STAGE_SHIFT = 1 the result is about FFT(x) / N; with 0 it is FFT(x)
and the inputs must fit in 7 bits.
"""

from pathlib import Path

import numpy as np

TWIDDLE_FILE = Path(__file__).resolve().parents[1] / 'src' / 'twiddle.tv'


def _s16(v):
    """Keep the low 16 bits of an int array as a signed value."""
    return ((v + 0x8000) & 0xFFFF) - 0x8000


def load_twiddles(path=TWIDDLE_FILE):
    """Read twiddle.tv (32-bit binary words, real in the top half)."""
    w = [int(line, 2) for line in open(path) if line.strip()]
    w = np.array(w, dtype=np.int64)
    return _s16(w >> 16), _s16(w & 0xFFFF)


def bitrev(i, m):
    return int(f'{i:0{m}b}'[::-1], 2)


def fft_fixed(x_re, x_im=None, m=9, stage_shift=1, twiddles=None):
    """Run the RTL's FFT on integer inputs. Returns (re, im) int arrays, natural order."""
    n = 1 << m
    tw_re, tw_im = twiddles if twiddles is not None else load_twiddles()
    x_re = np.asarray(x_re, dtype=np.int64)
    x_im = np.zeros(n, np.int64) if x_im is None else np.asarray(x_im, dtype=np.int64)

    rev = np.array([bitrev(i, m) for i in range(n)])
    re = np.zeros(n, np.int64)
    im = np.zeros(n, np.int64)
    re[rev] = x_re
    im[rev] = x_im

    def mult(a, b):
        return _s16((a * b + (1 << 14)) >> 15)

    half = n // 2
    j = np.arange(half)
    mask = (1 << m) - 1
    for lvl in range(m):
        ta, tb = 2 * j, 2 * j + 1
        A = ((ta << lvl) | (ta >> (m - lvl))) & mask
        B = ((tb << lvl) | (tb >> (m - lvl))) & mask
        smask = ((1 << m) - (1 << (m - 1 - lvl))) & mask       # top lvl+1 bits of m
        t = (smask & j) & (half - 1)
        # butterflies in one level touch different addresses, so they can run together
        ar, ai, br, bi = re[A], im[A], re[B], im[B]
        wr, wi = tw_re[t], tw_im[t]
        pr = _s16(mult(br, wr) - mult(bi, wi))
        pi = _s16(mult(br, wi) + mult(bi, wr))
        re[A] = _s16((ar + pr) >> stage_shift)
        im[A] = _s16((ai + pi) >> stage_shift)
        re[B] = _s16((ar - pr) >> stage_shift)
        im[B] = _s16((ai - pi) >> stage_shift)
    return re, im


def pack(re, im):
    """32-bit words {re, im}, as the RTL stores them."""
    return ((np.asarray(re) & 0xFFFF) << 16) | (np.asarray(im) & 0xFFFF)


def unpack(words):
    w = np.asarray(words, dtype=np.int64)
    return _s16(w >> 16), _s16(w & 0xFFFF)

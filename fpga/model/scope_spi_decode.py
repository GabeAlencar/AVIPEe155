"""Decode SPI from a scope CSV (for a scope without the serial decode option).

    python scope_spi_decode.py FILE.csv [--cs 1] [--sck 2] [--mosi 3] [--threshold 1.65]

FILE.csv is a Keysight InfiniiVision "CSV data" save: a header row, then one
row per sample with time in the first column and one column per channel
(x-axis, 1 (VOLT), 2 (VOLT), ...). --cs/--sck/--mosi give which column
holds each signal, counting the channels from 1.

Decodes SPI mode 0 as fft_frame_spi.sv sends it: cs low frames, mosi read on
each rising sck edge, 16-bit words MSB first. Prints every frame's words in
hex and, when a frame starts with A55A, the frame number and STAGE_SHIFT and
the first bins as signed numbers.
"""

import argparse
import csv


def s16(w):
    return w - 0x10000 if w & 0x8000 else w


def read_csv(path):
    rows = []
    with open(path, newline='') as f:
        for row in csv.reader(f):
            try:
                rows.append([float(v) for v in row if v.strip() != ''])
            except ValueError:
                continue                      # header lines
    return rows


def decode(rows, cs_col, sck_col, mosi_col, threshold):
    frames, words, bits = [], [], []
    in_frame = False
    prev_sck = None
    for r in rows:
        cs = r[cs_col] > threshold
        sck = r[sck_col] > threshold
        mosi = r[mosi_col] > threshold
        if not cs and not in_frame:
            in_frame, words, bits = True, [], []
        elif cs and in_frame:
            frames.append((words, len(bits)))
            in_frame = False
        if in_frame and prev_sck is False and sck:
            bits.append(int(mosi))
            if len(bits) % 16 == 0:
                w = 0
                for b in bits[-16:]:
                    w = (w << 1) | b
                words.append(w)
        prev_sck = sck
    if in_frame:
        frames.append((words, len(bits)))    # cut off by the end of the capture
    return frames


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('file')
    ap.add_argument('--cs', type=int, default=1)
    ap.add_argument('--sck', type=int, default=2)
    ap.add_argument('--mosi', type=int, default=3)
    ap.add_argument('--threshold', type=float, default=1.65)
    a = ap.parse_args()
    rows = read_csv(a.file)
    print(f'{len(rows)} samples, {rows[1][0] - rows[0][0]:.3g} s apart' if len(rows) > 1 else 'no data')
    frames = decode(rows, a.cs, a.sck, a.mosi, a.threshold)
    if not frames:
        print('no cs low seen')
    for i, (words, nbits) in enumerate(frames):
        print(f'frame {i}: {nbits} bits, {len(words)} words (a full frame is 8224 bits, 514 words)')
        for j in range(0, len(words), 8):
            print('  ' + ' '.join(f'{w:04X}' for w in words[j:j + 8]))
        if words and words[0] == 0xA55A:
            if len(words) > 1:
                print(f'  sync OK, frame number {words[1] >> 8}, STAGE_SHIFT {words[1] & 0xFF}')
            bins = [(s16(words[k]), s16(words[k + 1])) for k in range(2, len(words) - 1, 2)]
            for k, (re, im) in enumerate(bins[:16]):
                print(f'  X[{k}] = {re} + {im}j')
        elif words:
            print(f'  first word {words[0]:04X}, expected A55A')


if __name__ == '__main__':
    main()

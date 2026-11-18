"""Check the SPI frames from fpga_top_tb against fft_fixed.py.

    python fft_spi_check.py SPI_HEX IN_TXT [PCM_TXT]

SPI_HEX  the testbench's +SPI file: one hex word a line, a blank line after
         each frame (cs_b high).
IN_TXT   the testbench's +IN file: the 512 samples that went into the fft
         for each frame, one frame a line.
PCM_TXT  optional +PCM file; each input frame must then be 512 consecutive
         samples of it.

Frame format (fpga/src/spi_frame_tx.sv): A55A, {frame number, STAGE_SHIFT},
then re X[k], im X[k] for k = 0..255, all 16-bit words.
"""

import sys

import numpy as np

from fft_fixed import fft_fixed

BINS = 256


def s16(w):
    return w - 0x10000 if w & 0x8000 else w


def read_frames(path):
    frames, cur = [], []
    for line in open(path):
        line = line.strip()
        if line:
            cur.append(int(line, 16))
        elif cur:
            frames.append(cur)
            cur = []
    if cur:
        frames.append(cur)
    return frames


def main(spi_path, in_path, pcm_path=None):
    frames = read_frames(spi_path)
    inputs = [[int(v) for v in line.split()] for line in open(in_path) if line.strip()]
    pcm = [int(v) for v in open(pcm_path)] if pcm_path else None
    errors = 0
    if len(frames) != len(inputs):
        print(f'{len(frames)} SPI frames but {len(inputs)} input frames')
        errors += 1
    prev_num = None
    for i, (words, x) in enumerate(zip(frames, inputs)):
        if len(words) != 2 + 2 * BINS or words[0] != 0xA55A:
            print(f'frame {i}: {len(words)} words, sync {words[0]:04x}')
            errors += 1
            continue
        num, shift = words[1] >> 8, words[1] & 0xFF
        if prev_num is not None and num != (prev_num + 1) & 0xFF:
            print(f'frame {i}: frame number {num} after {prev_num}')
            errors += 1
        prev_num = num
        if pcm is not None:
            hits = [j for j in range(len(pcm) - 511) if pcm[j:j + 512] == x]
            if not hits:
                print(f'frame {i}: input is not 512 consecutive pcm samples')
                errors += 1
        re_hw = np.array([s16(w) for w in words[2::2]])
        im_hw = np.array([s16(w) for w in words[3::2]])
        re_m, im_m = fft_fixed(np.array(x), m=9, stage_shift=shift)
        bad = int(np.sum(re_hw != re_m[:BINS]) + np.sum(im_hw != im_m[:BINS]))
        peak = int(np.argmax(np.hypot(re_hw[1:], im_hw[1:]))) + 1
        print(f'frame {i}: number {num}, STAGE_SHIFT {shift}, {bad} of {2 * BINS} words differ from fft_fixed, '
              f'biggest bin {peak} ({peak * 15625 / 512:.0f} Hz at 15,625 Hz)')
        errors += bad != 0
    print('PASSED' if errors == 0 and frames else 'FAILED')
    return errors == 0 and bool(frames)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(0 if main(*sys.argv[1:4]) else 1)

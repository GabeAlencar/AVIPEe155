"""Check logic analyzer captures from mic_hw_test_top against the model.

Export the decoded words from the logic analyzer (WaveForms, Saleae, ...) as
text or CSV, one word per row, then run one of:

  python hw_capture.py frames FRAMES.csv            # frame dump port
  python hw_capture.py pcm PCM.csv                  # pcm stream port
  python hw_capture.py compare I2S.csv PCM.csv      # mic words -> model -> pcm

Each row may hold other columns (time, index, ...). By default the last
number on each row is used; pick a CSV column with --column NAME (before
the command) instead, or --i2s-column / --pcm-column for compare.
Numbers may be decimal, 0x1A2B, h1A2B, or 1A2Bh; add --hex if they are bare hex.

frames  finds where each frame starts (the frame number word), then checks
        that frame numbers count up by 1, that each frame starts with the
        200 samples the previous one ended with (512 - 312 hop), that the
        DC is removed, and reports the loudest frequency.
pcm     reports DC, rms, peak, and the loudest frequency of the stream.
compare runs the I2S words through the bit-exact model of sum_of_3 and
        dc_removal and checks the pcm stream matches word for word. Both
        captures must start at reset (trigger the analyzer on reset_b rising).

The internal oscillator can be up to 10% off, so frequencies use --fs
(default 15625 Hz). For exact numbers, measure ws on a scope and pass
--fs <ws frequency / 3>.
"""

import argparse
import csv
import re
import sys

import numpy as np

FRAME_N, HOP = 512, 312
NUM = re.compile(r'^(?:0x([0-9a-f]+)|h([0-9a-f]+)|([0-9a-f]+)h|(-?\d+))$', re.I)


def parse_number(token, bare_hex):
    token = token.strip().strip('"')
    if bare_hex and re.fullmatch(r'[0-9a-fA-F]+', token):
        return int(token, 16)
    m = NUM.match(token)
    if not m:
        return None
    hx = m.group(1) or m.group(2) or m.group(3)
    return int(hx, 16) if hx else int(m.group(4))


def read_words(path, column=None, bare_hex=False):
    words = []
    with open(path, newline='') as f:
        if column:
            for row in csv.DictReader(f):
                v = parse_number(row[column], bare_hex)
                if v is not None:
                    words.append(v)
        else:
            for line in f:
                tokens = re.split(r'[,;\t ]+', line.strip())
                vals = [v for v in (parse_number(t, bare_hex) for t in tokens) if v is not None]
                if vals:
                    words.append(vals[-1])
    if not words:
        sys.exit(f'{path}: no words found')
    return np.array(words, dtype=np.int64)


def signed(words, bits):
    w = words & ((1 << bits) - 1)
    return np.where(w >= 1 << (bits - 1), w - (1 << bits), w)


def loudest(x, fs):
    x = np.asarray(x, float) - np.mean(x)
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    k = int(np.argmax(spec[1:]) + 1)
    return k * fs / len(x), 20 * np.log10(spec[k] / (np.sum(np.hanning(len(x))) / 2) / 32768 + 1e-12)


def describe(x, fs, label):
    f, db = loudest(x, fs)
    print(f'{label}: {len(x)} samples, DC {np.mean(x):+.1f}, rms {np.std(x):.1f}, '
          f'peak {np.abs(x).max()} LSB, loudest {f:.1f} Hz at {db:.1f} dBFS')


def model_pcm(mic):
    """Bit-exact sum_of_3 + dc_removal (AVERAGE_SHIFT 10, 16-bit saturation)."""
    out, acc = [], 0
    for g in range(len(mic) // 3):
        s = int(mic[3 * g] + mic[3 * g + 1] + mic[3 * g + 2])
        avg = acc >> 10
        out.append(min(32767, max(-32768, s - avg)))
        acc += s - avg
    return np.array(out, dtype=np.int64)


def cmd_frames(a):
    w = read_words(a.file, a.column, a.hex)
    n = FRAME_N + 1
    best = None
    for off in range(min(n, len(w))):
        heads = w[off::n][: (len(w) - off) // n]
        if len(heads) >= 2 and np.all((np.diff(heads) & 0xFFFF) == 1):
            best = off
            break
    if best is None:
        if len(w) >= 2 * n:
            sys.exit('FAIL: no offset where frame numbers count up by 1. Check the export.')
        best = 0
        print('only one frame captured, assuming it starts at the first word')
    frames = [(int(w[o]), signed(w[o + 1:o + n], 16)) for o in range(best, len(w) - n + 1, n)]
    print(f'{len(frames)} whole frames (first at word {best}), frame numbers {frames[0][0]} to {frames[-1][0]}')

    ok = True
    over = FRAME_N - HOP
    bad = [num for (num, x), (_, y) in zip(frames, frames[1:]) if not np.array_equal(x[HOP:], y[:over])]
    if len(frames) > 1:
        print(('PASS' if not bad else 'FAIL') + f': each frame starts with the last {over} samples of the one before'
              + (f' (wrong after frames {bad[:10]})' if bad else ''))
        ok &= not bad
    for num, x in frames[: a.show]:
        describe(x, a.fs, f'frame {num}')
    dc = np.mean([np.mean(x) for _, x in frames[len(frames) // 2:]])
    print(('PASS' if abs(dc) < 200 else 'CHECK') + f': mean DC of the later frames is {dc:+.1f} LSB (should be near 0)')
    if a.plot:
        plot_frames(frames, a.fs, a.plot)
    return ok


def cmd_pcm(a):
    x = signed(read_words(a.file, a.column, a.hex), 16)
    describe(x, a.fs, 'pcm stream')
    settle = min(len(x) // 2, 5 * 1024)
    describe(x[settle:], a.fs, f'pcm after the first {settle} (DC removal settled)')
    if a.plot:
        plot_stream(x, a.fs, a.plot)
    return True


def cmd_compare(a):
    raw = read_words(a.i2s, a.i2s_column or a.column, a.hex)[a.start::a.every]
    mic = signed(raw >> (a.i2s_bits - 18), 18)
    pcm = signed(read_words(a.pcm, a.pcm_column or a.column, a.hex), 16)
    exp = model_pcm(mic)
    n = min(len(exp), len(pcm))
    wrong = np.nonzero(exp[:n] != pcm[:n])[0]
    print(f'{len(mic)} mic words -> {len(exp)} model pcm, {len(pcm)} captured pcm, compared {n}')
    if len(wrong):
        i = wrong[0]
        print(f'FAIL: {len(wrong)} differ, first at pcm {i}: model {exp[i]}, captured {pcm[i]}')
        print('  If almost all differ, the captures probably do not both start at reset, '
              'or the I2S export includes the right channel (try --every 2).')
        return False
    print('PASS: captured pcm matches the model word for word')
    return True


def plot_frames(frames, fs, path):
    import matplotlib.pyplot as plt
    num, x = frames[-1]
    fig, ax = plt.subplots(1, 2, figsize=(12, 3.6))
    ax[0].plot(np.arange(FRAME_N) / fs * 1e3, x, lw=0.7)
    ax[0].set(title=f'frame {num}', xlabel='ms', ylabel='LSB')
    spec = np.abs(np.fft.rfft((x - x.mean()) * np.hanning(FRAME_N)))
    ax[1].plot(np.arange(len(spec)) * fs / FRAME_N, 20 * np.log10(spec / (FRAME_N / 4) / 32768 + 1e-9), lw=0.7)
    ax[1].set(title='spectrum (Hann window)', xlabel='Hz', ylabel='dBFS')
    fig.tight_layout(); fig.savefig(path, dpi=130)
    print(f'saved {path}')


def plot_stream(x, fs, path):
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(12, 3.6))
    ax.plot(np.arange(len(x)) / fs * 1e3, x, lw=0.5)
    ax.set(title='pcm stream', xlabel='ms', ylabel='LSB')
    fig.tight_layout(); fig.savefig(path, dpi=130)
    print(f'saved {path}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--column', help='CSV column holding the words (default: last number on each row)')
    p.add_argument('--hex', action='store_true', help='numbers are bare hex with no prefix')
    p.add_argument('--fs', type=float, default=15625.0, help='pcm sample rate in Hz (default 15625)')
    sub = p.add_subparsers(dest='cmd', required=True)
    f = sub.add_parser('frames'); f.add_argument('file'); f.add_argument('--plot'); f.add_argument('--show', type=int, default=3)
    s = sub.add_parser('pcm'); s.add_argument('file'); s.add_argument('--plot')
    c = sub.add_parser('compare'); c.add_argument('i2s'); c.add_argument('pcm')
    c.add_argument('--i2s-column', help='CSV column of the I2S words')
    c.add_argument('--pcm-column', help='CSV column of the pcm words')
    c.add_argument('--i2s-bits', type=int, default=24, help='bits per decoded I2S word (default 24)')
    c.add_argument('--every', type=int, default=1, help='keep every Nth I2S word (2 if both channels are exported)')
    c.add_argument('--start', type=int, default=0, help='first I2S word to keep (0 = left if both channels)')
    a = p.parse_args()
    ok = {'frames': cmd_frames, 'pcm': cmd_pcm, 'compare': cmd_compare}[a.cmd](a)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()

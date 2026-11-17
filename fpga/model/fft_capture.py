"""Read and check the FFT packets that mic_fft_test_top sends to the PC.

Each packet (fft_frame_uart.sv) holds one 512-sample input frame from the
ring buffer and the 512 outputs of Katie's fft for that frame:

  A5 5A F0 0F | frame number | STAGE_SHIFT | 512 x int16 input | 512 x {re, im} int16 | 16-bit checksum

Record on Windows (needs pyserial; run ftdi_reset.py first after programming):

  py fft_capture.py record --seconds 4 --out captures/fft_NAME.bin

Check a recording, or the bytes from mic_fft_test_top_tb (sim):

  python fft_capture.py check captures/fft_NAME.bin
  python fft_capture.py check uart.hex --pcm pcm.txt

check parses every packet, checks the checksum, and runs each input frame
through fft_fixed.py (a bit-exact model of the RTL). Every output word
should match. With --pcm it also checks that each input frame is 512
consecutive samples of the expected pcm stream.
"""

import argparse
import json
import sys
import time

try:
    import numpy as np
except ImportError:          # recording on Windows Python only needs count_packets
    np = None

SYNC = b'\xA5\x5A\xF0\x0F'
N = 512
PACKET = 4 + 2 + 2 * N + 4 * N + 2           # 3080 bytes
BAUD = 744186                                # works for this board's oscillator (12.034 MHz)


def parse(data):
    """Find the packets in a byte string. Returns (packets, stats)."""
    packets, bad_sum, i = [], 0, 0
    while True:
        i = data.find(SYNC, i)
        if i < 0 or i + PACKET > len(data):
            break
        p = data[i:i + PACKET]
        if sum(p[4:-2]) & 0xFFFF != int.from_bytes(p[-2:], 'big'):
            bad_sum += 1
            i += 1
            continue
        x = np.frombuffer(p[6:6 + 2 * N], dtype='>i2').astype(np.int64)
        w = np.frombuffer(p[6 + 2 * N:-2], dtype='>i2').astype(np.int64).reshape(N, 2)
        packets.append({'frame': p[4], 'shift': p[5], 'x': x, 're': w[:, 0], 'im': w[:, 1], 'offset': i})
        i += PACKET
    skipped = sum((b['frame'] - a['frame']) % 256 != 1 for a, b in zip(packets, packets[1:]))
    return packets, {'packets': len(packets), 'bad_checksums': bad_sum, 'frame_number_gaps': skipped}


def count_packets(data):
    """Packets with a good checksum, without numpy (for record)."""
    n, i = 0, 0
    while True:
        i = data.find(SYNC, i)
        if i < 0 or i + PACKET > len(data):
            return n
        p = data[i:i + PACKET]
        if sum(p[4:-2]) & 0xFFFF == int.from_bytes(p[-2:], 'big'):
            n += 1
            i += PACKET
        else:
            i += 1


def check(packets, pcm=None):
    """Compare every packet with the bit-exact model. Returns a list of per-packet dicts."""
    from fft_fixed import fft_fixed
    rows = []
    for p in packets:
        re, im = fft_fixed(p['x'], stage_shift=p['shift'])
        row = {'frame': p['frame'], 'wrong_words': int(np.sum((re != p['re']) | (im != p['im'])))}
        if pcm is not None:
            starts = [s for s in range(len(pcm) - N + 1) if pcm[s] == p['x'][0] and np.array_equal(pcm[s:s + N], p['x'])]
            row['pcm_start'] = starts[0] if starts else None
        rows.append(row)
    return rows


def read_file(path):
    if path.endswith('.hex'):
        return bytes(int(line, 16) for line in open(path) if line.strip())
    return open(path, 'rb').read()


def record(a):
    from serial_capture import find_port, grab
    port = a.port or find_port()
    t0 = time.time()
    data = grab(port, a.baud, a.seconds)
    n = count_packets(data)
    info = {'port': port, 'baud': a.baud, 'seconds': a.seconds, 'bytes': len(data),
            'elapsed': time.time() - t0, 'packets': n}
    open(a.out, 'wb').write(data)
    json.dump(info, open(a.out.rsplit('.', 1)[0] + '.json', 'w'), indent=1)
    print(json.dumps(info))
    if not n:
        sys.exit('No packets. Run ftdi_reset.py after programming, and check that mic_fft_test_top is running.')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('record')
    r.add_argument('--port')
    r.add_argument('--baud', type=int, default=BAUD)
    r.add_argument('--seconds', type=float, default=4.0)
    r.add_argument('--out', default='captures/fft.bin')
    c = sub.add_parser('check')
    c.add_argument('file')
    c.add_argument('--pcm', help='expected pcm samples, one per line (from the testbench)')
    a = ap.parse_args()

    if a.cmd == 'record':
        record(a)
        return
    packets, st = parse(read_file(a.file))
    print(st)
    pcm = np.loadtxt(a.pcm, dtype=np.int64) if a.pcm else None
    rows = check(packets, pcm)
    for row in rows:
        print(row)
    bad = sum(r['wrong_words'] for r in rows) + st['bad_checksums']
    if pcm is not None:
        bad += sum(r['pcm_start'] is None for r in rows)
        starts = [r['pcm_start'] for r in rows]
        print('input frame starts in pcm:', starts, '(should be 312 apart, times a whole number)')
    print('PASS' if packets and bad == 0 else 'FAIL')
    sys.exit(0 if packets and bad == 0 else 1)


if __name__ == '__main__':
    main()

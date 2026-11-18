"""Record pcm samples that mic_hw_test_top sends over the UPduino's USB serial port.

Run it with a Python that can open the port (on WSL that means Windows Python,
for example `py serial_capture.py ...` from PowerShell; needs pyserial):

  py serial_capture.py --seconds 5 --out capture.bin

The FPGA sends each sample as 3 bytes (see pcm_uart.sv) at clk / 16, nominally
750 kbaud. Its clock is the internal oscillator, which can be a few percent
off, so the script first tries baud rates from -10% to +10% and keeps the one
where the stream decodes cleanly. The FT232H makes 12 MHz / d baud with d in
steps of 1/8, so it tries d = 14.5 to 17.75.

Run ftdi_reset.py first after each programming: the Radiant programmer leaves
the FT232H in SPI mode, where it does not receive.

Writes:
  capture.bin   the raw bytes
  capture.json  the baud rate used, the FPGA clock and sample rate it implies
                (clk = 16 * baud, fs = clk / 768, good to about 1%), the
                measured byte rate, and the decode stats
Load both in hw_fft.ipynb with decode().
"""

import argparse
import json
import sys
import time



def decode(data):
    """Split the byte stream into samples. Returns (samples, counters, stats)."""
    samples, counters = [], []
    bad = 0
    i, n = 0, len(data)
    while i + 3 <= n:
        b0, b1, b2 = data[i], data[i + 1], data[i + 2]
        if b0 & 0x80 and not b1 & 0x80 and not b2 & 0x80:
            v = ((b0 & 0x7F) << 9) | (b1 << 2) | (b2 & 0x03)
            samples.append(v - 65536 if v & 0x8000 else v)
            counters.append((b2 >> 2) & 0x1F)
            i += 3
        else:
            bad += 1
            i += 1
    skips = sum(1 for a, b in zip(counters, counters[1:]) if (b - a) % 32 != 1)
    return samples, counters, {'samples': len(samples), 'bad_bytes': bad, 'counter_skips': skips}


def score(data):
    s, c, st = decode(data)
    if not s:
        return 0.0
    return st['samples'] * 3 / max(len(data), 1) - st['counter_skips'] / max(st['samples'], 1)


def find_port():
    from serial.tools import list_ports
    for p in list_ports.comports():
        if p.vid == 0x0403 and p.pid == 0x6014:
            return p.device
    sys.exit('No FT232H (UPduino) serial port found. Is the board plugged in?')


def grab(port, baud, seconds):
    import serial
    with serial.Serial(port, baud, timeout=0.05) as s:
        s.reset_input_buffer()
        time.sleep(0.02)
        s.reset_input_buffer()
        end, buf = time.time() + seconds, bytearray()
        while time.time() < end:
            buf += s.read(65536)
        return bytes(buf)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', help='serial port (default: find the UPduino FT232H)')
    ap.add_argument('--seconds', type=float, default=5.0)
    ap.add_argument('--out', default='capture.bin')
    ap.add_argument('--baud', type=int, help='skip the scan and use this baud')
    a = ap.parse_args()
    port = a.port or find_port()

    if a.baud:
        baud = a.baud
    else:
        results = []
        for k in range(116, 143):                 # d = 14.5 .. 17.75 in 1/8 steps
            b = round(12e6 / (k / 8))
            results.append((b, score(grab(port, b, 0.12))))
        good = sorted(b for b, sc in results if sc > 0.98)
        if not good:
            sys.exit('No baud rate decodes cleanly. Run ftdi_reset.py after programming, '
                     'and check that mic_hw_test_top is running.')
        # the UART works over a window of rates; the middle is the best guess
        baud = good[len(good) // 2]
        print(f'baud scan: {len(good)} rates decode, {good[0]} to {good[-1]}; using {baud}')

    t0 = time.time()
    data = grab(port, baud, a.seconds)
    elapsed = time.time() - t0
    s, c, st = decode(data)
    clk = 16 * baud
    info = {'port': port, 'baud': baud, 'clk_hz': clk, 'fs_hz': clk / 768, 'seconds': a.seconds, 'bytes': len(data),
            'fs_from_byte_rate_hz': len(data) / 3 / elapsed, **st}
    with open(a.out, 'wb') as f:
        f.write(data)
    with open(a.out.rsplit('.', 1)[0] + '.json', 'w') as f:
        json.dump(info, f, indent=1)
    print(json.dumps(info))
    print(f'{st["samples"]} samples, expected about {a.seconds * clk / 768:.0f}')


if __name__ == '__main__':
    main()

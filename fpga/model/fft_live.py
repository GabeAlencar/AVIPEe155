"""Read the FFT frames fpga_top sends over USB and plot them live.

fpga_top sends every frame twice: on the SPI pins (J3) for the scope
and the MCU, and on the UPduino's USB serial port for the PC (uart_frame_tx.sv).
The USB copy is the SPI frame plus a checksum, 515 big-endian 16-bit words:

  A55A | {frame number, STAGE_SHIFT} | re X[0], im X[0], ..., re X[255], im X[255] | sum of words 1..513

Live plot (needs pyserial, numpy, matplotlib):

  python fft_live.py                   # finds the UPduino's serial port
  python fft_live.py --port COM5       # or /dev/ttyUSB0 on Linux, /dev/cu.usbserial-* on macOS
  python fft_live.py --seconds 5 --out captures/spi_NAME.bin    # record instead of plotting

After programming with openFPGALoader, unplug and replug the USB cable (or
run ftdi_reset.py on Windows) so the FT232H is back in serial mode.

Check the bytes from fpga_top_tb against its SPI frames:

  python fft_live.py --check uart.hex --spi spi.hex
"""

import argparse
import sys
import time

import numpy as np

SYNC = b'\xA5\x5A'
WORDS = 515
FRAME_BYTES = 2 * WORDS                      # 1030
BINS = 256
BAUD = 744186                                # this board's oscillator runs at about 12.034 MHz, not 12
FS = 15669.7                                 # measured sample rate (hw_fft_full.ipynb)


def parse(data):
    """Find the frames in a byte string.

    Returns (frames, rest, bad): each frame is a dict with 'frame', 'shift',
    're', 'im' (int arrays of 256); rest is the unparsed tail to keep for the
    next read; bad counts checksum failures.
    """
    frames, bad, i = [], 0, 0
    while True:
        i = data.find(SYNC, i)
        if i < 0:
            return frames, data[-1:], bad
        if i + FRAME_BYTES > len(data):
            return frames, data[i:], bad
        w = np.frombuffer(data[i:i + FRAME_BYTES], dtype='>u2').astype(np.int64)
        if int(w[1:WORDS - 1].sum()) & 0xFFFF != int(w[-1]):
            bad += 1
            i += 1
            continue
        s = np.where(w >= 0x8000, w - 0x10000, w)
        frames.append({'frame': int(w[1] >> 8), 'shift': int(w[1] & 0xFF),
                       're': s[2:WORDS - 1:2], 'im': s[3:WORDS - 1:2], 'words': w[:WORDS - 1]})
        i += FRAME_BYTES


def find_port():
    """The UPduino's FT232H (FTDI vendor 0403, product 6014), or the only FTDI port."""
    from serial.tools import list_ports
    ports = [p for p in list_ports.comports() if p.vid == 0x0403]
    if not ports:
        sys.exit('no FTDI serial port found; is the UPduino plugged in? '
                 'Ports: ' + ', '.join(p.device for p in list_ports.comports()))
    ports.sort(key=lambda p: p.pid != 0x6014)
    return ports[0].device


def open_port(port=None, baud=BAUD):
    import serial
    return serial.Serial(port or find_port(), baud, timeout=0.05)


def frames_from(ser):
    """Yield frames from an open serial port as they arrive."""
    buf = b''
    while True:
        buf += ser.read(4096)
        frames, buf, _ = parse(buf)
        yield from frames


def magnitude_db(f):
    """|X[k]| in dB, with 0 dB = a full-scale (32767) sine at STAGE_SHIFT 1."""
    m = np.hypot(f['re'], f['im'])
    return 20 * np.log10(np.maximum(m, 0.5) / (32767 / 2))


def live(port, seconds=None, fs=FS, baud=BAUD):
    import matplotlib.pyplot as plt
    ser = open_port(port, baud)
    print(f'reading {ser.port} at {ser.baudrate} baud; close the window to stop')
    freqs = np.arange(BINS) * fs / 512
    plt.ion()
    fig, ax = plt.subplots(figsize=(10, 5))
    line, = ax.plot(freqs, np.full(BINS, -100.0), lw=1)
    ax.set_xlim(0, fs / 2)
    ax.set_ylim(-100, 0)
    ax.set_xlabel('frequency (Hz)')
    ax.set_ylabel('|X[k]| (dB, 0 = full-scale sine)')
    title = ax.set_title('waiting for frames...')
    ax.grid(alpha=0.3)
    start, n, last_num, gaps = time.time(), 0, None, 0
    try:
        for f in frames_from(ser):
            db = magnitude_db(f)
            n += 1
            if last_num is not None and (f['frame'] - last_num) % 256 != 1:
                gaps += 1
            last_num = f['frame']
            if n % 2 == 0 or ser.in_waiting < 1030:    # skip drawing if we fall behind
                line.set_ydata(db)
                k = int(np.argmax(db[1:])) + 1
                title.set_text(f'frame {f["frame"]}  |  peak {k * fs / 512:.0f} Hz (bin {k})  |  '
                               f'{n / (time.time() - start):.1f} frames/s, {gaps} gaps')
                fig.canvas.draw_idle()
                plt.pause(0.001)
            if not plt.fignum_exists(fig.number) or (seconds and time.time() - start > seconds):
                break
    finally:
        ser.close()


def record(port, seconds, out, baud=BAUD):
    ser = open_port(port, baud)
    data, start = b'', time.time()
    while time.time() - start < seconds:
        data += ser.read(65536)
    ser.close()
    open(out, 'wb').write(data)
    frames, _, bad = parse(data)
    print(f'{len(data)} bytes, {len(frames)} frames, {bad} bad checksums -> {out}')


def check(uart_hex, spi_hex):
    """Testbench check: every UART frame equals the SPI frame with the same number."""
    data = bytes(int(l, 16) for l in open(uart_hex) if l.strip())
    frames, _, bad = parse(data)
    spi = [[int(w, 16) for w in block.split()] for block in open(spi_hex).read().split('\n\n') if block.strip()]
    by_num = {s[1] >> 8: s for s in spi}
    ok = bool(frames) and bad == 0
    for f in frames:
        s = by_num.get(f['frame'])
        same = s is not None and list(f['words']) == s
        ok &= same
        print(f'uart frame {f["frame"]}: checksum OK, {"equals" if same else "DIFFERS FROM"} the SPI frame')
    print(f'{len(frames)} uart frames, {bad} bad checksums, {len(spi)} spi frames')
    print('PASSED' if ok else 'FAILED')
    return ok


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port')
    ap.add_argument('--baud', type=int, default=BAUD, help=f'default {BAUD}, which matches this board')
    ap.add_argument('--seconds', type=float)
    ap.add_argument('--out', help='record raw bytes to this file instead of plotting')
    ap.add_argument('--check', metavar='UART_HEX')
    ap.add_argument('--spi', metavar='SPI_HEX')
    a = ap.parse_args()
    if a.check:
        sys.exit(0 if check(a.check, a.spi) else 1)
    elif a.out:
        record(a.port, a.seconds or 4, a.out, a.baud)
    else:
        live(a.port, a.seconds, baud=a.baud)

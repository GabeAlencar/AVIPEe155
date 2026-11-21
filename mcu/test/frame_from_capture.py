"""Pull one FFT frame out of a USB capture and write it as the 514 SPI words.

The output is what the MCU receives on SPI3 (spi_frame_tx.sv), one hex word
per line, for render_host.c:

  python frame_from_capture.py ../../fpga/model/captures/spi_live.bin --index 20 > frame.hex
"""

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'fpga' / 'model'))
from fft_live import parse   # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('capture')
ap.add_argument('--index', type=int, default=0, help='which frame in the capture')
ap.add_argument('--all', action='store_true', help='write every frame, one after another')
a = ap.parse_args()

frames, _, bad = parse(pathlib.Path(a.capture).read_bytes())
if not frames:
    sys.exit(f'no frames in {a.capture} ({bad} bad checksums)')
for f in (frames if a.all else [frames[min(a.index, len(frames) - 1)]]):
    for w in f['words']:      # A55A, header, re/im of X[0..255]
        print(f'{int(w):04X}')
print(f'{len(frames)} frames, using frame {f["frame"]}', file=sys.stderr)

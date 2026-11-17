"""Restart the FPGA through CRESET_N, then record the first samples.

The FT232H's ADBUS7 drives the iCE40 CRESET_N on the UPduino. Pulling it low
and releasing it makes the FPGA reload from flash, which also resets the DC
removal's running average to 0. Recording right after shows the mic's DC
offset dying away, which the notebook compares with the simulation
(time constant 1024 samples).

  py reset_capture.py --baud 744186 --seconds 1.5 --out captures/reset.bin
"""
import argparse, ctypes, json, time, sys
from serial_capture import grab, decode, find_port

ap = argparse.ArgumentParser()
ap.add_argument('--baud', type=int, required=True)
ap.add_argument('--seconds', type=float, default=1.5)
ap.add_argument('--out', default='captures/reset.bin')
a = ap.parse_args()

d2xx = ctypes.WinDLL('ftd2xx.dll')
h = ctypes.c_void_p()
if d2xx.FT_Open(0, ctypes.byref(h)) != 0:
    sys.exit('could not open the FT232H')
w = ctypes.c_ulong()
d2xx.FT_SetBitMode(h, 0x80, 1)                   # async bit-bang, only ADBUS7 is an output
d2xx.FT_Write(h, ctypes.byref(ctypes.c_ubyte(0x00)), 1, ctypes.byref(w))   # CRESET_N low
time.sleep(0.01)
d2xx.FT_Write(h, ctypes.byref(ctypes.c_ubyte(0x80)), 1, ctypes.byref(w))   # release
d2xx.FT_SetBitMode(h, 0, 0)                      # back to serial
d2xx.FT_Close(h)
t_release = time.time()

port = find_port()
data = grab(port, a.baud, a.seconds)
s, c, st = decode(data)
info = {'baud': a.baud, 'clk_hz': 16 * a.baud, 'fs_hz': 16 * a.baud / 768, 'seconds': a.seconds,
        'bytes': len(data), 'note': 'recorded right after CRESET_N', **st}
open(a.out, 'wb').write(data)
json.dump(info, open(a.out.rsplit('.', 1)[0] + '.json', 'w'), indent=1)
print(json.dumps(info))
print('first samples:', s[:12])

"""Put the UPduino's FT232H back in plain serial (UART) mode.

The Radiant programmer leaves the FT232H in MPSSE (SPI) mode, where it drives
the line the FPGA's uart_tx uses and does not receive. This resets the bit
mode through FTDI's D2XX driver (ftd2xx.dll, installed with the FTDI driver
on Windows). Run it with Windows Python after programming, before
serial_capture.py. Unplugging and replugging the board does the same.
"""
import ctypes, sys

d2xx = ctypes.WinDLL('ftd2xx.dll')
n = ctypes.c_ulong()
d2xx.FT_CreateDeviceInfoList(ctypes.byref(n))
for i in range(n.value):
    desc = ctypes.create_string_buffer(64)
    d2xx.FT_GetDeviceInfoDetail(i, None, None, None, None, None, desc, None)
    if b'UPduino' not in desc.value and n.value > 1:
        continue
    h = ctypes.c_void_p()
    if d2xx.FT_Open(i, ctypes.byref(h)) != 0:
        sys.exit(f'could not open device {i} ({desc.value!r}); close the programmer or any serial terminal')
    r1 = d2xx.FT_SetBitMode(h, 0, 0)      # mode 0 = reset to the EEPROM default (UART)
    r2 = d2xx.FT_ResetDevice(h)
    d2xx.FT_Close(h)
    print(f'device {i} {desc.value.decode()}: bit mode reset ({r1}, {r2})')
    break
else:
    sys.exit('no FTDI device found')

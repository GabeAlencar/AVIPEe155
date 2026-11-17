# Hardware tests with the mic

`mic_hw_test_top` runs the front end (I2S receiver → sum of 3 → DC removal →
ring buffer) on the UPduino with the SPH0645 connected, plus four tests that
all run at once. The testbench `sim/mic_hw_test_top_tb.sv` checks the same
bitstream logic in simulation first.

## Build

1. In Radiant, set the top module to `mic_hw_test_top` (Project → Properties,
   or right-click the file → Set as Top-Level Unit).
2. Make `mic_hw_test.pdc` the active constraint file instead of `AVIPEe155.pdc`
   (add it with File → Add → Existing File if it is not listed, then right-click
   → Set as Active).
3. Build and program. Check the pad report for the pins below.
4. To go back to the real design: top `fpga_board_top`, active `AVIPEe155.pdc`.

## Wiring

All signals go through the E155 breadboard adapter (FA23, v4). Only FPGA
pins 2, 3, 4, 6, 9, 10, 11, 12, 13, 18, 19, 20, 21 and 44 to 48 reach it.

| Signal | FPGA pin | Adapter pin | Connect to |
|---|---|---|---|
| mic 3V | | J3-2 (+3V3) | mic 3V (not +5V: J1 has only +5V and VIN) |
| mic GND, SEL | | J3-1 or J1-18 (GND) | mic GND and SEL (SEL low = left channel) |
| bclk | 11 | J1-4 | mic BCLK, and the analyzer |
| ws | 6 | J1-5 | mic LRCL, and the analyzer |
| sd | 48 | J1-7 | mic DOUT, and the analyzer |
| reset_b | 34 | — | dev board push button SW0 (pull-up inside) |
| bar[0], bar[1], bar[2] | 10, 21, 19 | J1-1, J1-2, J1-3 | VU meter LEDs 1-3 (quietest first), each anode to the pin, cathode through 330 Ω-1 kΩ to GND |
| bar[3], bar[4] | 4, 47 | J1-6, J1-8 | VU meter LEDs 4-5, same way |
| led_heartbeat | 42 | — | dev board blue LED D6 |
| led_clip | 38 | — | dev board blue LED D7 |
| pcm_sck, pcm_sdo, pcm_cs_b | 46, 45, 3 | J3-12, J3-13, J3-14 | analyzer |
| frm_sck, frm_sdo, frm_cs_b | 44, 9, 18 | J3-15, J3-16, J3-17 | analyzer |
| analyzer ground | | any GND | analyzer GND |

Spare: P2 (J1-9), P13 (J3-18), P12 (J3-19), P20 (J3-20).

Keep the dev board's DIP switch SW7 off. It connects MCU pins to P10, P12,
P20, P21, P23 and P25-P27, and P10 and P21 drive VU meter LEDs.

## Tests

**1. Clocks.** On a scope, `bclk` is about 3 MHz and `ws` about 46.875 kHz
(the internal oscillator can be ±10% off). Write down the `ws` frequency:
the pcm sample rate is `ws / 3`. Pass it to the script as `--fs`.

**2. Heartbeat.** D6 blinks at about 1 Hz. This shows every block up to
the ring buffer runs. If it stays off, check `ws` and `bclk` first.

**3. VU meter.** The 5 green LEDs are a bar, about 10 dB per LED (levels 100,
300, 1000, 3000, 10000). In a quiet room they are off. Talking lights 2-3,
and a clap or whistle close to the mic fills the bar. The highest LED reached
stays on for 0.5 s as a peak-hold dot, then falls one LED every 0.1 s. D7 is the
clip light: it stays on 0.5 s after the DC removal output hits full scale. If
the bar stays full in silence, the DC removal is not working. If nothing ever
lights, `sd` is probably flat: check SEL, power, and `sd` on the scope.

**4. Bit-exact chain (`compare`).** Decode `bclk`/`ws`/`sd` as I2S (24 bits,
MSB first, data one bclk after ws changes) and `pcm_*` as SPI (mode 0, 16 bits,
MSB first, CS active low). Trigger on `reset_b` rising (P34, probe at SW0), press SW0, and
record about 100 ms with a 1 kHz tone from a phone. Export both decoded lists
and run:

```bash
python hw_capture.py compare i2s.csv pcm.csv --i2s-column <col> --pcm-column <col> --every 2
```

(`--every 2` if the I2S export has both channels.) PASS means the hardware
sum of 3 and DC removal match the model on real mic data.

**5. Frames (`frames`).** Decode `frm_*` as SPI (same settings), record at
least 3 frames (60 ms), export, and run:

```bash
python hw_capture.py --fs <ws/3> frames frames.csv --plot frame.png
```

It checks that frame numbers count up by 1, that each frame starts with the
last 200 samples of the one before (so the ring buffer order is right), that
the DC is near 0, and it reports the loudest frequency. With a 1 kHz tone
that should be about 1 kHz, give or take one 30.5 Hz bin.

The logic analyzer must sample each SPI clock at least 4 times (6 MS/s or more
for 1.5 MHz). A 60 ms capture at 6 MS/s is 360k samples, so use the
analyzer's record/streaming mode if its buffer is smaller.

**6. Samples to the PC over USB (no analyzer).** Every `pcm` sample also goes out of
FPGA pin 14 to the UPduino's FT232H, so it appears on the board's USB serial
port. After programming, from `fpga/model` in PowerShell:

```
py ftdi_reset.py
py serial_capture.py --seconds 4 --out captures/NAME.bin
```

Then open `fpga/model/hw_fft.ipynb` to plot the samples and run 512-point FFTs
on them. On 11/10/26: the clock measured 12.034 MHz (fs 15,670 Hz), 1 kHz,
500 Hz and 2.5 kHz tones from a monitor speaker all landed within 1/3 bin,
and a 290 Hz to 5 kHz sweep tracked cleanly.

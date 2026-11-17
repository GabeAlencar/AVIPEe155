# Signal chain math

`avipe_chain.ipynb` works through the AVIPE signal chain as plain math, one step per cell:

mic → sum of 3 → DC removal → 512-sample frames → FFT → frame to MCU → Hamming window and magnitude

- The first code cell holds every input: the test signal, the bit widths, the averaging shift, the frame size and hop, and the FFT output bits. Change it and run all cells.
- Each step ends with a plot or a table, and checks the result against the formula for it (sum-of-3 gain, DC decay, tone amplitudes, Hamming equivalence).

## Run

```bash
cd fpga/model
uv venv .venv
uv pip install --python .venv/bin/python numpy matplotlib pandas jupyter
.venv/bin/jupyter lab avipe_chain.ipynb
```

You can also open the notebook in VS Code (from WSL) and pick `.venv/bin/python` as the kernel.

# Hardware data

`hw_fft.ipynb` runs the same frame math (512 points, hop 312, Hamming window) on real `pcm`
samples from the FPGA, recorded with `mic_hw_test_top` programmed:

- `serial_capture.py` records samples from the UPduino's USB serial port (FPGA pin 14 drives the
  FT232H RXD). Run it with Windows Python, which can open the COM port: `py serial_capture.py
  --seconds 4 --out captures/NAME.bin`. It finds the baud rate (the internal oscillator is not
  exactly 12 MHz) and writes `NAME.bin` and `NAME.json`.
- `ftdi_reset.py` puts the FT232H back in serial mode. Run it once after each programming, since
  the Radiant programmer leaves it in SPI mode.
- The notebook measures the real sample rate from a capture of a known tone (`tone1k`).

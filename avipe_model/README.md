# Signal chain math

`avipe_chain.ipynb` works through the AVIPE signal chain as plain math, one step per cell:

mic → sum of 3 → DC removal → 512-sample frames → FFT → frame to MCU → Hamming window and magnitude

- The first code cell holds every input: the test signal, the bit widths, the averaging shift, the frame size and hop, and the FFT output bits. Change it and run all cells.
- Each step ends with a plot or a table, and checks the result against the formula for it (sum-of-3 gain, DC decay, tone amplitudes, Hamming equivalence).

## Run

```bash
cd fpga/model
uv venv .venv
uv pip install --python .venv/bin/python numpy matplotlib pandas jupyter scipy sounddevice
.venv/bin/jupyter lab avipe_chain.ipynb
```

`SOURCE` in the first code cell picks the input: `tone`, `chirp`, `speech`, `click`, `silence`, a `wav` file, or your `mic`. With `mic`, the last cell plots the chain live (needs the PortAudio system package, e.g. `pacman -S portaudio`).

You can also open the notebook in VS Code (from WSL) and pick `.venv/bin/python` as the kernel.

# AVIPE

Final project for E155 (MicroPs) at Harvey Mudd College. The project website is
at <https://gabealencar.github.io/AVIPEe155/>.

## Where to find things

| Folder | Contents |
|---|---|
| `docs/` | Quarto source for the project website |
| `fpga/src/` | SystemVerilog source |
| `fpga/sim/` | Testbenches |
| `fpga/Lattice/` | Lattice Radiant project |
| `mcu/src/` | MCU application code |
| `mcu/lib/` | MCU device drivers |
| `mcu/Segger/` | SEGGER Embedded Studio project |

## Website

Preview the website locally from `docs/`:

```bash
quarto preview
```

Publish it to GitHub Pages from `docs/`:

```bash
quarto publish gh-pages
```

Every page that still needs content has a "To do" callout. List the remaining
items from the root of the repository with:

```bash
grep -rn 'title="To do"' docs --include=*.qmd
```

# RTL Design
## AGV Embedded Systems Marathon

## Prerequisites

Install Icarus Verilog, which provides both the `iverilog` compiler and the
`vvp` simulation runtime.

On Debian or Ubuntu:

```sh
sudo apt-get update
sudo apt-get install iverilog
```

## Usage

Run the complete self-checking test suite:

```sh
make
```

The `test` target is an alias for the complete suite:

```sh
make test
```

Run an individual testbench with one of these targets:

```sh
make test-sccb_sequencer
make test-line_buffer
make test-ov7670_capture
make test-stream_edge
make test-frame_buffer_bram
make test-agv_top
```

Each target compiles the RTL and testbench with `iverilog`, then runs the
resulting simulation with `vvp`. Compiled simulation files are written to
`build/`. Remove them with:

```sh
make clean
```

## Quartus / DE0-Nano pin assignments

[`agv_top.qsf`](./agv_top.qsf) contains the Quartus project settings and the
standard DE0-Nano `EP4CE22F17C6` pin assignments for the top-level
[`agv_top`](./src/agv_top.v) module. The signals are grouped on the headers as
follows:

| Header | Signals |
| --- | --- |
| `GPIO_0[0..15]` | OV7670 `cam_pclk`, `cam_href`, `cam_vsync`, `cam_d[7:0]`, `cam_xclk`, `cam_sioc`, `cam_siod`, `cam_reset`, `cam_pwdn` |
| `GPIO_1[0..13]` | VGA `vga_hsync`, `vga_vsync`, `vga_r[3:0]`, `vga_g[3:0]`, `vga_b[3:0]` |
| Board pins | `clk50` = 50 MHz oscillator, `rst_n` = `KEY[0]`, `led_config_done` = `LED[0]` |

Open `agv_top.qsf` in Quartus, or create a Quartus project whose top-level
entity is `agv_top` and add this file as the project's settings file. The
camera data/control lines and VGA outputs are 3.3 V LVTTL FPGA signals.
`cam_sioc` and `cam_siod` require external SCCB pull-ups. Connect the VGA
outputs through a suitable resistor DAC and verify the camera module's voltage
levels before connecting it to the headers. The QSF has not been validated by
physical-board bring-up yet.

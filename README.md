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

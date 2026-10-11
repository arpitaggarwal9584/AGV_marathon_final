# AGV Vision Pipeline: Camera to VGA Edge Detection on FPGA

Project reference. Author: Arpit Aggarwal (Roll No. 25EC10087), IIT Kharagpur. Date: 09 October 2026.

Figures in the Word version: Figure 2.1 (block diagram by clock domain), Figure 7.1 (buffer use over time), Figure 10.1 (simulated input image vs. VGA output). Their content is described in the text.

## 1. Overview

The AGV vision front end turns live video from an OV7670 camera module into a binary edge map and shows that map on a VGA monitor, entirely inside an FPGA. The camera is configured for 320 x 240 (QVGA) RGB565 output. Each pixel is converted to an 8-bit grayscale value, passed through a streaming 3 x 3 Sobel edge detector, reduced to a single edge or no-edge bit, and stored in a double-buffered frame store built from on-chip block RAM. A VGA controller reads that store and displays it at the standard 640 x 480, 60 Hz mode, drawing every stored pixel as a 2 x 2 block so the image fills the screen.

The target is an Intel Cyclone IV FPGA on a DE0-Nano class board with a 50 MHz clock. Every module is written in synthesizable Verilog-2001 and has been verified in simulation with self-checking testbenches, including an end-to-end test that drives a full 320 x 240 frame from a camera model to the VGA pins. Synthesis and bring-up on the physical board have not been carried out yet.

This reference describes the whole project: the system architecture, the decisions that shaped it, the behaviour and interface of every module, the verification performed and its results, the source files, and the items still open.

| **Item**                            | **Value**                                                                     |
|-------------------------------------|-------------------------------------------------------------------------------|
| Target device                       | Intel Cyclone IV (DE0-Nano class board), 50 MHz board clock                   |
| Camera                              | OmniVision OV7670, configured over SCCB at device address 0x42                |
| Image size and format at the sensor | 320 x 240 (QVGA), RGB565, two bytes per pixel                                 |
| Processing                          | RGB565 to 8-bit gray, 3 x 3 Sobel, \|Gx\| + \|Gy\| \> threshold (default 64)  |
| Stored image                        | 1 bit per pixel, 76,800 bits per frame, two frames in block RAM               |
| Display                             | VGA 640 x 480 at 60 Hz, 25 MHz pixel clock, 2x upscaled, white edges on black |
| Clock domains                       | clk50 (configuration), pclk (camera side), clk25 (VGA side)                   |
| Language and tools                  | Verilog-2001; Icarus Verilog for simulation; Quartus for synthesis (pending)  |
| Status                              | All modules pass simulation; hardware bring-up pending                        |

*Table 1.1 — The project at a glance*

## 2. System Architecture

The design is a single streaming pipeline with one storage stage. Configuration logic writes the camera's registers once at power-up. After that, pixel bytes flow from the camera through capture, grayscale conversion and edge detection without ever being stored as a full colour frame. Only the final 1-bit edge map is stored, and only because the camera and the monitor produce and consume pixels on independent schedules.

*Figure 2.1 — Signal path from the camera to the monitor, grouped by clock domain*

Three clock domains exist, and only one boundary between them carries image data. The camera produces its own pixel clock (PCLK), and everything from capture up to the write side of the frame buffer runs on it. The VGA controller and the read side of the frame buffer run on a 25 MHz clock produced inside the FPGA. Because these two clocks are unrelated, the frame buffer is also the clock-domain crossing point, and it is the only place in the design where synchronizers are needed. The SCCB configuration logic runs on the 50 MHz board clock and has no data connection to the other two domains.

| **Domain** | **Source**                                       | **Frequency**                                   | **Modules**                                                      |
|------------|--------------------------------------------------|-------------------------------------------------|------------------------------------------------------------------|
| clk50      | Board oscillator                                 | 50 MHz                                          | sccb_sequencer, sccb_master, xclk_gen                            |
| pclk       | OV7670 PCLK output                               | Set by the sensor (derived from XCLK and CLKRC) | ov7670_capture, img_edge_stream, write side of frame_buffer_bram |
| clk25      | clk50 divided by 2 (also drives the camera XCLK) | 25 MHz                                          | Read side of frame_buffer_bram, vga_display                      |

*Table 2.1 — Clock domains*

Per frame, the camera sends 240 rows of 640 bytes. The capture stage pairs the bytes into 320 RGB565 pixels per row, the edge pipeline emits exactly one edge bit per pixel, and the frame buffer therefore receives exactly 76,800 bits per frame. The VGA side reads each stored bit four times per displayed frame (twice along a line, on two consecutive lines).

## 3. Design Evolution and Key Decisions

### 3.1 From full-frame processing to streaming

The first plan was to store each camera frame and then process it. A single 640 x 480 RGB565 frame occupies more than 600 KB, far beyond the on-chip memory of a Cyclone IV, so the processing stage was redesigned as a streaming pipeline. A 3 x 3 Sobel window only ever needs the current row and the two rows above it, so two line buffers of one row each replace the full frame. This is the standard line-buffer technique used in FPGA image pipelines, and it reduces the processing memory from a whole frame to a few kilobits.

### 3.2 The SDRAM frame buffer and why it was dropped

A frame store is still required between the camera and the monitor, because the two run on independent clocks and cannot be locked pixel for pixel. At 640 x 480 the 1-bit edge map needs 307,200 bits per frame, or 614,400 bits for two buffers. That exceeds the roughly 594 Kbit (608,256 bit) of embedded memory in the EP4CE22 device on the DE0-Nano, so the first frame-buffer design used the board's external SDRAM.

That design packed edge bits into 16-bit words, moved them across clock domains through Gray-code asynchronous FIFOs, read them back in bursts through a prefetch FIFO, shared a single memory port through a read/write arbiter, and signalled frame boundaries with toggle-based pulse synchronizers. Simulation exposed a chain of timing hazards. These included a double read in the pixel unpacker, fetching starting before any buffer had been written, the buffer-select flag switching before the queued writes had actually reached memory, and a one-cycle misread of the FIFO's registered output. Most were fixed, but a recurring race at buffer swaps remained, and the complexity was out of proportion to the goal.

The resolution was therefore reduced to 320 x 240. A 1-bit QVGA frame is 76,800 bits and two of them are 153,600 bits, which fits comfortably in block RAM. Block RAM writes complete in the same clock cycle they are issued, so the whole class of write-completion races disappears, and the arbiter, FIFOs and burst logic are no longer needed. The SDRAM design was abandoned at this point.

| **Decision**                                 | **Alternative considered**       | **Reason**                                                                              |
|----------------------------------------------|----------------------------------|-----------------------------------------------------------------------------------------|
| Streaming Sobel with two line buffers        | Store a full frame, then process | A full frame does not fit on chip; a 3 x 3 window needs only two previous rows          |
| 320 x 240 camera resolution                  | 640 x 480                        | Lets the double frame buffer fit in on-chip block RAM                                   |
| Frame buffer in block RAM                    | External SDRAM                   | No controller, arbiter or FIFOs; writes land in the same cycle, removing the swap races |
| Store 1 bit per pixel                        | Store gray or RGB values         | Only the edge decision is displayed; 1 bit keeps the buffer at 76,800 bits              |
| Double buffering                             | Single buffer                    | The camera can write one frame while the display reads a complete one                   |
| Buffer swap only at the VGA vertical blank   | Switch buffers at any time       | Each displayed frame comes from one buffer, so frames never tear                        |
| 640 x 480 output with 2x upscaling           | A 320 x 240 video mode           | Monitors do not accept 320 x 240; 640 x 480 at 60 Hz is the lowest standard mode        |
| Magnitude as \|Gx\| + \|Gy\|                 | Square root of Gx² + Gy²         | Adders only, no multiplier or square root                                               |
| One edge output per input pixel              | Skip border pixels               | Keeps every stored row exactly 320 wide                                                 |
| Register values from the Linux OV7670 driver | Values from forum examples       | A widely used, field-tested reference for the same sensor                               |

*Table 3.1 — Key design decisions*

## 4. Camera Configuration over SCCB

The OV7670 has two separate interfaces: a parallel pixel bus (D\[7:0\], HREF, VSYNC, PCLK) and a slow two-wire configuration bus called SCCB. SCCB is electrically compatible with I2C, with open-drain clock and data lines (SIO_C, SIO_D) that need pull-up resistors. Every write uses the same three-byte shape: device address 0x42, register address, and value, each byte followed by one acknowledge slot. The configuration logic is split into two modules in ov7670_sccb_config.v.

### 4.1 sccb_master

The master performs one complete write transaction per start pulse. Each bit cell is divided into four equal sub-phases of CLK_DIV system clocks. SDA changes only in the first sub-phase while SCL is low, and SCL is high for the last two sub-phases, when the camera samples the bit. With CLK_DIV = 125 and a 50 MHz clock, one bit takes 500 cycles, giving a 100 kHz SCL. START is SDA falling while SCL is high, and STOP is SDA rising while SCL is high. The master releases SDA during every acknowledge slot but does not check the value the camera drives. This is a deliberate simplification that is acceptable for a fixed, trusted register table on a single-device bus.

| **State**  | **Action**                                                               |
|------------|--------------------------------------------------------------------------|
| IDLE       | Bus idle (SCL and SDA high); waits for start, loads the device address   |
| START_COND | Drives SDA low while SCL is high                                         |
| SHIFT_BYTE | Sends 8 bits, most significant bit first                                 |
| ACK_BIT    | Releases SDA for one bit cell, then loads the next byte or moves to STOP |
| STOP_COND  | Drives SDA high while SCL is high                                        |
| DONE_ST    | Pulses done for one cycle and returns to IDLE                            |

*Table 4.1 — sccb_master states*

### 4.2 sccb_sequencer

The sequencer walks a fixed table of register and value pairs and hands each pair to the master. After the first entry (a software reset) it waits RESET_WAIT cycles, 5,000,000 by default or about 100 ms at 50 MHz, so the sensor can settle. After the table, a final write sets COM15 for full-range RGB565, and config_done then goes high. Each transaction takes about 0.3 ms, so the full sequence takes roughly 104 ms, almost all of it the post-reset wait.

| **\#** | **Register** | **Address** | **Value** | **Meaning**                                       |
|--------|--------------|-------------|-----------|---------------------------------------------------|
| 0      | COM7         | 0x12        | 0x80      | Software reset of all registers                   |
| 1      | CLKRC        | 0x11        | 0x01      | Internal clock prescaler                          |
| 2      | TSLB         | 0x3A        | 0x04      | Output sequence setting                           |
| 3      | COM7         | 0x12        | 0x00      | Leave reset, default format                       |
| 4      | HSTART       | 0x17        | 0x15      | Horizontal window start, high 8 bits              |
| 5      | HSTOP        | 0x18        | 0x03      | Horizontal window stop, high 8 bits               |
| 6      | HREF         | 0x32        | 0x80      | Low 3 bits of the horizontal start and stop       |
| 7      | VSTART       | 0x19        | 0x03      | Vertical window start, high 8 bits                |
| 8      | VSTOP        | 0x1A        | 0x7B      | Vertical window stop, high 8 bits                 |
| 9      | VREF         | 0x03        | 0x00      | Low 2 bits of the vertical start and stop         |
| 10     | COM10        | 0x15        | 0x00      | No inversion of HREF, VSYNC or PCLK               |
| 11     | COM7         | 0x12        | 0x14      | QVGA (0x10) and RGB output (0x04)                 |
| 12     | COM15        | 0x40        | 0xD0      | RGB565 (0x10) with full 0x00 to 0xFF range (0xC0) |

*Table 4.2 — Register writes sent at power-up, in order*

### 4.3 Deriving the QVGA window values

The Linux kernel OV7670 driver describes each resolution by four window numbers (hstart, hstop, vstart, vstop) and converts them into register bytes. The high bits go into HSTART, HSTOP, VSTART and VSTOP, and the leftover low bits are packed into HREF and VREF:

> HSTART = (hstart \>\> 3) & 0xFF HSTOP = (hstop \>\> 3) & 0xFF
>
> HREF = 0x80 \| (hstop & 7) \<\< 3 \| (hstart & 7)
>
> VSTART = (vstart \>\> 2) & 0xFF VSTOP = (vstop \>\> 2) & 0xFF
>
> VREF = 0x00 \| (vstop & 3) \<\< 2 \| (vstart & 3)

The method was checked by recomputing the earlier 640 x 480 register bytes from the driver's VGA window numbers. All six bytes matched exactly. The same formula applied to the QVGA window numbers gives the values in Table 4.2.

| **Quantity**                 | **VGA (640 x 480)** | **QVGA (320 x 240)** |
|------------------------------|---------------------|----------------------|
| Window numbers hstart, hstop | 158, 14             | 168, 24              |
| Window numbers vstart, vstop | 10, 490             | 12, 492              |
| HSTART, HSTOP                | 0x13, 0x01          | 0x15, 0x03           |
| HREF                         | 0xB6                | 0x80                 |
| VSTART, VSTOP                | 0x02, 0x7A          | 0x03, 0x7B           |
| VREF                         | 0x0A                | 0x00                 |
| Format bit in COM7           | 0x00                | 0x10 (COM7_FMT_QVGA) |

*Table 4.3 — Window numbers and resulting register bytes*

## 5. Pixel Capture

The camera needs an input clock on its XCLK pin. xclk_gen produces 25 MHz by toggling a flip-flop on the 50 MHz board clock, which is inside the OV7670's accepted input range. The same 25 MHz signal is used as the VGA pixel clock.

ov7670_capture runs on PCLK and turns the byte stream into pixels. With COM10 at its default, VSYNC is high during vertical blanking and low while a frame is being sent, and HREF is high only while a row's valid bytes are on D\[7:0\]. Every PCLK edge with HREF high carries one byte. The first byte of each pair is the high byte of an RGB565 pixel, and pairing restarts at the beginning of every row. The module produces four outputs, all synchronous to PCLK:

| **Output**  | **Width** | **Meaning**                                                                           |
|-------------|-----------|---------------------------------------------------------------------------------------|
| pixel_valid | 1         | One-cycle pulse when pixel_data holds a new pixel                                     |
| pixel_data  | 16        | RGB565 pixel {high byte, low byte}                                                    |
| line_end    | 1         | One-cycle pulse on the falling edge of HREF (the cycle after the last pixel of a row) |
| frame_start | 1         | One-cycle pulse on the falling edge of VSYNC, before the first row of a frame         |

*Table 5.1 — ov7670_capture outputs*

The capture logic depends only on HREF and VSYNC, not on any resolution count, so it works unchanged at 320 x 240.

## 6. Sobel Edge-Detection Pipeline

The edge pipeline is wrapped in img_edge_stream (file stream_edge_pipeline.v) and is built from three stages, all clocked by PCLK.

### 6.1 Grayscale conversion

rgb565_to_gray is purely combinational. It expands the 5, 6 and 5 bit colour fields to 8 bits by repeating their top bits, then applies integer luma weights that sum to 256: Y = (77 R + 150 G + 29 B) / 256. This approximates the standard 0.299, 0.587, 0.114 weighting using only small multiplications by constants and a shift.

### 6.2 The 3 x 3 window generator

line_buffer_3x3 (file line_buffer_3x3.v, parameter IMG_WIDTH = 320) keeps two row memories of 320 x 8 bits. At any moment one holds the row directly above the incoming pixel (the fresh row) and the other holds the row two above (the stale row). For each incoming pixel, both memories are read at the current column, and the stale one is then overwritten with the new pixel. At the end of each row the two roles swap. Small shift registers hold the last two values of each row so that a full 3 x 3 window is available. win_valid is high only when two complete rows have been buffered and the column index is at least 2. A second output, pix_out_valid, pulses for every input pixel, whether or not the window is complete.

### 6.3 Sobel operator and threshold

sobel_edge applies the two standard kernels, adds the absolute values of the results and compares the sum with THRESHOLD (default 64). The output is registered, adding one cycle of latency.

| **Kernel** | **Row 1** | **Row 2** | **Row 3** | **Responds to**                    |
|------------|-----------|-----------|-----------|------------------------------------|
| Gx         | -1 0 +1   | -2 0 +2   | -1 0 +1   | Vertical edges (horizontal change) |
| Gy         | -1 -2 -1  | 0 0 0     | +1 +2 +1  | Horizontal edges (vertical change) |

*Table 6.1 — Sobel kernels*

The edge pipeline emits exactly one edge_valid pulse for every input pixel. Pixels without a complete neighbourhood (the first two rows and the first two columns of each row) are output as 0. This is required by the frame buffer, which writes one address per pulse: if border pixels were skipped, each stored row would be 318 bits long and the stored image would slant diagonally. The window's centre is one row above and one column left of the pixel that has just arrived, so the stored edge map is shifted one pixel down and right relative to the camera image. That is a 2-pixel offset on screen and is harmless. The total latency from an input pixel to its edge output is two PCLK cycles.

## 7. Frame Buffer in Block RAM

frame_buffer_bram.v contains dp_bram, a 1-bit-wide simple dual-port RAM with separate write and read clocks, and frame_buffer_bram, which uses two instances of it (76,800 entries each, 17-bit addresses) as alternating buffers. dp_bram uses one always block per clock with a registered read, which is the pattern Quartus recognises as dual-clock block RAM.

### 7.1 Write side (pclk domain)

The write address resets to 0 on every frame_start and increments on every pix_valid pulse. A select bit, cur_wbuf, chooses which buffer receives writes. It toggles on every frame_start except the first one after reset, because before the first frame there is no finished buffer to hand over. The first toggle also sets a sticky flag, buf_ready_w, meaning one complete frame now exists. Because block RAM writes take effect in the same cycle, the buffer that cur_wbuf has just left is already complete at the moment of the toggle.

### 7.2 Crossing into the VGA domain

Only two single-bit signals cross from pclk to clk25: cur_wbuf and buf_ready_w. Each passes through its own two-flip-flop synchronizer. A single bit cannot arrive half-changed, so a two-flip-flop synchronizer is sufficient for both.

### 7.3 Read side (clk25 domain)

The VGA controller supplies the read address directly (rd_addr_in), which is what allows the 2x upscale. The buffer to read is chosen only at the VGA controller's frame_start pulse, which marks the start of vertical blanking. At that moment, if the synchronized ready flag is set, the read side selects the buffer that is not being written and sets disp_en. Because the selection changes only during blanking, every displayed frame is read from one buffer from top to bottom. Because disp_en turns on only at a frame boundary, the first valid pixel ever shown is pixel 0 of a frame.

Data is returned two clocks after its address: one for the RAM's registered read and one for the output register. The buffer selection, the request flag and the enable flag are delayed by one clock alongside the address, so the output multiplexer always uses the selection that was in force when that address was issued. pixel_valid is high only for real requests made while the display is enabled.

*Figure 7.1 — Buffer use over time: the display stays blank until the first frame is complete, then always reads the buffer not being written*

### 7.4 Memory budget

Storing one bit per pixel at QVGA keeps the memory use well inside the device:

| **Storage**    | **Size**     | **Notes**                                                             |
|----------------|--------------|-----------------------------------------------------------------------|
| Frame buffer 0 | 76,800 bits  | 320 x 240 x 1 bit                                                     |
| Frame buffer 1 | 76,800 bits  | 320 x 240 x 1 bit                                                     |
| Line buffers   | 5,120 bits   | 2 rows x 320 x 8 bits                                                 |
| Total          | 158,720 bits | About 26 percent of the 608,256 bits of embedded memory in an EP4CE22 |

*Table 7.1 — On-chip memory use*

### 7.5 Behaviour at buffer swaps

The displayed image is one camera frame behind the newest frame, which is inherent to double buffering. There is also a narrow window at each swap: the synchronized select bit takes a few clk25 cycles to settle, and if the VGA vertical blank falls inside that window, the display keeps the previous complete frame for one more refresh. The image is never corrupted or torn; at worst it is one extra frame old for a single refresh. Removing even this would require a request and acknowledge handshake between the two clock domains, which was judged unnecessary.

## 8. VGA Display

vga_display generates standard 640 x 480 at 60 Hz timing from the 25 MHz clock. The exact standard pixel clock is 25.175 MHz; 25.000 MHz is within the tolerance that monitors accept. Both sync signals are active low in this mode.

| **Direction**       | **Visible** | **Front porch** | **Sync pulse** | **Back porch** | **Total** |
|---------------------|-------------|-----------------|----------------|----------------|-----------|
| Horizontal (pixels) | 640         | 16              | 96             | 48             | 800       |
| Vertical (lines)    | 480         | 10              | 2              | 33             | 525       |

*Table 8.1 — 640 x 480 at 60 Hz timing*

Two counters track the screen position. While the position is in the visible area, the controller requests the stored pixel at half the screen coordinates:

> rd_addr = (y/2) \* 320 + (x/2)
>
> = ((y/2) \<\< 8) + ((y/2) \<\< 6) + (x/2)

The multiplication by 320 becomes two shifts and an add, so no hardware multiplier is needed. Each stored pixel is read for two neighbouring screen pixels on two consecutive lines, filling the screen without any extra memory. The frame_start pulse sent to the frame buffer occurs at the start of line 480, the first line of vertical blanking. The frame buffer returns data two clocks after the address and the colour output is registered once more, so HSYNC and VSYNC are delayed by three clocks to stay aligned with the picture. The colour outputs are 4 bits per channel: all ones for an edge pixel, zero otherwise, and always zero during blanking or before the first frame is ready.

## 9. Top-Level Integration

agv_top connects every block. It holds the camera's RESET pin high and its PWDN pin low, generates the 25 MHz clock, starts the SCCB sequencer from reset, and wires capture, edge detection, the frame buffer and the VGA controller together, as shown in Figure 2.1.

| **Port**                                    | **Direction** | **Description**                                  |
|---------------------------------------------|---------------|--------------------------------------------------|
| clk50                                       | in            | 50 MHz board clock                               |
| rst_n                                       | in            | Active-low reset (push button)                   |
| cam_pclk, cam_href, cam_vsync, cam_d\[7:0\] | in            | OV7670 pixel bus                                 |
| cam_xclk                                    | out           | 25 MHz clock to the camera                       |
| cam_sioc, cam_siod                          | out, inout    | SCCB clock and data (external pull-ups required) |
| cam_reset, cam_pwdn                         | out           | Held at 1 and 0 to keep the camera running       |
| vga_hsync, vga_vsync                        | out           | Active-low sync pulses                           |
| vga_r, vga_g, vga_b \[3:0\]                 | out           | 4-bit colour outputs                             |
| led_config_done                             | out           | High once the camera has been configured         |

*Table 9.1 — agv_top ports*

Two parameters are exposed: RESET_WAIT (camera settle time after reset, default 5,000,000 cycles) and THRESHOLD (Sobel edge threshold, default 64; a higher value shows fewer edges). The files to add to a Quartus project are agv_top.v, ov7670_sccb_config.v, ov7670_capture.v, stream_edge_pipeline.v, line_buffer_3x3.v, frame_buffer_bram.v and vga_display.v.

The DE0-Nano has no VGA connector, so the colour and sync outputs must reach a VGA socket through the GPIO header, with a resistor network converting the 4-bit outputs into the 0 to 0.7 V analogue colour levels a monitor expects.

## 10. Verification

All verification was done in Icarus Verilog with self-checking testbenches that print an explicit PASS or FAIL. Four principles were applied throughout. Expected results are computed independently inside the testbench (a golden Sobel model, a known register table, known frame patterns) rather than read back from the design's own internal signals. Bus-level behaviour is observed from outside, for example a slave model that decodes SCCB bytes from the wires, or screen coordinates rebuilt purely from the HSYNC and VSYNC pins. Camera and display clocks run at unrelated periods, so the clock-domain crossing is genuinely exercised. Subsystems are first tested at a small size so every bit can be traced, and the complete system is then tested at the full 320 x 240 size.

| **Testbench**          | **Unit tested**             | **What it checks**                                                                                               | **Result**                      |
|------------------------|-----------------------------|------------------------------------------------------------------------------------------------------------------|---------------------------------|
| tb_sccb_sequencer.v    | sccb_sequencer, sccb_master | Slave model decodes all 13 writes from SIO_C/SIO_D and compares them with Table 4.2                              | PASS, 13 of 13 writes match     |
| tb_ov7670_capture.v    | ov7670_capture              | Byte pairing, line_end and frame_start timing on a small two-row frame                                           | PASS                            |
| tb_line_buffer.v       | line_buffer_3x3             | Every 3 x 3 window on a 6 x 6 image with unique pixel values                                                     | PASS, 16 of 16 windows          |
| tb_stream_edge.v       | img_edge_stream             | Output count and every output bit against a golden Sobel on a 12 x 10 image                                      | PASS, 120 of 120 outputs        |
| tb_frame_buffer_bram.v | frame_buffer_bram           | Startup blanking, no mixing of frames within a displayed frame, in-order frame progression with unrelated clocks | PASS, 53 frames, 0 mismatches   |
| tb_agv_top.v           | Complete system             | Full 320 x 240 camera image to VGA pins; VGA timing; all 307,200 visible pixels against golden\[y/2\]\[x/2\]     | PASS, 307,200 of 307,200 pixels |

*Table 10.1 — Testbenches and results*

In the end-to-end test, a camera model sends a 320 x 240 image containing a bright rectangle and a mid-gray square with realistic HREF and VSYNC timing on its own clock. The testbench also checks the VGA timing measured at the pins: 800 clocks per line, a 96-clock HSYNC pulse, 525 lines per frame and a 2-line VSYNC pulse. Figure 10.1 shows the input image and the picture rebuilt from the VGA output pins, which matches the reference edge map pixel for pixel.

*Figure 10.1 — End-to-end simulation: the camera test image and the 640 x 480 edge map captured at the VGA pins*

Verification also caught several design faults, which were corrected before the results above were obtained:

| **Problem found**                                                                      | **Effect**                                                                  | **Correction**                                                          |
|----------------------------------------------------------------------------------------|-----------------------------------------------------------------------------|-------------------------------------------------------------------------|
| An older, untested copy of the window generator was embedded in the edge pipeline file | Possible duplicate-module conflict and unproven logic in the main data path | Removed; the pipeline uses the verified line_buffer_3x3.v               |
| Border pixels produced no output                                                       | 318 outputs per row, so the stored image would slant                        | One output per input pixel, with borders set to 0                       |
| Display enable could switch on mid-frame                                               | The first displayed frame started part-way through the image                | Enable is latched only at the VGA frame boundary                        |
| An extra address register in the read path                                             | Data arrived one clock after its valid flag                                 | The VGA address drives the RAM directly; latency is fixed at two clocks |

*Table 10.2 — Faults found and corrected during verification*

## 11. Source File Inventory

The active design consists of seven source files and six testbenches. Files from the abandoned SDRAM design remain for reference only and are not part of the build.

| **File**                                   | **Modules**                                 | **Status**                              |
|--------------------------------------------|---------------------------------------------|-----------------------------------------|
| agv_top.v                                  | agv_top                                     | Active: top level                       |
| ov7670_sccb_config.v                       | sccb_master, sccb_sequencer                 | Active: QVGA configuration              |
| ov7670_capture.v                           | xclk_gen, ov7670_capture                    | Active                                  |
| stream_edge_pipeline.v                     | rgb565_to_gray, sobel_edge, img_edge_stream | Active                                  |
| line_buffer_3x3.v                          | line_buffer_3x3                             | Active                                  |
| frame_buffer_bram.v                        | dp_bram, frame_buffer_bram                  | Active                                  |
| vga_display.v                              | vga_display                                 | Active                                  |
| tb\_\*.v (six files in Table 10.1)         | Testbenches                                 | Active, all passing                     |
| sdram_bridge.v, tb_sdram_bridge.v          | SDRAM frame-buffer bridge                   | Superseded; unresolved swap race        |
| async_fifo.v, pulse_sync.v and testbenches | Gray-code async FIFO, pulse synchronizer    | Verified but unused in the final design |

*Table 11.1 — Source files*

The complete system simulation is run with:

> iverilog -g2012 -o sim tb_agv_top.v agv_top.v ov7670_capture.v \\
>
> ov7670_sccb_config.v stream_edge_pipeline.v line_buffer_3x3.v \\
>
> frame_buffer_bram.v vga_display.v
>
> vvp sim

## 12. Known Limitations and Next Steps

The design is complete in simulation. The items below remain before and during hardware bring-up.

| **Item**                           | **Detail**                                                                                          | **Suggested action**                                                                                         |
|------------------------------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| Hardware not yet tested            | Only simulation has been carried out                                                                | Synthesize in Quartus, assign pins, check resource and timing reports                                        |
| Clock generation                   | 25 MHz is made with a flip-flop divider                                                             | Use the Cyclone IV PLL; declare clk50, clk25 and pclk as asynchronous clock groups in the timing constraints |
| Line buffer memory style           | The row memories are read combinationally, which may be built from logic cells instead of block RAM | Check the fitter report; if needed, rewrite with registered reads                                            |
| QVGA image size on the real sensor | Only window and format registers are written; no scaling registers are set                          | Confirm 640 bytes per HREF and 240 rows with a logic analyser; add scaling registers if the count differs    |
| SCCB acknowledge not checked       | A missing or miswired camera is not detected                                                        | Read back the product ID register (0x0A should read 0x76) during bring-up                                    |
| Fixed edge threshold               | Lighting changes the best threshold                                                                 | Tune THRESHOLD on hardware, or make it switch-selectable                                                     |
| VGA output stage                   | The board has no VGA connector                                                                      | Build a resistor-ladder adapter on the GPIO header                                                           |
| Display behaviour                  | One frame of latency, rare one-refresh delay at swaps, 1-pixel offset                               | No action needed; documented and harmless                                                                    |

*Table 12.1 — Open items*

## 13. Conclusion

The project delivers a complete, verified FPGA pipeline that configures an OV7670 for 320 x 240 RGB565 output, detects edges in real time with a streaming Sobel filter, stores the 1-bit result in a double-buffered on-chip frame store, and displays it at 640 x 480 on a VGA monitor. The move from 640 x 480 with external SDRAM to 320 x 240 with block RAM was the decisive simplification. It removed the arbiter, FIFOs and write-latency races, and left a single, simple clock-domain crossing inside the frame buffer. Every module passes its own testbench, and the full system reproduces a reference edge map exactly at the VGA pins. The next phase is synthesis and bring-up on the board, guided by the open items in Table 12.1.

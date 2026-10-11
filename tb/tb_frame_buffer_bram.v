`timescale 1ns/1ps
module tb_frame_buffer_bram;

    localparam AW           = 4;
    localparam FRAME_PIXELS = 16;     // toy 4x4 "image"

    // --------------------------------------------------------------- clocks
    reg pclk    = 0;
    reg vga_clk = 0;
    always #4 pclk    = ~pclk;      // camera-side clock, period 8
    always #5 vga_clk = ~vga_clk;   // VGA-side clock, period 10 - unrelated

    reg rst_n     = 0;
    reg vga_rst_n = 0;
    initial begin
        rst_n = 0; vga_rst_n = 0;
        repeat (4) @(posedge pclk);
        rst_n = 1;
        repeat (4) @(posedge vga_clk);
        vga_rst_n = 1;
    end

    // ------------------------------------------------------------- DUT I/O
    reg  pix_valid, pix_data, frame_start;
    reg  vga_frame_start, pixel_req;
    wire pixel_valid, pixel_data, frame_ready;

    frame_buffer_bram #(
        .FRAME_PIXELS (FRAME_PIXELS),
        .AW           (AW)
    ) dut (
        .pclk            (pclk),
        .rst_n           (rst_n),
        .pix_valid       (pix_valid),
        .pix_data        (pix_data),
        .frame_start     (frame_start),

        .vga_clk         (vga_clk),
        .vga_rst_n       (vga_rst_n),
        .vga_frame_start (vga_frame_start),
        .pixel_req       (pixel_req),
        .pixel_valid     (pixel_valid),
        .pixel_data      (pixel_data),
        .frame_ready     (frame_ready)
    );

    // ------------------------------------------------------- camera model
    // Each camera frame gets its own bit pattern so a reader can identify
    // exactly which frame it is looking at: frame k's pixel i = bit i of
    // (k+1) rotated, giving a distinct, easy-to-check 16-bit word per frame.
    function [FRAME_PIXELS-1:0] frame_pattern(input integer k);
        frame_pattern = {FRAME_PIXELS{1'b0}} | ((16'hACE1 ^ (k * 16'h1357)) );
    endfunction

    integer NFRAMES;
    initial NFRAMES = 10;

    integer cf, ci;
    reg [FRAME_PIXELS-1:0] cur_pattern;

    initial begin
        pix_valid = 0; pix_data = 0; frame_start = 0;
        cur_pattern = {FRAME_PIXELS{1'b0}};
        @(posedge rst_n);
        repeat (3) @(posedge pclk);

        for (cf = 0; cf < NFRAMES; cf = cf + 1) begin
            cur_pattern = frame_pattern(cf);
            @(posedge pclk);
            frame_start <= 1'b1;
            @(posedge pclk);
            frame_start <= 1'b0;
            for (ci = 0; ci < FRAME_PIXELS; ci = ci + 1) begin
                @(posedge pclk);
                pix_valid <= 1'b1;
                pix_data  <= cur_pattern[ci];
                @(posedge pclk);
                pix_valid <= 1'b0;
                pix_data  <= 1'b0;
                repeat (2) @(posedge pclk);   // href-style gaps between pixels
            end
            // gap between camera frames (vertical blanking), several times
            // longer than a VGA frame so many VGA frames happen inside it
            repeat (40) @(posedge pclk);
        end
        // let the last frame's data get read a few more times, then stop
        repeat (200) @(posedge pclk);
        $display("================================================================");
        if (errors == 0)
            $display(" RESULT: PASS -- %0d VGA frames checked, 0 mismatches", vframe_count);
        else
            $display(" RESULT: FAIL -- %0d mismatches out of %0d VGA frames", errors, vframe_count);
        $display("================================================================");
        $finish;
    end

    // ------------------------------------------------------------ VGA model
    // Continuously requests pixels, much faster relative to its own frame
    // length than the camera produces frames, and declares its own
    // vga_frame_start periodically - fully asynchronous to the camera side.
    // One VGA "frame" = 1 frame_start slot (pixel_req low) + FRAME_PIXELS
    // pixel_req slots - the frame_start slot must NOT also count as a pixel
    // request, otherwise the read address's frame boundary (reset every
    // VGA_FRAME_LEN cycles) drifts out of alignment with the capture
    // checker's 16-pixels-per-frame grouping.
    localparam VGA_FRAME_LEN = FRAME_PIXELS + 1;

    integer vcount;
    integer errors;
    integer vframe_count;
    reg [FRAME_PIXELS-1:0] captured;
    integer cap_idx;
    reg      capturing;

    initial begin
        pixel_req       = 0;
        vga_frame_start = 0;
        vcount          = 0;
        errors          = 0;
        vframe_count    = 0;
        cap_idx         = 0;
        capturing       = 0;
        captured        = {FRAME_PIXELS{1'b0}};
        @(posedge vga_rst_n);
        repeat (3) @(posedge vga_clk);

        forever begin
            @(posedge vga_clk);
            if (vcount == 0) begin
                vga_frame_start <= 1'b1;
                pixel_req       <= 1'b0;
            end else begin
                vga_frame_start <= 1'b0;
                pixel_req       <= 1'b1;
            end
            vcount <= (vcount + 1) % VGA_FRAME_LEN;
        end
    end

    // Capture pixel_valid/pixel_data into "captured", one VGA-frame's worth
    // at a time, and check the completed word against known-good frames.
    // Uses a blocking assign to a plain variable (not the "captured" reg)
    // so the just-written bit is visible immediately, same simulation time
    // step, to the check_frame call below - no NBA-ordering helper needed.
    reg [FRAME_PIXELS-1:0] cap_word;
    // The DUT's output lags pixel_req by a fixed 2 cycles (BRAM read + output
    // register), so the checker's frame boundary is delayed by the same 2.
    reg vfs_d1, vfs_d2;
    always @(posedge vga_clk) begin vfs_d1 <= vga_frame_start; vfs_d2 <= vfs_d1; end
    always @(posedge vga_clk) begin
        if (!vga_rst_n || vfs_d2) begin
            if (vga_rst_n && cap_idx != 0) begin
                $display("[%0t] *** FAIL: VGA frame ended after only %0d valid pixels ***", $time, cap_idx);
                errors = errors + 1;
            end
            cap_idx  = 0;
            cap_word = {FRAME_PIXELS{1'b0}};
        end else if (pixel_valid) begin
            cap_word[cap_idx] = pixel_data;
            captured           = cap_word;
            if (cap_idx == FRAME_PIXELS-1) begin
                vframe_count = vframe_count + 1;
                check_frame(cap_word);
                cap_word = {FRAME_PIXELS{1'b0}};
                cap_idx  = 0;
            end else begin
                cap_idx = cap_idx + 1;
            end
        end
    end

    task check_frame(input [FRAME_PIXELS-1:0] word);
        integer k;
        reg found;
        begin
            found = 1'b0;
            if (!frame_ready) begin
                $display("[%0t] *** FAIL: full VGA frame captured (0x%04h) while frame_ready was still low ***",
                          $time, word);
                errors = errors + 1;
            end else begin
                for (k = 0; k < NFRAMES; k = k + 1) begin
                    if (word == frame_pattern(k))
                        found = 1'b1;
                end
                if (!found) begin
                    $display("[%0t] *** FAIL: VGA frame #%0d read 0x%04h, which matches NO known camera frame pattern ***",
                              $time, vframe_count, word);
                    errors = errors + 1;
                end else begin
                    $display("[%0t] VGA frame #%0d read 0x%04h -- matches a valid, complete camera-frame pattern",
                              $time, vframe_count, word);
                end
            end
        end
    endtask

    // Safety net
    initial begin
        #20000;
        $display("*** TIMEOUT ***");
        $finish;
    end

    initial begin
        $dumpfile("fb_bram_tb.vcd");
        $dumpvars(0, tb_frame_buffer_bram);
    end

endmodule

`timescale 1ns/1ps
// =============================================================================
// End-to-end testbench for agv_top at the REAL 320x240 size.
//
// A camera model sends a 320x240 RGB565 test image (a bright rectangle and a
// mid-gray square on black) with OV7670-style HREF/VSYNC timing on its own
// unrelated pclk. The testbench:
//   1. Computes a golden 320x240 Sobel edge map itself (same luma formula,
//      same threshold, same one-pixel down/right offset as the hardware).
//   2. Rebuilds screen coordinates purely from the VGA output pins (hsync /
//      vsync falling edges), not from the design's internal counters.
//   3. Checks the standard 640x480@60 timing: 800 clocks per line, 96-clock
//      hsync pulse, 525 lines per frame, 2-line vsync pulse.
//   4. For one complete VGA frame, checks all 640x480 visible pixels against
//      golden[y/2][x/2] (white = edge), and that colour is 0 in blanking.
// =============================================================================
module tb_agv_top;
    localparam W = 320, H = 240, TH = 64;

    // ---------------- clocks ----------------
    reg clk50 = 0;  always #10 clk50 = ~clk50;          // 50 MHz board clock
    reg pclk  = 0;  always #20.5 pclk = ~pclk;           // camera pclk, unrelated
    reg rst_n = 1;
    initial #1 rst_n = 0;   // real falling edge so async resets fire in simulation

    // ---------------- camera model signals ----------------
    reg       href = 0, vsync = 1;
    reg [7:0] d = 0;

    wire sioc, siod, xclk, cam_reset, cam_pwdn, cfg_done;
    wire hs, vs;
    wire [3:0] r, g, b;
    pullup (siod);

    agv_top #(.RESET_WAIT(32'd50), .THRESHOLD(TH)) dut (
        .clk50(clk50), .rst_n(rst_n),
        .cam_pclk(pclk), .cam_href(href), .cam_vsync(vsync), .cam_d(d),
        .cam_xclk(xclk), .cam_sioc(sioc), .cam_siod(siod),
        .cam_reset(cam_reset), .cam_pwdn(cam_pwdn),
        .vga_hsync(hs), .vga_vsync(vs), .vga_r(r), .vga_g(g), .vga_b(b),
        .led_config_done(cfg_done)
    );

    // ---------------- test image + golden Sobel ----------------
    reg [15:0] img    [0:H-1][0:W-1];
    integer    gray   [0:H-1][0:W-1];
    reg        golden [0:H-1][0:W-1];
    integer i, j, gx, gy;

    function integer to_gray(input [15:0] p);
        reg [7:0] r8, g8, b8;
        begin
            r8 = {p[15:11], p[15:13]};  g8 = {p[10:5], p[10:9]};  b8 = {p[4:0], p[4:2]};
            to_gray = (r8*77 + g8*150 + b8*29) >> 8;
        end
    endfunction
    function integer iabs(input integer v); iabs = (v < 0) ? -v : v; endfunction

    initial begin
        for (i = 0; i < H; i = i + 1)
            for (j = 0; j < W; j = j + 1) begin
                if (i >= 60 && i < 180 && j >= 40 && j < 200)       img[i][j] = 16'hFFFF;
                else if (i >= 90 && i < 150 && j >= 240 && j < 290) img[i][j] = 16'h8410;
                else                                                img[i][j] = 16'h0000;
                gray[i][j] = to_gray(img[i][j]);
            end
        // output (row i, col j) = window centred at (i-1, j-1); 0 on the border
        for (i = 0; i < H; i = i + 1)
            for (j = 0; j < W; j = j + 1)
                if (i < 2 || j < 2) golden[i][j] = 0;
                else begin
                    gx = (gray[i-2][j] - gray[i-2][j-2]) + 2*(gray[i-1][j] - gray[i-1][j-2])
                       + (gray[i][j]   - gray[i][j-2]);
                    gy = (gray[i][j-2] - gray[i-2][j-2]) + 2*(gray[i][j-1] - gray[i-2][j-1])
                       + (gray[i][j]   - gray[i-2][j]);
                    golden[i][j] = (iabs(gx) + iabs(gy)) > TH;
                end
    end

    // ---------------- camera: OV7670-style timing, changes on pclk falling --
    integer frames_sent = 0, cr, cc, k;
    initial begin
        repeat (5) @(posedge clk50);
        rst_n = 1;
        forever begin
            @(negedge pclk); vsync <= 1;            // vertical blanking
            repeat (3*800) @(negedge pclk);
            vsync <= 0;
            repeat (200) @(negedge pclk);
            for (cr = 0; cr < H; cr = cr + 1) begin
                for (cc = 0; cc < W; cc = cc + 1) begin
                    href <= 1; d <= img[cr][cc][15:8]; @(negedge pclk);
                    d <= img[cr][cc][7:0];             @(negedge pclk);
                end
                href <= 0; d <= 0;
                repeat (144) @(negedge pclk);          // horizontal blanking
            end
            frames_sent = frames_sent + 1;
            $display("[%0t] camera frame %0d sent", $time, frames_sent);
        end
    end

    // ---------------- VGA receiver: coordinates from sync pins only ---------
    // hsync falls at h = 656 (640 + 16 front porch); vsync falls at the
    // start (h = 0) of line 490 (480 + 10 front porch).
    integer hx = 0, vy = 0, errors = 0, checked = 0;
    integer hs_fall_t = -1, hs_low = 0, line_len = 0, vs_lines = 0, frame_lines = 0;
    reg hs_p = 1, vs_p = 1, checking = 0, done = 0, seen_vs = 0;
    integer full_frames_timed = 0;
    reg expect_white;

    always @(posedge dut.clk25) if (rst_n) begin
        // horizontal position
        if (hs_p && !hs) begin
            if (hs_fall_t >= 0 && line_len != 800 && errors < 10) begin
                $display("TIMING FAIL: line length %0d (expected 800)", line_len); errors = errors + 1;
            end
            hs_fall_t = 0; line_len = 0; hx = 656;
        end else begin
            hx = (hx + 1) % 800;
        end
        line_len = line_len + 1;
        if (!hs) hs_low = hs_low + 1;
        if (!hs_p && hs) begin
            if (hs_low != 96 && errors < 10) begin
                $display("TIMING FAIL: hsync low for %0d clocks (expected 96)", hs_low); errors = errors + 1;
            end
            hs_low = 0;
        end

        // vertical position: advances when a new line starts (hx wraps to 0)
        if (hx == 0) vy = (vy + 1) % 525;
        if (vs_p && !vs) begin
            vy = 490;
            // the first vsync after reset ends a partial frame, so only
            // measure frame length from the second vsync onwards
            if (seen_vs) begin
                if (frame_lines != 525) begin
                    $display("TIMING FAIL: %0d lines per frame (expected 525)", frame_lines); errors = errors + 1;
                end else begin
                    $display("[%0t] frame length: 525 lines, ok", $time);
                    full_frames_timed = full_frames_timed + 1;
                end
            end
            seen_vs = 1;
            frame_lines = 0;
        end
        if (hx == 0) frame_lines = frame_lines + 1;
        if (hx == 0 && !vs) vs_lines = vs_lines + 1;
        if (!vs_p && vs) begin
            if (vs_lines != 2) begin
                $display("TIMING FAIL: vsync low for %0d lines (expected 2)", vs_lines); errors = errors + 1;
            end else $display("[%0t] vsync pulse: 2 lines, ok", $time);
            vs_lines = 0;
        end

        // start checking at the first visible pixel after the frame buffer
        // has a picture to show
        if (!checking && !done && dut.u_fb.disp_en && hx == 0 && vy == 0) begin
            checking = 1;
            $display("[%0t] checking one full VGA frame (640x480 pixels)...", $time);
        end
        if (checking) begin
            if (hx < 640 && vy < 480) begin
                expect_white = golden[vy/2][hx/2];
                if ((r !== (expect_white ? 4'hF : 4'h0)) || (g !== r) || (b !== r)) begin
                    if (errors < 10)
                        $display("PIXEL FAIL at screen (%0d,%0d): got r=%h, expected %s",
                                 hx, vy, r, expect_white ? "white" : "black");
                    errors = errors + 1;
                end
                checked = checked + 1;
            end else if (r !== 4'h0 || g !== 4'h0 || b !== 4'h0) begin
                if (errors < 10) $display("BLANKING FAIL at (%0d,%0d): colour not 0", hx, vy);
                errors = errors + 1;
            end
            if (hx == 799 && vy == 479) begin
                checking = 0; done = 1;
            end
        end
        hs_p = hs; vs_p = vs;
    end

    initial begin
        wait (done);
        repeat (12000) @(posedge dut.clk25);   // reach the next vsync so a full frame's length is measured
        $display("================================================================");
        $display(" SCCB config_done = %b", cfg_done);
        if (errors == 0 && checked == 640*480 && full_frames_timed > 0)
            $display(" RESULT: PASS -- %0d screen pixels match the golden 320x240 Sobel map (2x scaled), timing correct", checked);
        else
            $display(" RESULT: FAIL -- %0d errors, %0d pixels checked", errors, checked);
        $display("================================================================");
        $finish;
    end

    // ASCII preview of the stored edge map (every 8th pixel) from the golden map
    initial begin
        #1;
        $display("golden edge map preview (1 char = 8x8 pixels):");
        for (i = 0; i < H; i = i + 8) begin
            for (j = 0; j < W; j = j + 4) $write("%s", (golden[i][j]|golden[i+1][j]|golden[i+2][j]|golden[i+3][j]|golden[i+4][j]|golden[i+5][j]|golden[i+6][j]|golden[i+7][j]) ? "#" : ".");
            $write("\n");
        end
    end

    initial begin
        #120_000_000;
        $display("*** TIMEOUT (frames_sent=%0d, checked=%0d) ***", frames_sent, checked);
        $finish;
    end
endmodule

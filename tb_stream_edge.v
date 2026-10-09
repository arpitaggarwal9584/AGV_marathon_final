`timescale 1ns/1ps
// =============================================================================
// Self-checking testbench for img_edge_stream (gray -> 3x3 window -> Sobel).
//
// Feeds a small W x H image (a bright square on a dark background, so both
// vertical and horizontal edges and corners appear) through the pipeline,
// using the same timing as ov7670_capture: pixel_valid pulses during a row,
// then line_end one cycle AFTER the last pixel (HREF falling edge).
//
// Checks:
//   1. Exactly W*H edge_valid pulses per frame (one output per input pixel),
//      which the 320x240 frame buffer depends on.
//   2. Every output bit equals a software ("golden") Sobel computed here in
//      the testbench from the same image. Output k (row r=k/W, col c=k%W)
//      is the window centred at (r-1, c-1); it is 0 when r<2 or c<2.
// =============================================================================
module tb;
    localparam W  = 12;
    localparam H  = 10;
    localparam TH = 64;

    reg pclk = 0, rst_n = 0;
    always #5 pclk = ~pclk;

    reg         pixel_valid = 0, line_end = 0, frame_start = 0;
    reg [15:0]  pixel_data  = 0;
    wire        edge_valid, edge_pixel;

    img_edge_stream #(.IMG_WIDTH(W), .THRESHOLD(TH)) dut (
        .pclk(pclk), .rst_n(rst_n),
        .pixel_valid(pixel_valid), .pixel_data(pixel_data),
        .line_end(line_end), .frame_start(frame_start),
        .edge_valid(edge_valid), .edge_pixel(edge_pixel)
    );

    reg [15:0] img  [0:H-1][0:W-1];
    integer    gray [0:H-1][0:W-1];
    integer r, c, orow, ocol, gx, gy, mag, errors, outs;
    reg expected;

    // same luma formula as rgb565_to_gray
    function integer to_gray(input [15:0] p);
        reg [7:0] r8, g8, b8;
        begin
            r8 = {p[15:11], p[15:13]};
            g8 = {p[10:5],  p[10:9]};
            b8 = {p[4:0],   p[4:2]};
            to_gray = (r8*77 + g8*150 + b8*29) >> 8;
        end
    endfunction

    function integer iabs(input integer v);
        iabs = (v < 0) ? -v : v;
    endfunction

    initial begin
        // bright square (rows 3..6, cols 4..8) on a dark background,
        // plus a mid-gray stripe on row 8 to exercise sub-threshold values
        for (r = 0; r < H; r = r + 1)
            for (c = 0; c < W; c = c + 1) begin
                if (r >= 3 && r <= 6 && c >= 4 && c <= 8) img[r][c] = 16'hFFFF;
                else if (r == 8)                         img[r][c] = 16'h4208;
                else                                     img[r][c] = 16'h0000;
                gray[r][c] = to_gray(img[r][c]);
            end

        errors = 0; outs = 0;
        repeat (4) @(posedge pclk);
        rst_n = 1;
        @(posedge pclk); frame_start <= 1;
        @(posedge pclk); frame_start <= 0;
        repeat (3) @(posedge pclk);

        for (r = 0; r < H; r = r + 1) begin
            for (c = 0; c < W; c = c + 1) begin
                pixel_valid <= 1; pixel_data <= img[r][c];
                @(posedge pclk);
                pixel_valid <= 0;           // one pixel every 2 clocks, like the
                @(posedge pclk);            // camera (2 bytes per RGB565 pixel)
            end
            line_end <= 1;                  // HREF falling edge, after last pixel
            @(posedge pclk); line_end <= 0;
            repeat (6) @(posedge pclk);     // horizontal blanking
        end
        repeat (10) @(posedge pclk);

        if (outs != W*H) begin
            $display("FAIL: got %0d outputs, expected %0d", outs, W*H);
            errors = errors + 1;
        end
        if (errors == 0) $display("RESULT: PASS (%0d outputs, all match golden Sobel)", outs);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    always @(posedge pclk) begin
        if (edge_valid) begin
            orow = outs / W; ocol = outs % W;
            if (orow < 2 || ocol < 2) expected = 0;
            else begin
                // centre (r-1, c-1); neighbours rows r-2..r, cols c-2..c
                gx = (gray[orow-2][ocol] - gray[orow-2][ocol-2]) + 2*(gray[orow-1][ocol] - gray[orow-1][ocol-2])
                   + (gray[orow][ocol]   - gray[orow][ocol-2]);
                gy = (gray[orow][ocol-2] - gray[orow-2][ocol-2]) + 2*(gray[orow][ocol-1] - gray[orow-2][ocol-1])
                   + (gray[orow][ocol]   - gray[orow-2][ocol]);
                mag = iabs(gx) + iabs(gy);
                expected = (mag > TH);
            end
            if (edge_pixel !== expected) begin
                $display("MISMATCH out #%0d (row %0d col %0d): got %b expected %b",
                         outs, orow, ocol, edge_pixel, expected);
                errors = errors + 1;
            end
            $write("%s", edge_pixel ? "#" : ".");
            if (ocol == W-1) $write("\n");
            outs = outs + 1;
        end
    end

endmodule

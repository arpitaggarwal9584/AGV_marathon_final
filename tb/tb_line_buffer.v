`timescale 1ns/1ps
// Verifies line_buffer_3x3 against an exact, known image: pixel(row,col) =
// row*10 + col, so every value is unique and invertible. Rather than trying
// to hand-track the pipeline's exact cycle latency (easy to get wrong),
// the checker DECODES the window's claimed centre row/col directly from
// p11's value, then checks all 8 neighbours against what they should be
// for that centre. If the window shape is right, this can't be fooled by
// a latency miscount, because the centre comes from the DUT's own output.
module tb;
    localparam W = 6;
    localparam H = 6;

    reg pclk = 0;
    reg rst_n = 0;
    always #5 pclk = ~pclk;

    reg        pixel_valid = 0;
    reg [7:0]  pixel_data  = 0;
    reg        line_end    = 0;
    reg        frame_start = 0;

    wire [7:0] p00,p01,p02,p10,p11,p12,p20,p21,p22;
    wire win_valid;

    line_buffer_3x3 #(.IMG_WIDTH(W)) dut (
        .pclk(pclk), .rst_n(rst_n),
        .pixel_valid(pixel_valid), .pixel_data(pixel_data),
        .line_end(line_end), .frame_start(frame_start),
        .p00(p00),.p01(p01),.p02(p02),
        .p10(p10),.p11(p11),.p12(p12),
        .p20(p20),.p21(p21),.p22(p22),
        .win_valid(win_valid)
    );

    function [7:0] val(input integer row, input integer col);
        val = row*10 + col;
    endfunction

    integer r, c;
    integer errors = 0;
    integer checks = 0;
    integer cr, cc;

    // Sample on the FALLING edge: by then, all of this cycle's nonblocking
    // updates inside the DUT (triggered on the prior rising edge) have
    // settled, so there's no same-edge read race between this checker and
    // the DUT's own clocked block.
    always @(negedge pclk) begin
        if (win_valid) begin
            cr = p11 / 10;
            cc = p11 % 10;
            checks = checks + 1;
            if (p00 !== val(cr-1,cc-1) || p01 !== val(cr-1,cc) || p02 !== val(cr-1,cc+1) ||
                p10 !== val(cr,  cc-1) || p11 !== val(cr,  cc) || p12 !== val(cr,  cc+1) ||
                p20 !== val(cr+1,cc-1) || p21 !== val(cr+1,cc) || p22 !== val(cr+1,cc+1)) begin
                errors = errors + 1;
                $display("MISMATCH, decoded centre row=%0d col=%0d:", cr, cc);
                $display("  got      %0d %0d %0d / %0d %0d %0d / %0d %0d %0d",
                          p00,p01,p02,p10,p11,p12,p20,p21,p22);
                $display("  expected %0d %0d %0d / %0d %0d %0d / %0d %0d %0d",
                          val(cr-1,cc-1), val(cr-1,cc), val(cr-1,cc+1),
                          val(cr,  cc-1), val(cr,  cc), val(cr,  cc+1),
                          val(cr+1,cc-1), val(cr+1,cc), val(cr+1,cc+1));
            end else begin
                $display("OK centre row=%0d col=%0d", cr, cc);
            end
        end
    end

    initial begin
        rst_n = 0;
        repeat (4) @(posedge pclk);
        rst_n = 1;
        @(posedge pclk);

        frame_start = 1;
        @(posedge pclk);
        frame_start = 0;

        for (r = 0; r < H; r = r + 1) begin
            for (c = 0; c < W; c = c + 1) begin
                pixel_valid = 1;
                pixel_data  = val(r,c);
                line_end    = (c == W-1);
                @(posedge pclk);
            end
            pixel_valid = 0;
            line_end    = 0;
            @(posedge pclk);
        end

        repeat (5) @(posedge pclk);
        $display("================================================");
        $display("checks=%0d errors=%0d", checks, errors);
        // interior of a 6x6 image (not first/last row or column) has
        // 4 rows x 4 cols = 16 valid centre positions
        if (errors == 0 && checks == (H-2)*(W-2))
            $display("RESULT: PASS (all %0d interior windows correct)", checks);
        else
            $display("RESULT: FAIL");
        $display("================================================");
        $finish;
    end
endmodule

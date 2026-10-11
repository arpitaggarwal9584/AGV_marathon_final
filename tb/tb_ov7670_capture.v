`timescale 1ns/1ps
// Verifies ov7670_capture: drives a tiny fake 2-row frame (3 pixels then
// 2 pixels) through href/vsync/d, and checks pixel assembly, line_end, and
// frame_start all happen on the right cycles.
//
// All stimulus changes (vsync, href, d) are made right after @(negedge pclk),
// so every new value is stable for the entire low half of the clock before
// the next posedge samples it -- the same race-avoidance pattern already
// verified in tb_line_buffer.v. Checks are then done shortly after the
// posedge that should have reacted to it.
module tb;
    reg pclk = 0;
    reg rst_n = 0;
    always #5 pclk = ~pclk;

    reg        href  = 0;
    reg        vsync = 1;   // start in vertical blanking
    reg [7:0]  d     = 0;

    wire        pixel_valid;
    wire [15:0] pixel_data;
    wire        line_end;
    wire        frame_start;

    ov7670_capture dut (
        .pclk(pclk), .rst_n(rst_n),
        .href(href), .vsync(vsync), .d(d),
        .pixel_valid(pixel_valid), .pixel_data(pixel_data),
        .line_end(line_end), .frame_start(frame_start)
    );

    integer errors = 0;

    // Sets d to val at a negedge, then waits for the posedge that samples it.
    task send_byte(input [7:0] val);
        begin
            @(negedge pclk);
            d = val;
            @(posedge pclk);
            #1;   // let the DUT's NBA updates (pixel_valid/pixel_data) settle before a read
        end
    endtask

    // Like send_byte, but also raises href on that same negedge -- href and
    // the first data byte must become valid together, otherwise the DUT
    // samples one extra "phantom" byte (d's old value) on the cycle where
    // href is high but the real first byte hasn't been driven yet.
    task start_row_send_byte(input [7:0] val);
        begin
            @(negedge pclk);
            href = 1;
            d = val;
            @(posedge pclk);
            #1;
        end
    endtask

    task check16(input [15:0] exp, input [127:0] label);
        begin
            if (!pixel_valid || pixel_data !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: valid=%b got=%h expected=%h", label, pixel_valid, pixel_data, exp);
            end else begin
                $display("OK %0s = %h", label, pixel_data);
            end
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (3) @(negedge pclk);
        rst_n = 1;

        // end blanking -> frame_start expected on the next posedge
        @(negedge pclk);
        vsync = 0;
        @(posedge pclk);
        #1;
        if (!frame_start) begin
            errors = errors + 1;
            $display("FAIL: frame_start not seen after vsync fell");
        end else $display("OK: frame_start pulsed");

        // ---- Row 0: 3 pixels, 6 bytes ----
        start_row_send_byte(8'h11); send_byte(8'h22); check16(16'h1122, "row0 pixel0");
        send_byte(8'h33); send_byte(8'h44); check16(16'h3344, "row0 pixel1");
        send_byte(8'h55); send_byte(8'h66); check16(16'h5566, "row0 pixel2");

        @(negedge pclk);
        href = 0;
        @(posedge pclk);
        #1;
        if (!line_end) begin
            errors = errors + 1;
            $display("FAIL: line_end not seen after row 0");
        end else $display("OK: line_end pulsed (row 0)");

        repeat (2) @(posedge pclk);   // small horizontal blanking gap

        // ---- Row 1: 2 pixels, 4 bytes ----
        start_row_send_byte(8'hAA); send_byte(8'hBB); check16(16'hAABB, "row1 pixel0");
        send_byte(8'hCC); send_byte(8'hDD); check16(16'hCCDD, "row1 pixel1");

        @(negedge pclk);
        href = 0;
        @(posedge pclk);
        #1;
        if (!line_end) begin
            errors = errors + 1;
            $display("FAIL: line_end not seen after row 1");
        end else $display("OK: line_end pulsed (row 1)");

        @(negedge pclk);
        vsync = 1;   // end frame
        repeat (2) @(posedge pclk);

        $display("================================================");
        if (errors == 0) $display("RESULT: PASS (all checks correct)");
        else              $display("RESULT: FAIL (%0d errors)", errors);
        $display("================================================");
        $finish;
    end
endmodule

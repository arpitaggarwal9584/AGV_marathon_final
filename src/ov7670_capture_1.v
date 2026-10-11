
module xclk_gen (
    input  wire sys_clk,
    input  wire rst_n,
    output reg  xclk
);
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) xclk <= 1'b0;
        else        xclk <= ~xclk;
    end
endmodule



module ov7670_capture (
    input  wire       pclk,
    input  wire       rst_n,

    input  wire        href,
    input  wire        vsync,
    input  wire [7:0]  d,

    output reg          pixel_valid,
    output reg  [15:0]  pixel_data,
    output reg          line_end,
    output reg          frame_start
);

    reg        href_d;      // previous cycle's href, to catch the falling edge
    reg        vsync_d;     // previous cycle's vsync, to catch the falling edge
    reg        byte_sel;    // 0 = next byte is the high byte, 1 = next is the low byte
    reg [7:0]  hi_byte;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            href_d      <= 1'b0;
            vsync_d     <= 1'b0;
            byte_sel    <= 1'b0;
            hi_byte     <= 8'd0;
            pixel_valid <= 1'b0;
            pixel_data  <= 16'd0;
            line_end    <= 1'b0;
            frame_start <= 1'b0;
        end else begin
            // one-cycle pulses: default low every cycle, re-asserted below
            // only on the specific cycle each condition actually happens
            pixel_valid <= 1'b0;
            line_end    <= 1'b0;
            frame_start <= 1'b0;

            href_d  <= href;
            vsync_d <= vsync;

            // VSYNC falling edge: vertical blanking just ended -- the new
            // frame's first active row is about to begin
            if (vsync_d && !vsync) begin
                frame_start <= 1'b1;
                byte_sel    <= 1'b0;   // start the new frame's first row on a high byte
            end

            // HREF falling edge: the row that was active just finished
            if (href_d && !href) begin
                line_end <= 1'b1;
                byte_sel <= 1'b0;      // next row also starts fresh on a high byte
            end

            // while HREF is high, every pclk edge brings one new data byte
            if (href) begin
                if (!byte_sel) begin
                    hi_byte  <= d;
                    byte_sel <= 1'b1;
                end else begin
                    pixel_data  <= {hi_byte, d};
                    pixel_valid <= 1'b1;
                    byte_sel    <= 1'b0;
                end
            end
        end
    end
endmodule


module line_buffer_3x3 #(
    parameter IMG_WIDTH = 320
) (
    input  wire       pclk,
    input  wire       rst_n,

    input  wire        pixel_valid,
    input  wire [7:0]  pixel_data,
    input  wire        line_end,      // one-cycle pulse on the last pixel_valid of a row
    input  wire        frame_start,   // one-cycle pulse at the start of a new frame

    // 3x3 window: row0 = two rows above, row1 = one row above, row2 = current row
    // col0 = left neighbour, col1 = centre pixel, col2 = right neighbour
    output reg [7:0] p00, p01, p02,
    output reg [7:0] p10, p11, p12,
    output reg [7:0] p20, p21, p22,
    output reg       win_valid,
    output reg       pix_out_valid   // pulses once for EVERY input pixel (same
                                      // timing as win_valid), so downstream can
                                      // emit exactly one output per input pixel
                                      // (border pixels included, as 0)
);

    localparam CW = $clog2(IMG_WIDTH);

    reg [7:0] lineA [0:IMG_WIDTH-1];
    reg [7:0] lineB [0:IMG_WIDTH-1];
    reg       a_is_stale;             // 1 = lineA holds the older row this cycle

    reg [CW-1:0] col;
    reg [1:0]    rows_done;           // saturates at 2: rows completed so far this frame

    // 3-tap shift registers, one per row of the window
    reg [7:0] row0_sr [0:1];          // row two-above: [left, centre] (right is the fresh read this cycle)
    reg [7:0] row1_sr [0:1];          // row one-above
    reg [7:0] row2_sr [0:1];          // current row

    wire [7:0] stale_rd = a_is_stale ? lineA[col] : lineB[col];   // row two-above, this column
    wire [7:0] fresh_rd = a_is_stale ? lineB[col] : lineA[col];   // row one-above, this column

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            col         <= 0;
            a_is_stale  <= 1'b1;
            rows_done   <= 2'd0;
            win_valid   <= 1'b0;
            pix_out_valid <= 1'b0;
            row0_sr[0] <= 0; row0_sr[1] <= 0;
            row1_sr[0] <= 0; row1_sr[1] <= 0;
            row2_sr[0] <= 0; row2_sr[1] <= 0;
            p00<=0; p01<=0; p02<=0; p10<=0; p11<=0; p12<=0; p20<=0; p21<=0; p22<=0;
        end else begin
            win_valid     <= 1'b0;
            pix_out_valid <= 1'b0;

            if (frame_start) begin
                col        <= 0;
                a_is_stale <= 1'b1;
                rows_done  <= 2'd0;
            end else if (pixel_valid) begin
                pix_out_valid <= 1'b1;
                // read both buffers at this column (values from the stale/fresh
                // read wires above), then overwrite the stale one with the new pixel
                if (a_is_stale) lineA[col] <= pixel_data;
                else            lineB[col] <= pixel_data;

                // shift each row's little window along by one column
                row0_sr[0] <= row0_sr[1];  row0_sr[1] <= stale_rd;
                row1_sr[0] <= row1_sr[1];  row1_sr[1] <= fresh_rd;
                row2_sr[0] <= row2_sr[1];  row2_sr[1] <= pixel_data;

                // once we have 2 full rows buffered and are past the first
                // two columns, the shift registers hold a genuine 3x3 window
                if (rows_done == 2'd2 && col >= 2) begin
                    p00 <= row0_sr[0]; p01 <= row0_sr[1]; p02 <= stale_rd;
                    p10 <= row1_sr[0]; p11 <= row1_sr[1]; p12 <= fresh_rd;
                    p20 <= row2_sr[0]; p21 <= row2_sr[1]; p22 <= pixel_data;
                    win_valid <= 1'b1;
                end

                if (col == IMG_WIDTH-1) col <= 0;
                else                    col <= col + 1'b1;
            end

            if (line_end) begin
                a_is_stale <= ~a_is_stale;    // the row just finished becomes "fresh"; swap roles
                if (rows_done < 2'd2)
                    rows_done <= rows_done + 1'b1;
            end
        end
    end
endmodule

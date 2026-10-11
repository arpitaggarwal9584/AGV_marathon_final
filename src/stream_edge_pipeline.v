
module rgb565_to_gray (
    input  wire [15:0] rgb565,
    output wire [7:0]  gray
);
    wire [4:0] r5 = rgb565[15:11];
    wire [5:0] g6 = rgb565[10:5];
    wire [4:0] b5 = rgb565[4:0];

    // Scale each field up to 8 bits first (replicate top bits into the gap),
    // then apply the integer luma weights.
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    wire [15:0] luma = (r8 * 8'd77) + (g8 * 8'd150) + (b8 * 8'd29);
    assign gray = luma[15:8];   // divide by 256
endmodule


// -----------------------------------------------------------------------------
// 2) Sobel gradient + threshold
//
// Standard 3x3 Sobel kernels:
//   Gx = [-1 0 +1; -2 0 +2; -1 0 +1]      (horizontal gradient)
//   Gy = [-1 -2 -1; 0 0 0; +1 +2 +1]      (vertical gradient)
// Magnitude approximated as |Gx| + |Gy| (cheap, avoids a square root, the
// standard FPGA shortcut). One output per input pixel, one cycle of latency;
// border pixels (win_valid low) are forced to 0.
// -----------------------------------------------------------------------------
module sobel_edge #(
    parameter THRESHOLD = 8'd64
) (
    input  wire       pclk,
    input  wire       rst_n,

    input  wire       pix_in_valid,  // one pulse per input pixel
    input  wire       win_valid,     // the 3x3 window below is a real one
    input  wire [7:0] p00, p01, p02,
    input  wire [7:0] p10, p11, p12,
    input  wire [7:0] p20, p21, p22,

    output reg        edge_valid,
    output reg        edge_pixel     // 1 = edge, 0 = not (binary edge map)
);
    wire signed [11:0] gx = $signed({4'b0,p02}) - $signed({4'b0,p00})
                          + 2*($signed({4'b0,p12}) - $signed({4'b0,p10}))
                          + $signed({4'b0,p22}) - $signed({4'b0,p20});

    wire signed [11:0] gy = $signed({4'b0,p20}) - $signed({4'b0,p00})
                          + 2*($signed({4'b0,p21}) - $signed({4'b0,p01}))
                          + $signed({4'b0,p22}) - $signed({4'b0,p02});

    wire [11:0] abs_gx = gx[11] ? -gx : gx;
    wire [11:0] abs_gy = gy[11] ? -gy : gy;
    wire [12:0] mag    = abs_gx + abs_gy;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            edge_valid <= 1'b0;
            edge_pixel <= 1'b0;
        end else begin
            edge_valid <= pix_in_valid;
            edge_pixel <= win_valid && (mag > THRESHOLD);
        end
    end
endmodule


// -----------------------------------------------------------------------------
// 3) Top-level wrapper: gray conversion -> 3x3 window -> Sobel.
// -----------------------------------------------------------------------------
module img_edge_stream #(
    parameter IMG_WIDTH = 320,
    parameter THRESHOLD = 8'd64
) (
    input  wire        pclk,
    input  wire        rst_n,

    input  wire         pixel_valid,   // from ov7670_capture
    input  wire [15:0]  pixel_data,    // RGB565, from ov7670_capture
    input  wire         line_end,      // from ov7670_capture
    input  wire         frame_start,   // from ov7670_capture

    output wire         edge_valid,    // exactly one pulse per input pixel
    output wire         edge_pixel
);
    wire [7:0] gray;
    rgb565_to_gray u_gray (.rgb565(pixel_data), .gray(gray));

    wire [7:0] p00,p01,p02,p10,p11,p12,p20,p21,p22;
    wire       win_valid, pix_out_valid;

    line_buffer_3x3 #(.IMG_WIDTH(IMG_WIDTH)) u_lb (
        .pclk(pclk), .rst_n(rst_n),
        .pixel_valid(pixel_valid), .pixel_data(gray),
        .line_end(line_end), .frame_start(frame_start),
        .p00(p00), .p01(p01), .p02(p02),
        .p10(p10), .p11(p11), .p12(p12),
        .p20(p20), .p21(p21), .p22(p22),
        .win_valid(win_valid), .pix_out_valid(pix_out_valid)
    );

    sobel_edge #(.THRESHOLD(THRESHOLD)) u_sobel (
        .pclk(pclk), .rst_n(rst_n),
        .pix_in_valid(pix_out_valid), .win_valid(win_valid),
        .p00(p00), .p01(p01), .p02(p02),
        .p10(p10), .p11(p11), .p12(p12),
        .p20(p20), .p21(p21), .p22(p22),
        .edge_valid(edge_valid), .edge_pixel(edge_pixel)
    );
endmodule

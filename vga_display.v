
module vga_display #(
    parameter IMG_W = 320,          // stored image size
    parameter IMG_H = 240,
    parameter AW    = 17            // frame-buffer address width
) (
    input  wire          vga_clk,   // 25 MHz pixel clock
    input  wire          rst_n,

    // ---- to / from frame_buffer_bram (read side) ----
    output wire          frame_start,  // 1-cycle pulse at start of vertical blank
    output wire          pixel_req,    // high while (x, y) is in the visible area
    output wire [AW-1:0] rd_addr,      // (y/2)*IMG_W + (x/2)
    input  wire          pixel_valid,  // from frame buffer, 2 clocks after pixel_req
    input  wire          pixel_data,   // 1 = edge

    // ---- to the VGA connector ----
    output reg           vga_hsync,
    output reg           vga_vsync,
    output reg  [3:0]    vga_r,        // 4 bits per colour (DE0-Nano/DE10-Lite
    output reg  [3:0]    vga_g,        // style resistor DAC); use the top bits if
    output reg  [3:0]    vga_b         // your board has fewer
);
    // ---------------- standard 640x480 @ 60 Hz timing constants -----------
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_BP = 48;
    localparam H_TOT = H_VIS + H_FP + H_SYNC + H_BP;   // 800
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33;
    localparam V_TOT = V_VIS + V_FP + V_SYNC + V_BP;   // 525

    // ---------------- stage 0: pixel/line counters -------------------------
    reg [9:0] h_cnt;   // 0 .. 799
    reg [9:0] v_cnt;   // 0 .. 524

    always @(posedge vga_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 10'd0;
            v_cnt <= 10'd0;
        end else if (h_cnt == H_TOT-1) begin
            h_cnt <= 10'd0;
            v_cnt <= (v_cnt == V_TOT-1) ? 10'd0 : v_cnt + 10'd1;
        end else begin
            h_cnt <= h_cnt + 10'd1;
        end
    end

    wire active = (h_cnt < H_VIS) && (v_cnt < V_VIS);
    wire hs0    = ~((h_cnt >= H_VIS + H_FP) && (h_cnt < H_VIS + H_FP + H_SYNC)); // active low
    wire vs0    = ~((v_cnt >= V_VIS + V_FP) && (v_cnt < V_VIS + V_FP + V_SYNC)); // active low

    // 2x upscale: stored pixel = (x/2, y/2). y2*320 = y2*256 + y2*64, so the
    // multiply is just two shifts and an add (no hardware multiplier).
    wire [8:0] x2 = h_cnt[9:1];   // 0 .. 319 while active
    wire [8:0] y2 = v_cnt[9:1];   // 0 .. 239 while active
    assign rd_addr   = active ? (({8'd0, y2} << 8) + ({8'd0, y2} << 6) + {8'd0, x2})
                              : {AW{1'b0}};
    assign pixel_req = active;

    // Buffer swaps are only allowed at this point (start of vertical blank),
    // so a whole visible frame is always read from one buffer.
    assign frame_start = (h_cnt == 10'd0) && (v_cnt == V_VIS);

    // ---------------- stages 1-2: delay syncs to match frame-buffer latency
    reg hs1, hs2, vs1, vs2, act1, act2;
    always @(posedge vga_clk or negedge rst_n) begin
        if (!rst_n) begin
            hs1 <= 1'b1; hs2 <= 1'b1;
            vs1 <= 1'b1; vs2 <= 1'b1;
            act1 <= 1'b0; act2 <= 1'b0;
        end else begin
            hs1 <= hs0;  hs2 <= hs1;
            vs1 <= vs0;  vs2 <= vs1;
            act1 <= active; act2 <= act1;
        end
    end

    // ---------------- stage 3: registered outputs -------------------------
    // White for an edge pixel, black otherwise. Black also whenever the frame
    // buffer has no valid picture yet (pixel_valid low) and during blanking
    // (colour MUST be 0 outside the visible area or monitors misbehave).
    wire white = act2 && pixel_valid && pixel_data;

    always @(posedge vga_clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_hsync <= 1'b1;
            vga_vsync <= 1'b1;
            vga_r <= 4'd0; vga_g <= 4'd0; vga_b <= 4'd0;
        end else begin
            vga_hsync <= hs2;
            vga_vsync <= vs2;
            vga_r <= white ? 4'hF : 4'h0;
            vga_g <= white ? 4'hF : 4'h0;
            vga_b <= white ? 4'hF : 4'h0;
        end
    end
endmodule

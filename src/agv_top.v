module agv_top #(
    parameter RESET_WAIT = 32'd5_000_000,   // camera settle time after reset (~100 ms)
    parameter THRESHOLD  = 8'd64            // Sobel edge threshold (raise = fewer edges)
) (
    input  wire       clk50,        // 50 MHz board clock
    input  wire       rst_n,        // active-low reset button

    // ---- OV7670 camera ----
    input  wire       cam_pclk,
    input  wire       cam_href,
    input  wire       cam_vsync,
    input  wire [7:0] cam_d,
    output wire       cam_xclk,
    output wire       cam_sioc,
    inout  wire       cam_siod,
    output wire       cam_reset,    // OV7670 RESET pin is active low: hold high
    output wire       cam_pwdn,     // OV7670 PWDN pin is active high: hold low

    // ---- VGA connector ----
    output wire       vga_hsync,
    output wire       vga_vsync,
    output wire [3:0] vga_r,
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,

    output wire       led_config_done   // lights once the camera is configured
);
    assign cam_reset = 1'b1;
    assign cam_pwdn  = 1'b0;

    // ---------------- 25 MHz clock (see CLOCKS note above) -----------------
    wire clk25;
    xclk_gen u_clkdiv (.sys_clk(clk50), .rst_n(rst_n), .xclk(clk25));
    assign cam_xclk = clk25;

    // ---------------- camera configuration (SCCB) --------------------------
    sccb_sequencer #(.DEV_ADDR(8'h42), .RESET_WAIT(RESET_WAIT)) u_sccb (
        .sys_clk     (clk50),
        .rst_n       (rst_n),
        .sio_c       (cam_sioc),
        .sio_d       (cam_siod),
        .config_done (led_config_done)
    );

    // ---------------- capture: bytes -> RGB565 pixels ----------------------
    wire        cap_valid, cap_line_end, cap_frame_start;
    wire [15:0] cap_pixel;
    ov7670_capture u_cap (
        .pclk        (cam_pclk),
        .rst_n       (rst_n),
        .href        (cam_href),
        .vsync       (cam_vsync),
        .d           (cam_d),
        .pixel_valid (cap_valid),
        .pixel_data  (cap_pixel),
        .line_end    (cap_line_end),
        .frame_start (cap_frame_start)
    );

    // ---------------- Sobel edge pipeline (320 wide) -----------------------
    wire edge_valid, edge_pixel;
    img_edge_stream #(.IMG_WIDTH(320), .THRESHOLD(THRESHOLD)) u_edge (
        .pclk        (cam_pclk),
        .rst_n       (rst_n),
        .pixel_valid (cap_valid),
        .pixel_data  (cap_pixel),
        .line_end    (cap_line_end),
        .frame_start (cap_frame_start),
        .edge_valid  (edge_valid),
        .edge_pixel  (edge_pixel)
    );

    // ---------------- frame buffer (BRAM, double-buffered) -----------------
    wire        vga_frame_start, vga_pixel_req, fb_valid, fb_data, fb_ready;
    wire [16:0] vga_rd_addr;
    frame_buffer_bram #(.FRAME_PIXELS(76800), .AW(17)) u_fb (
        .pclk            (cam_pclk),
        .rst_n           (rst_n),
        .pix_valid       (edge_valid),
        .pix_data        (edge_pixel),
        .frame_start     (cap_frame_start),

        .vga_clk         (clk25),
        .vga_rst_n       (rst_n),
        .vga_frame_start (vga_frame_start),
        .pixel_req       (vga_pixel_req),
        .pixel_valid     (fb_valid),
        .pixel_data      (fb_data),
        .frame_ready     (fb_ready)
    );

    // ---------------- VGA output -------------------------------------------
    vga_display #(.IMG_W(320), .IMG_H(240), .AW(17)) u_vga (
        .vga_clk     (clk25),
        .rst_n       (rst_n),
        .frame_start (vga_frame_start),
        .pixel_req   (vga_pixel_req),
        .rd_addr     (vga_rd_addr),
        .pixel_valid (fb_valid),
        .pixel_data  (fb_data),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b)
    );
endmodule

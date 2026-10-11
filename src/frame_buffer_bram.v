
module dp_bram #(
    parameter DEPTH = 76800,
    parameter AW    = 17            // must satisfy 2**AW >= DEPTH
) (
    input  wire          wr_clk,
    input  wire          wr_en,
    input  wire [AW-1:0] wr_addr,
    input  wire          wr_data,

    input  wire          rd_clk,
    input  wire [AW-1:0] rd_addr,
    output reg           rd_data
);
    reg mem [0:DEPTH-1];

    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        rd_data <= mem[rd_addr];
    end
endmodule

// frame_buffer_bram - the double-buffered wrapper described above.

module frame_buffer_bram #(
    parameter FRAME_PIXELS = 76800,   // 320*240 for the real system
    parameter AW           = 17       // must satisfy 2**AW >= FRAME_PIXELS
) (
    //  write side: pclk domain (camera / edge pipeline) 
    input  wire pclk,
    input  wire rst_n,
    input  wire pix_valid,     // one-cycle pulse: pix_data is a new pixel
    input  wire pix_data,      // 1-bit edge pixel
    input  wire frame_start,   // one-cycle pulse: new camera frame begins

    // read side: vga_clk domain (display) 
    input  wire vga_clk,
    input  wire vga_rst_n,
    input  wire vga_frame_start,  // one-cycle pulse: new VGA frame begins (vblank)
    input  wire pixel_req,        // one-cycle pulse: consume/advance one pixel
    output reg  pixel_valid,      // one-cycle pulse: pixel_data is valid
    output reg  pixel_data,       // the 1-bit pixel for this request
    output wire frame_ready       // 0 until the first camera frame has fully
                                   // landed; display should treat "not ready"
                                   // as blank/black rather than trust pixel_data
);

   
    // Write side //
    reg [AW-1:0] wr_addr;
   
    reg          cur_wbuf;      // which buffer pclk is currently filling
    reg          have_started;  // 0 until the very first frame_start
    reg          buf_ready_w;   // sticky: 1 once buffer 0's first frame is complete

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr      <= {AW{1'b0}};
            cur_wbuf     <= 1'b0;
            have_started <= 1'b0;
            buf_ready_w  <= 1'b0;
        end else begin
            if (frame_start) begin
                wr_addr <= {AW{1'b0}};
                if (have_started) begin
                    cur_wbuf    <= ~cur_wbuf;
                    buf_ready_w <= 1'b1;   // the buffer we just left is now complete
                end
                have_started <= 1'b1;
            end else if (pix_valid) begin
                wr_addr <= wr_addr + 1'b1;
            end
        end
    end

    wire wr_en0 = pix_valid && !cur_wbuf;
    wire wr_en1 = pix_valid &&  cur_wbuf;

    
    // Cross-domain synchronization: cur_wbuf and buf_ready, pclk -> vga_clk.
    // Both are single bits, so a plain 2-flip-flop level synchronizer is
    // sufficient and safe (see header comment for the residual-race caveat).
   
    reg cur_wbuf_s0, cur_wbuf_s1;
    reg buf_ready_s0, buf_ready_s1;

    always @(posedge vga_clk or negedge vga_rst_n) begin
        if (!vga_rst_n) begin
            cur_wbuf_s0  <= 1'b0; cur_wbuf_s1  <= 1'b0;
            buf_ready_s0 <= 1'b0; buf_ready_s1 <= 1'b0;
        end else begin
            cur_wbuf_s0  <= cur_wbuf;    cur_wbuf_s1  <= cur_wbuf_s0;
            buf_ready_s0 <= buf_ready_w; buf_ready_s1 <= buf_ready_s0;
        end
    end

    wire cur_wbuf_sync  = cur_wbuf_s1;
    wire buf_ready_sync = buf_ready_s1;
    assign frame_ready  = buf_ready_sync;

  
    // Read side
   
    reg [AW-1:0] rd_addr;
    reg          rbuf_select;     // latched once per VGA frame, at vblank only
    reg          rbuf_select_d;   // delayed by 1 cycle, to match the BRAMs'
                                   // 1-cycle read latency (see mux below)
    reg          req_d;           // pixel_req delayed by 1 cycle, same reason
    reg          ready_d;         // disp_en captured at request time
    reg          disp_en;         // display enabled - only ever turns on AT a
                                   // vga_frame_start, so the first valid
                                   // pixel is always pixel 0 of a frame

    always @(posedge vga_clk or negedge vga_rst_n) begin
        if (!vga_rst_n) begin
            rd_addr       <= {AW{1'b0}};
            rbuf_select   <= 1'b0;
            rbuf_select_d <= 1'b0;
            req_d         <= 1'b0;
            ready_d       <= 1'b0;
            disp_en       <= 1'b0;
        end else begin
            if (vga_frame_start) begin
                rd_addr <= {AW{1'b0}};
                if (buf_ready_sync) begin
                    rbuf_select <= ~cur_wbuf_sync;   // vsync-locked buffer pick
                    disp_en     <= 1'b1;
                end
            end else if (pixel_req) begin
                rd_addr <= rd_addr + 1'b1;
            end

            // Register, alongside the address, which buffer and ready-state
            // that address was issued under, so the mux below (one cycle
            // later, when the BRAMs' registered output actually appears)
            // uses the matching selection rather than whatever rbuf_select
            // happens to be by then.
            rbuf_select_d <= rbuf_select;
            req_d         <= pixel_req;
            ready_d       <= disp_en;
        end
    end

    wire buf0_rdata, buf1_rdata;

    dp_bram #(.DEPTH(FRAME_PIXELS), .AW(AW)) u_buf0 (
        .wr_clk (pclk),    .wr_en (wr_en0), .wr_addr (wr_addr), .wr_data (pix_data),
        .rd_clk (vga_clk),                  .rd_addr (rd_addr), .rd_data (buf0_rdata)
    );
    dp_bram #(.DEPTH(FRAME_PIXELS), .AW(AW)) u_buf1 (
        .wr_clk (pclk),    .wr_en (wr_en1), .wr_addr (wr_addr), .wr_data (pix_data),
        .rd_clk (vga_clk),                  .rd_addr (rd_addr), .rd_data (buf1_rdata)
    );

    always @(posedge vga_clk or negedge vga_rst_n) begin
        if (!vga_rst_n) begin
            pixel_valid <= 1'b0;
            pixel_data  <= 1'b0;
        end else begin
            pixel_valid <= req_d && ready_d;
            pixel_data  <= rbuf_select_d ? buf1_rdata : buf0_rdata;
        end
    end

endmodule

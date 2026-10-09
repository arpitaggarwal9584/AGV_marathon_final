

module sccb_master #(
    parameter CLK_DIV = 125   // SCL period = 4 * CLK_DIV sys_clk cycles
                              // 50 MHz / (4*125) = 100 kHz SCL
) (
    input  wire        sys_clk,
    input  wire        rst_n,

    input  wire        start,       // 1-cycle pulse: begin a write transaction
    input  wire [7:0]  dev_addr,    // e.g. 8'h42 (OV7670 write ID)
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_data,

    output reg          busy,
    output reg          done,        // 1-cycle pulse when the transaction finishes

    inout  wire         sio_d,       // SCCB data line (open-drain; needs a pull-up)
    output reg          sio_c        // SCCB clock line
);

    reg sda_out;
    reg sda_oe;                      // 1 = driving sio_d, 0 = released (hi-Z)
    assign sio_d = sda_oe ? sda_out : 1'bz;

    reg [31:0] div_cnt;
    reg [1:0]  phase;
    wire       phase_tick = (div_cnt == CLK_DIV-1);

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 0;
            phase   <= 0;
        end else if (busy) begin
            if (phase_tick) begin
                div_cnt <= 0;
                phase   <= phase + 2'd1;
            end else begin
                div_cnt <= div_cnt + 1;
            end
        end else begin
            div_cnt <= 0;
            phase   <= 0;
        end
    end

    localparam IDLE       = 3'd0,
               START_COND = 3'd1,
               SHIFT_BYTE = 3'd2,
               ACK_BIT    = 3'd3,
               STOP_COND  = 3'd4,
               DONE_ST    = 3'd5;

    reg [2:0] state;
    reg [1:0] byte_sel;      // 0 = dev_addr, 1 = reg_addr, 2 = reg_data
    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            sio_c     <= 1'b1;
            sda_out   <= 1'b1;
            sda_oe    <= 1'b1;
            byte_sel  <= 2'd0;
            bit_cnt   <= 3'd7;
            shift_reg <= 8'd0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    sio_c   <= 1'b1;
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    if (start) begin
                        busy      <= 1'b1;
                        byte_sel  <= 2'd0;
                        shift_reg <= dev_addr;
                        bit_cnt   <= 3'd7;
                        state     <= START_COND;
                    end
                end

                START_COND: begin
                    case (phase)
                        2'd0, 2'd1: begin sio_c <= 1'b1; sda_out <= 1'b1; sda_oe <= 1'b1; end
                        2'd2, 2'd3: begin sio_c <= 1'b1; sda_out <= 1'b0; end
                    endcase
                    if (phase == 2'd3 && phase_tick)
                        state <= SHIFT_BYTE;
                end

                SHIFT_BYTE: begin
                    sda_out <= shift_reg[7];
                    sda_oe  <= 1'b1;
                    case (phase)
                        2'd0, 2'd1: sio_c <= 1'b0;
                        2'd2, 2'd3: sio_c <= 1'b1;   // slave samples here
                    endcase
                    if (phase == 2'd3 && phase_tick) begin
                        shift_reg <= {shift_reg[6:0], 1'b0};
                        if (bit_cnt == 3'd0)
                            state <= ACK_BIT;
                        else
                            bit_cnt <= bit_cnt - 3'd1;
                    end
                end

                ACK_BIT: begin
                    sda_oe <= 1'b0;   // release the bus for the slave's ACK
                    case (phase)
                        2'd0, 2'd1: sio_c <= 1'b0;
                        2'd2, 2'd3: sio_c <= 1'b1;
                    endcase
                    if (phase == 2'd3 && phase_tick) begin
                        if (byte_sel == 2'd2) begin
                            state <= STOP_COND;
                        end else begin
                            byte_sel  <= byte_sel + 2'd1;
                            shift_reg <= (byte_sel == 2'd0) ? reg_addr : reg_data;
                            bit_cnt   <= 3'd7;
                            state     <= SHIFT_BYTE;
                        end
                    end
                end

                STOP_COND: begin
                    case (phase)
                        2'd0, 2'd1: begin sio_c <= 1'b0; sda_out <= 1'b0; sda_oe <= 1'b1; end
                        2'd2, 2'd3: begin sio_c <= 1'b1; sda_out <= 1'b1; end
                    endcase
                    if (phase == 2'd3 && phase_tick)
                        state <= DONE_ST;
                end

                DONE_ST: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule



// 2) Sequencer: steps through the register table at power-up, one entry per
//    sccb_master transaction, with an extra wait after the reset entry.
module sccb_sequencer #(
    parameter DEV_ADDR    = 8'h42,
    parameter RESET_WAIT  = 32'd5_000_000   // ~100ms @ 50MHz: settle time after reset
) (
    input  wire sys_clk,
    input  wire rst_n,

    output wire        sio_c,
    inout  wire        sio_d,

    output reg          config_done   // goes high once every entry has been sent
);

    // register table: {register address, value} 
    // Window values (HSTART/HSTOP/HREF/VSTART/VSTOP/VREF) and the final COM7
    // write are the QVGA (320x240) values derived and cross-checked at the
    // top of this file. CLKRC/TSLB/COM10 are unchanged from the verified
    // VGA table since they are not resolution-dependent.
    localparam N_REGS = 12;
    reg [15:0] regtab [0:N_REGS-1];
    initial begin
        regtab[0]  = {8'h12, 8'h80};   // COM7  = RESET
        regtab[1]  = {8'h11, 8'h01};   // CLKRC = clock scale for 30fps
        regtab[2]  = {8'h3a, 8'h04};   // TSLB
        regtab[3]  = {8'h12, 8'h00};   // COM7  = non-reset (QVGA bit added below)
        regtab[4]  = {8'h17, 8'h15};   // HSTART
        regtab[5]  = {8'h18, 8'h03};   // HSTOP
        regtab[6]  = {8'h32, 8'h80};   // HREF
        regtab[7]  = {8'h19, 8'h03};   // VSTART
        regtab[8]  = {8'h1a, 8'h7b};   // VSTOP
        regtab[9]  = {8'h03, 8'h00};   // VREF
        regtab[10] = {8'h15, 8'h00};   // COM10 = no polarity inversion, written
                                        // explicitly instead of relying on the
                                        // post-reset default (which does happen
                                        // to be 0x00, but ov7670_capture.v's
                                        // polarity assumptions deserve a real
                                        // write here, not an assumption about
                                        // reset behaviour)
        regtab[11] = {8'h12, 8'h14};   // COM7  = QVGA | RGB  (COM7_FMT_QVGA | COM7_RGB)
        // after this table, COM15 is written separately below with the
        // combined RGB565 + full-range value, since it's a fixed constant
        // rather than part of the window/format loop
    end

    localparam [7:0] COM15_ADDR = 8'h40;
    localparam [7:0] COM15_VAL  = 8'hD0;  // COM15_RGB565 (0x10) | COM15_R00FF (0xc0)

    localparam ST_IDLE   = 2'd0,
               ST_WAIT   = 2'd1,
               ST_SEND   = 2'd2,
               ST_LAST   = 2'd3;

    reg [1:0]  state;
    reg [3:0]  idx;          // 0 .. N_REGS  (N_REGS index = the extra COM15 write)
    reg [31:0] wait_cnt;
    reg        mstr_start;
    wire       mstr_done;
    wire       mstr_busy;
    reg [7:0]  cur_reg, cur_val;

    sccb_master #(.CLK_DIV(125)) u_master (
        .sys_clk  (sys_clk),
        .rst_n    (rst_n),
        .start    (mstr_start),
        .dev_addr (DEV_ADDR),
        .reg_addr (cur_reg),
        .reg_data (cur_val),
        .busy     (mstr_busy),
        .done     (mstr_done),
        .sio_d    (sio_d),
        .sio_c    (sio_c)
    );

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            idx         <= 4'd0;
            wait_cnt    <= 32'd0;
            mstr_start  <= 1'b0;
            config_done <= 1'b0;
            cur_reg     <= 8'd0;
            cur_val     <= 8'd0;
        end else begin
            mstr_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    idx       <= 4'd0;
                    cur_reg   <= regtab[0][15:8];
                    cur_val   <= regtab[0][7:0];
                    mstr_start<= 1'b1;
                    state     <= ST_SEND;
                end

                ST_SEND: begin
                    if (mstr_done) begin
                        if (idx == 4'd0) begin
                            // just finished the software-reset write - give the
                            // sensor time to settle before sending anything else
                            wait_cnt <= 32'd0;
                            state    <= ST_WAIT;
                        end else if (idx == N_REGS-1) begin
                            // finished the window/format table - send COM15 next
                            cur_reg    <= COM15_ADDR;
                            cur_val    <= COM15_VAL;
                            mstr_start <= 1'b1;
                            state      <= ST_LAST;
                        end else begin
                            idx        <= idx + 4'd1;
                            cur_reg    <= regtab[idx+4'd1][15:8];
                            cur_val    <= regtab[idx+4'd1][7:0];
                            mstr_start <= 1'b1;
                        end
                    end
                end

                ST_WAIT: begin
                    if (wait_cnt == RESET_WAIT) begin
                        idx        <= 4'd1;
                        cur_reg    <= regtab[1][15:8];
                        cur_val    <= regtab[1][7:0];
                        mstr_start <= 1'b1;
                        state      <= ST_SEND;
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                ST_LAST: begin
                    if (mstr_done)
                        config_done <= 1'b1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`timescale 1ns/1ps


module tb_sccb_sequencer;

    // clock/reset
    reg sys_clk = 0;
    reg rst_n   = 0;

    always #10 sys_clk = ~sys_clk;   // 20 ns period -> stands in for 50 MHz

    initial begin
        rst_n = 0;
        repeat (5) @(posedge sys_clk);
        rst_n = 1;
    end

    // DUT
    wire sio_c;
    wire sio_d;
    wire config_done;

    sccb_sequencer #(
        .DEV_ADDR   (8'h42),
        .RESET_WAIT (32'd300)   // real hardware default: 32'd5_000_000 (~100 ms @ 50 MHz)
    ) dut (
        .sys_clk     (sys_clk),
        .rst_n       (rst_n),
        .sio_c       (sio_c),
        .sio_d       (sio_d),
        .config_done (config_done)
    );

    // Open-drain bus: nobody drives it high, the pull-up does. Without this
    // primitive sio_d would simply read 'z' whenever both master and slave
    // release it, instead of the '1' a real pulled-up wire would show.
    pullup (sio_d);

    // expected table
    // Mirrors ov7670_sccb_config.v's regtab[] plus the separate COM15 write,
    // used only to check the bytes the slave BFM actually captured.
    localparam N_EXPECTED = 13;
    reg [7:0] exp_reg [0:N_EXPECTED-1];
    reg [7:0] exp_val [0:N_EXPECTED-1];
    initial begin
        exp_reg[0]=8'h12; exp_val[0]=8'h80;   // COM7  = RESET
        exp_reg[1]=8'h11; exp_val[1]=8'h01;   // CLKRC
        exp_reg[2]=8'h3a; exp_val[2]=8'h04;   // TSLB
        exp_reg[3]=8'h12; exp_val[3]=8'h00;   // COM7  = VGA, non-reset
        exp_reg[4]=8'h17; exp_val[4]=8'h15;   // HSTART
        exp_reg[5]=8'h18; exp_val[5]=8'h03;   // HSTOP
        exp_reg[6]=8'h32; exp_val[6]=8'h80;   // HREF
        exp_reg[7]=8'h19; exp_val[7]=8'h03;   // VSTART
        exp_reg[8]=8'h1a; exp_val[8]=8'h7b;   // VSTOP
        exp_reg[9]=8'h03; exp_val[9]=8'h00;   // VREF
        exp_reg[10]=8'h15; exp_val[10]=8'h00; // COM10 (explicit, no inversion)
        exp_reg[11]=8'h12; exp_val[11]=8'h14; // COM7 = QVGA | RGB
        exp_reg[12]=8'h40; exp_val[12]=8'hD0; // COM15
    end

    // slave bus model
    // Pure observer/responder on the wire; has no access to the DUT's
    // internal signals. txn_byte counts bytes within ONE transaction
    // (0=device addr, 1=reg addr, 2=reg value); word_idx counts completed
    // three-byte transactions (0..12), one per register write.
    reg [3:0]  bitpos;        // 0..7 = data bits, 8 = ack slot
    reg [7:0]  shreg;
    reg [1:0]  txn_byte;
    integer    word_idx;
    reg        bus_active;
    reg        drive_ack;
    reg        armed;         // true right after START, before bit 7's first fall
    reg [7:0]  got_addr, got_reg, got_val;

    initial begin
        bitpos = 4'd0; shreg = 8'd0; txn_byte = 2'd0; word_idx = 0;
        bus_active = 1'b0; drive_ack = 1'b0; armed = 1'b0;
    end

    assign sio_d = drive_ack ? 1'b0 : 1'bz;

    // Reacting directly to edges on sio_c/sio_d (the way a real slave would,
    // since it has no access to sys_clk) avoids the classic testbench race
    // of polling a DUT's own clocked signal on the same clock edge the DUT
    // updates it on, which would otherwise sample every bit one position late.

    // START: SDA falls while SCL is already high.
    always @(negedge sio_d) begin
        if (sio_c) begin
            bus_active <= 1'b1;
            bitpos     <= 4'd0;
            txn_byte   <= 2'd0;
            drive_ack  <= 1'b0;
            armed      <= 1'b1;   // next SCL fall just sets up bit 7; it doesn't complete a bit
            $display("[%0t] [slave] START condition", $time);
        end
    end

    // STOP: SDA rises while SCL is already high.
    always @(posedge sio_d) begin
        if (sio_c && bus_active) begin
            bus_active <= 1'b0;
            drive_ack  <= 1'b0;
            $display("[%0t] [slave] STOP condition  -> write #%0d complete: addr=0x%02h reg=0x%02h val=0x%02h",
                      $time, word_idx, got_addr, got_reg, got_val);
            if (word_idx < N_EXPECTED) begin
                if (got_reg !== exp_reg[word_idx] || got_val !== exp_val[word_idx])
                    $display("    *** MISMATCH *** expected reg=0x%02h val=0x%02h",
                              exp_reg[word_idx], exp_val[word_idx]);
                else
                    $display("    matches expected table entry %0d", word_idx);
            end
            word_idx <= word_idx + 1;
        end
    end

    // Sample a data bit the instant SCL rises (the real slave-sampling point).
    always @(posedge sio_c) begin
        if (bus_active && bitpos < 4'd8)
            shreg <= {shreg[6:0], sio_d};
    end

    // Act at the instant SCL falls: either latch the finished byte and start
    // driving ACK, release ACK and move to the next byte, or just advance.
    always @(negedge sio_c) begin
        if (bus_active && armed) begin
            // This is the SCL fall coming straight out of the START condition:
            // it only pulls SCL low to set up bit 7's phase 0, it does not
            // conclude a bit, so bitpos must stay at 0 for the first capture.
            armed <= 1'b0;
        end else if (bus_active) begin
            if (bitpos == 4'd7) begin
                case (txn_byte)
                    2'd0: got_addr <= shreg;
                    2'd1: got_reg  <= shreg;
                    2'd2: got_val  <= shreg;
                endcase
                $display("[%0t] [slave]   byte %0d = 0x%02h -> ACK", $time, txn_byte, shreg);
                drive_ack <= 1'b1;
                bitpos    <= 4'd8;
            end else if (bitpos == 4'd8) begin
                drive_ack <= 1'b0;
                txn_byte  <= txn_byte + 2'd1;
                bitpos    <= 4'd0;
            end else begin
                bitpos <= bitpos + 4'd1;
            end
        end
    end

    // state names
    // Purely cosmetic: turns the master's numeric state into a readable
    // label whenever it changes, by peeking at the DUT's own internal
    // signal through a hierarchical reference (fine in a testbench).
    reg [63:0] state_name;
    always @(dut.u_master.state) begin
        case (dut.u_master.state)
            3'd0: state_name = "IDLE";
            3'd1: state_name = "START";
            3'd2: state_name = "SHIFT";
            3'd3: state_name = "ACK";
            3'd4: state_name = "STOP";
            3'd5: state_name = "DONE";
            default: state_name = "???";
        endcase
    end

    //  top-level trace
    initial begin
        $display("================================================================");
        $display(" sccb_sequencer / sccb_master simulation starting");
        $display(" RESET_WAIT shrunk to %0d cycles for simulation speed", 300);
        $display("================================================================");
    end

    always @(posedge config_done) begin
        $display("================================================================");
        $display("[%0t] config_done asserted: all %0d writes finished", $time, N_EXPECTED);
        if (word_idx == N_EXPECTED)
            $display(" RESULT: PASS -- all %0d register writes matched the expected table", N_EXPECTED);
        else
            $display(" RESULT: FAIL -- only %0d of %0d writes were observed on the bus", word_idx, N_EXPECTED);
        $display("================================================================");
        #200;
        $finish;
    end

    // Safety net: if something hangs (e.g. the DUT never finishes), stop the
    // simulation instead of letting it run forever.
    initial begin
        #8_000_000;
        $display("*** TIMEOUT: config_done never asserted (stuck after %0d/%0d writes) ***",
                  word_idx, N_EXPECTED);
        $finish;
    end

    // -------------------------------------------------------------- waveform
    initial begin
        $dumpfile("sccb_tb.vcd");
        $dumpvars(0, tb_sccb_sequencer);
    end

endmodule

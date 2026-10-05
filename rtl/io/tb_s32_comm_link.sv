`timescale 1ns/1ps
//============================================================================
// Self-checking testbench for s32_comm_link (two boards, cable crossed).
//
//   iverilog -g2012 -o tb tb_s32_comm_link.sv s32_comm_link.sv && vvp tb
//   (or: verilator --binary --timing -Wno-fatal tb_s32_comm_link.sv s32_comm_link.sv)
//
// It plays the role of the OutRunners game on both boards:
//   1. writes the "V70" signature, enables CN, expects "Z80" at [8..0xA]
//   2. writes node mode (A = master, B = slave), expects link up
//      ([4]=1, [1]=id, [0]=2) on both
//   3. A sends a 0xE0-byte frame, B sends one; checks RX ring slots
//   4. master "additional bytes" [5..0xF] reach the slave
//   5. B drops off; A must declare the link failed ([0] = 0xFF)
//============================================================================
module tb_s32_comm_link;

    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    reg rst = 1'b1;

    // board A
    reg        a_en = 1'b0, a_cn = 1'b0, a_vbl = 1'b0, a_we = 1'b0;
    reg [10:0] a_addr = 11'd0;
    reg  [7:0] a_wd = 8'd0;
    wire [7:0] a_q;
    wire       a_tx, a_up, a_seen;
    reg        a_test = 1'b0, b_test = 1'b0;
    // board B
    reg        b_en = 1'b0, b_cn = 1'b0, b_vbl = 1'b0, b_we = 1'b0;
    reg [10:0] b_addr = 11'd0;
    reg  [7:0] b_wd = 8'd0;
    wire [7:0] b_q;
    wire       b_tx, b_up, b_seen;

    // 2 Mbaud and a 3 ms tick keep the simulation short; the 228-byte DATA
    // frame (about 1.1 ms at 2 Mbaud) fits well inside one tick.
    localparam TICK_CYCLES = 150000;       // 3 ms

    s32_comm_link #(.CLK_HZ(50_000_000), .BAUD(2_000_000), .LOSS_TICKS(20)) dutA (
        .clk_sys(clk), .rst(rst),
        .cpu_we_ram(a_we), .cpu_addr(a_addr), .cpu_wdata(a_wd), .comm_q(a_q),
        .cabinet_id_q(), .link_enable(a_en), .link_master(1'b0), .cabinet_id(2'b00),
        .baud_sel(2'd0), .link_test(a_test), .peer_seen(a_seen),
        .cn_enable(a_cn), .vbl_start(a_vbl),
        .link_txd(a_tx), .link_rxd(b_tx), .link_up(a_up));

    s32_comm_link #(.CLK_HZ(50_000_000), .BAUD(2_000_000), .LOSS_TICKS(20)) dutB (
        .clk_sys(clk), .rst(rst),
        .cpu_we_ram(b_we), .cpu_addr(b_addr), .cpu_wdata(b_wd), .comm_q(b_q),
        .cabinet_id_q(), .link_enable(b_en), .link_master(1'b0), .cabinet_id(2'b00),
        .baud_sel(2'd0), .link_test(b_test), .peer_seen(b_seen),
        .cn_enable(b_cn), .vbl_start(b_vbl),
        .link_txd(b_tx), .link_rxd(a_tx), .link_up(b_up));

    // vblank generators (B is offset so the boards are not in lock-step)
    initial begin
        forever begin
            repeat (TICK_CYCLES) @(posedge clk);
            a_vbl <= 1'b1; @(posedge clk); a_vbl <= 1'b0;
        end
    end
    initial begin
        repeat (TICK_CYCLES/3) @(posedge clk);
        forever begin
            repeat (TICK_CYCLES) @(posedge clk);
            b_vbl <= 1'b1; @(posedge clk); b_vbl <= 1'b0;
        end
    end

    // CPU write helpers (one-cycle write strobe, like the V70 bus)
    task wrA(input [10:0] ad, input [7:0] d);
        begin
            @(posedge clk); a_we <= 1'b1; a_addr <= ad; a_wd <= d;
            @(posedge clk); a_we <= 1'b0;
        end
    endtask
    task wrB(input [10:0] ad, input [7:0] d);
        begin
            @(posedge clk); b_we <= 1'b1; b_addr <= ad; b_wd <= d;
            @(posedge clk); b_we <= 1'b0;
        end
    endtask

    integer errors = 0;
    integer i;

    task check(input [255:0] what, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL  %0s: got %02x expected %02x (t=%0t)", what, got, exp, $time);
            end
        end
    endtask

    // Wait for n vblanks of board A, then 2 ms more.  By then both boards have
    // finished their tick work (the engine needs ~100 us, and board B ticks
    // 1 ms after A) and all frames are on the wire, so RAM can be inspected
    // without catching an engine mid-update.
    task ticks(input integer n);
        begin repeat (n) @(posedge a_vbl); #2_000_000; end
    endtask

    // watchdog
    initial begin
        #600_000_000;
        $display("FAIL  watchdog timeout");
        $finish;
    end

    initial begin
        repeat (10) @(posedge clk);
        rst = 1'b0;
        a_en = 1'b1; b_en = 1'b1;

        // ---- 0. link-test mode: frames flow with no game running ----
        $display("-- link test (diagnostic)");
        if (a_seen || b_seen) begin errors = errors + 1; $display("FAIL  peer_seen high before any frame"); end
        a_test = 1'b1; b_test = 1'b1;
        ticks(4);
        if (!a_seen || !b_seen) begin errors = errors + 1; $display("FAIL  peer_seen low in link test a=%b b=%b", a_seen, b_seen); end
        if (a_up || b_up) begin errors = errors + 1; $display("FAIL  link_up in link test"); end
        a_test = 1'b0; b_test = 1'b0;
        ticks(2);

        // ---- 1. boot handshake ----
        $display("-- boot handshake");
        wrA(0, 8'h56); wrA(1, 8'h37); wrA(2, 8'h30);
        wrB(0, 8'h56); wrB(1, 8'h37); wrB(2, 8'h30);
        a_cn = 1'b1; b_cn = 1'b1;
        ticks(3);
        check("A Z80[8]", dutA.comm_ram[8],  8'h5A);
        check("A Z80[9]", dutA.comm_ram[9],  8'h38);
        check("A Z80[A]", dutA.comm_ram[10], 8'h30);
        check("B Z80[8]", dutB.comm_ram[8],  8'h5A);
        check("B Z80[9]", dutB.comm_ram[9],  8'h38);
        check("B Z80[A]", dutB.comm_ram[10], 8'h30);
        check("A status waiting", dutA.comm_ram[4], 8'h00);
        if (a_up || b_up) begin errors = errors + 1; $display("FAIL  link up too early"); end

        // ---- 2. modes -> link up ----
        $display("-- link up");
        wrA(2, 8'h01);   // master
        wrB(2, 8'h00);   // slave
        ticks(8);
        check("A count",  dutA.comm_ram[0], 8'h02);
        check("A id",     dutA.comm_ram[1], 8'h01);
        check("A status", dutA.comm_ram[4], 8'h01);
        check("B count",  dutB.comm_ram[0], 8'h02);
        check("B id",     dutB.comm_ram[1], 8'h02);
        check("B status", dutB.comm_ram[4], 8'h01);
        if (!a_up || !b_up) begin errors = errors + 1; $display("FAIL  link_up flags a=%b b=%b", a_up, b_up); end

        // ---- 3a. A -> B frame ----
        $display("-- A->B frame");
        for (i = 0; i < 224; i = i + 1) wrA(11'h710 + i, i[7:0] ^ 8'hA5);
        wrA(3, 8'h01);
        ticks(4);
        for (i = 0; i < 224; i = i + 1) begin
            if (dutB.comm_ram[11'h010 + i] !== (i[7:0] ^ 8'hA5)) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL  B RX slot0[%0d] = %02x", i, dutB.comm_ram[11'h010 + i]);
            end
            if (dutA.comm_ram[11'h010 + i] !== (i[7:0] ^ 8'hA5)) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL  A own slot0[%0d] = %02x", i, dutA.comm_ram[11'h010 + i]);
            end
        end
        check("A ready flag cleared", dutA.comm_ram[3], 8'h00);

        // ---- 3b. B -> A frame ----
        $display("-- B->A frame");
        for (i = 0; i < 224; i = i + 1) wrB(11'h710 + i, i[7:0] ^ 8'h3C);
        wrB(3, 8'h01);
        ticks(4);
        for (i = 0; i < 224; i = i + 1) begin
            if (dutA.comm_ram[11'h0F0 + i] !== (i[7:0] ^ 8'h3C)) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL  A RX slot1[%0d] = %02x", i, dutA.comm_ram[11'h0F0 + i]);
            end
            if (dutB.comm_ram[11'h0F0 + i] !== (i[7:0] ^ 8'h3C)) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL  B own slot1[%0d] = %02x", i, dutB.comm_ram[11'h0F0 + i]);
            end
        end
        check("B ready flag cleared", dutB.comm_ram[3], 8'h00);

        // ---- 4. master additional bytes ----
        $display("-- master FD bytes");
        for (i = 0; i < 11; i = i + 1) wrA(11'd5 + i, 8'hC0 + i[7:0]);
        ticks(4);
        for (i = 0; i < 11; i = i + 1)
            check("B FD byte", dutB.comm_ram[11'd5 + i], 8'hC0 + i[7:0]);

        // ---- 5. peer disappears ----
        $display("-- peer lost");
        b_en = 1'b0;
        ticks(30);
        check("A link failed marker", dutA.comm_ram[0], 8'hFF);
        if (a_up) begin errors = errors + 1; $display("FAIL  A still reports link up"); end

        if (errors == 0) $display("PASS  all checks");
        else             $display("FAILED  %0d error(s)", errors);
        $finish;
    end

endmodule

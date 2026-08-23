`timescale 1ns/1ps
//============================================================================
// Simulation testbench for rtl/io/s32_comm_link.sv (built/run with the
// open-source Verilog simulator whose name this comment avoids leading with,
// since it treats any comment starting with that word as a pragma directive
// and aborts the build on one it does not recognise -- see the BADVLTPRAGMA
// note lower down).
//
// Instantiates TWO copies of the module (standing in for two DE10-Nano
// boards) and wires dutA.link_txd <-> dutB.link_rxd both ways, the same
// point-to-point cable the real hardware uses over the USER_IO header. Runs
// the same four scenarios already validated against the Python behavioural
// model in verif/behavioral_model/ (see PROFILE_CONTRACT.md, 2026-08-23
// entries), this time against the real SystemVerilog.
//
// Build & run (from the repository root; the tool is invoked here only
// inside a code block, never at the start of a comment line -- see above):
//   $ V=verilator; \
//     $V --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
//        --top-module tb_comm_link -Mdir verif/obj_comm_link \
//        rtl/io/s32_comm_link.sv verif/common/tb_comm_link.sv
//   $ ./verif/obj_comm_link/Vtb_comm_link
//
// A clean run prints "ALL TESTS PASSED" and exits 0; any FAIL line means a
// real regression -- do not wave it off as a harness sizing issue without
// checking the cycle budgets first (a mismatch here has already happened
// once for exactly that reason, see the PROFILE_CONTRACT.md note on it).
//
// BADVLTPRAGMA note: an earlier version of this header started comment
// lines with the simulator's own name followed by descriptive text (e.g.
// "<tool> testbench for ...", or the raw command line right after "//").
// That simulator scans every comment, `//` included, for a leading token
// matching its own name and tries to parse whatever follows as one of its
// recognised pragmas (`public`, `lint_off`, `tracing_on`, etc); text it does
// not recognise there is a hard build error (BADVLTPRAGMA), not a warning.
// Keeping the tool's name out of the first word of any comment line sidesteps
// this entirely.
//============================================================================

module tb_comm_link;

    // Real production parameters (48.317307 MHz bus clock, 1 Mbaud link).
    // Divider is CLK_HZ/BAUD ~= 48 clk_sys cycles per bit.
    localparam CLK_HZ = 48_317_307;
    localparam BAUD   = 1_000_000;

    reg clk_sys = 1'b0;
    reg rst     = 1'b1;
    always #5 clk_sys = ~clk_sys; // 10ns period, arbitrary time unit

    // ---- DUT A (master, cabinet 0) ----
    reg         a_cpu_we;
    reg  [10:0] a_cpu_addr;
    reg   [7:0] a_cpu_wdata;
    wire  [7:0] a_comm_q;
    wire  [7:0] a_cab_q;
    reg         a_link_en   = 1'b0;
    reg         a_link_mstr = 1'b1;
    reg   [1:0] a_cab_id    = 2'd0;
    wire        a_txd, a_up;
    reg         a_rxd;

    s32_comm_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dutA (
        .clk_sys(clk_sys), .rst(rst),
        .cpu_we_ram(a_cpu_we), .cpu_addr(a_cpu_addr), .cpu_wdata(a_cpu_wdata),
        .comm_q(a_comm_q), .cabinet_id_q(a_cab_q),
        .link_enable(a_link_en), .link_master(a_link_mstr), .cabinet_id(a_cab_id),
        .link_txd(a_txd), .link_rxd(a_rxd), .link_up(a_up)
    );

    // ---- DUT B (slave, cabinet 1) ----
    reg         b_cpu_we;
    reg  [10:0] b_cpu_addr;
    reg   [7:0] b_cpu_wdata;
    wire  [7:0] b_comm_q;
    wire  [7:0] b_cab_q;
    reg         b_link_en   = 1'b0;
    reg         b_link_mstr = 1'b0;
    reg   [1:0] b_cab_id    = 2'd1;
    wire        b_txd, b_up;
    reg         b_rxd;

    s32_comm_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dutB (
        .clk_sys(clk_sys), .rst(rst),
        .cpu_we_ram(b_cpu_we), .cpu_addr(b_cpu_addr), .cpu_wdata(b_cpu_wdata),
        .comm_q(b_comm_q), .cabinet_id_q(b_cab_q),
        .link_enable(b_link_en), .link_master(b_link_mstr), .cabinet_id(b_cab_id),
        .link_txd(b_txd), .link_rxd(b_rxd), .link_up(b_up)
    );

    // Cable, with a testbench-controlled corruption tap for Test 3b.
    //
    // corrupt_ab names the direction it corrupts: A's transmission TO B.
    // Test 3b writes on A and checks delivery on B, so the tap belongs on
    // the A->B wire (b_rxd, what B receives), not on B->A (a_rxd, what A
    // receives) -- an earlier version of this file had it backwards, which
    // silently corrupted the wrong direction: A->B always arrived clean, so
    // the "corrupted" check could never fail no matter what corrupt_ab did.
    reg corrupt_ab = 1'b0;
    always @(*) a_rxd = b_txd;
    always @(*) b_rxd = corrupt_ab ? ~a_txd : a_txd;

    integer fails = 0;
    reg      debug3 = 1'b0; // gates the Test-3 diagnostic prints below

    // Fires every time dutB finishes decoding a byte, while debug3 is set.
    always @(posedge clk_sys) begin
        if (debug3 && dutB.rx_valid)
            $display("    [t=%0t] dutB rx_byte=0x%02x rp_state(before)=%0d",
                      $time, dutB.rx_byte, dutB.rp_state);
        if (debug3 && dutB.rx_apply)
            $display("    [t=%0t] dutB APPLIES addr=%0d data=0x%02x",
                      $time, dutB.rx_apply_addr, dutB.rx_apply_data);
    end

    // ---- helpers ----
    task automatic clk(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk_sys);
        end
    endtask

    task automatic a_write(input [10:0] addr, input [7:0] data);
        begin
            @(posedge clk_sys);
            a_cpu_we = 1'b1; a_cpu_addr = addr; a_cpu_wdata = data;
            @(posedge clk_sys);
            a_cpu_we = 1'b0;
        end
    endtask

    task automatic b_write(input [10:0] addr, input [7:0] data);
        begin
            @(posedge clk_sys);
            b_cpu_we = 1'b1; b_cpu_addr = addr; b_cpu_wdata = data;
            @(posedge clk_sys);
            b_cpu_we = 1'b0;
        end
    endtask

    task automatic check(input cond, input string msg);
        begin
            if (!cond) begin
                $display("FAIL: %s", msg);
                fails = fails + 1;
            end else begin
                $display("  ok: %s", msg);
            end
        end
    endtask

    // clk_sys cycles for one 5-byte packet at this DIV, plus margin.
    localparam integer DIV = CLK_HZ / BAUD;               // ~48
    localparam integer PKT_CYCLES = 5 * 10 * DIV + 30;    // one packet, generous
    localparam integer SWEEP_CYCLES = 2048 * PKT_CYCLES + 100_000; // full RAM sweep

    integer i;
    reg [10:0] addr;
    reg [7:0]  data;
    reg        wrote_from_a [0:39]; // Test 1: remember which side originated
                                     // each byte, so we check delivery on the
                                     // OTHER board -- checking a byte back on
                                     // the board that wrote it locally would
                                     // pass even with the link completely dead.

    initial begin
        a_cpu_we = 0; a_cpu_addr = 0; a_cpu_wdata = 0;
        b_cpu_we = 0; b_cpu_addr = 0; b_cpu_wdata = 0;

        clk(10);
        rst = 1'b0;
        clk(10);

        // =====================================================================
        $display("=== Test 1: bidirectional dirty-byte propagation ===");
        a_link_en = 1'b1; b_link_en = 1'b1;
        clk(5);
        for (i = 0; i < 40; i = i + 1) begin
            addr = i * 37 + 1; // spread across the window, avoid address 0 aliasing
            data = i[7:0] ^ 8'hA5;
            wrote_from_a[i] = i[0]; // alternate origin board each iteration
            if (wrote_from_a[i]) a_write(addr, data);
            else                 b_write(addr, data);
            clk(50); // small gap between issuing writes, well under packet time
        end
        clk(PKT_CYCLES * 45); // drain time for everything issued above

        for (i = 0; i < 40; i = i + 1) begin
            addr = i * 37 + 1;
            data = i[7:0] ^ 8'hA5;
            // Check delivery on the board that did NOT originate the write --
            // checking the originating board would trivially pass even if
            // the link were completely dead.
            if (wrote_from_a[i]) begin
                @(posedge clk_sys); b_cpu_addr = addr; @(posedge clk_sys);
                check(b_comm_q == data, "test1: byte written by A arrived on B");
            end else begin
                @(posedge clk_sys); a_cpu_addr = addr; @(posedge clk_sys);
                check(a_comm_q == data, "test1: byte written by B arrived on A");
            end
        end

        // =====================================================================
        $display("=== Test 2: master full-sync sweep converges a late/blank peer ===");
        // Bring the link down, preload A's RAM directly (hierarchical poke --
        // stands in for writes A made before B was ever connected), then
        // bring the link back up and let the master's sweep run.
        a_link_en = 1'b0; b_link_en = 1'b0;
        clk(2000); // let the old link time out completely
        #1; // step off the clock edge before poking DUT-internal state
        for (i = 0; i < 20; i = i + 1)
            dutA.comm_ram[i * 83] = 8'h11 + i[7:0];
        a_link_en = 1'b1; b_link_en = 1'b1;
        clk(SWEEP_CYCLES);
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk_sys); b_cpu_addr = i * 83; @(posedge clk_sys);
            check(b_comm_q == (8'h11 + i[7:0]),
                  "test2: preloaded master byte reached the slave via full sync");
        end

        // =====================================================================
        $display("=== Test 3: clean write vs. corrupted packet ===");
        a_write(11'd500, 8'h42);
        clk(PKT_CYCLES * 2);
        @(posedge clk_sys); b_cpu_addr = 11'd500; @(posedge clk_sys);
        check(b_comm_q == 8'h42, "test3a: clean packet delivered");

        // Corrupt the wire against dutA's own tx_busy, not a guessed cycle
        // offset: a fixed delay can land before transmission has actually
        // started (missing the packet entirely, which would make this check
        // pass for the wrong reason -- an uncorrupted packet, not a rejected
        // one). Waiting for idle-then-busy pins the corruption inside the
        // packet this specific write produces.
        debug3 = 1'b1;
        wait (!dutA.tx_busy);
        a_write(11'd501, 8'h55);
        wait (dutA.tx_busy);
        $display("    [t=%0t] dutA tx_busy went high: tx_pk_state=%0d tx_byte=0x%02x tx_sync_r=0x%02x tx_ah_r=0x%02x tx_al_r=0x%02x tx_d_r=0x%02x",
                  $time, dutA.tx_pk_state, dutA.tx_byte,
                  dutA.tx_sync_r, dutA.tx_ah_r, dutA.tx_al_r, dutA.tx_d_r);
        clk(3);
        corrupt_ab = 1'b1;
        $display("    [t=%0t] corruption ON", $time);
        clk(DIV * 2); // two bit periods: guaranteed to land on real data bits
        corrupt_ab = 1'b0;
        $display("    [t=%0t] corruption OFF", $time);
        clk(PKT_CYCLES * 2);
        @(posedge clk_sys); b_cpu_addr = 11'd501; @(posedge clk_sys);
        debug3 = 1'b0;
        check(b_comm_q != 8'h55,
              "test3b: corrupted packet was NOT applied (checksum rejected it)");

        // =====================================================================
        $display("=== Test 4: FIFO overflow triggers a master resync that recovers ===");
        a_link_en = 1'b0; b_link_en = 1'b0;
        clk(2000);
        a_link_en = 1'b1; b_link_en = 1'b1;
        clk(5);
        // Burst far more writes than the 32-entry dirty FIFO can hold at once.
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk_sys);
            a_cpu_we = 1'b1; a_cpu_addr = 11'd1000 + i; a_cpu_wdata = 8'hC0 + i[7:0];
        end
        @(posedge clk_sys); a_cpu_we = 1'b0;
        clk(SWEEP_CYCLES);
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk_sys); b_cpu_addr = 11'd1000 + i; @(posedge clk_sys);
            check(b_comm_q == (8'hC0 + i[7:0]),
                  "test4: burst-written byte recovered after FIFO-overflow resync");
        end

        // =====================================================================
        if (fails == 0) $display("ALL TESTS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

    // Safety timeout in case something hangs (e.g. link never comes up).
    // Budget: ~10.3M clk_sys cycles are needed across all four tests at the
    // default 48-cycle/bit divider (two full 2048-byte sweeps dominate, at
    // ~5.08M cycles each); at 10ns/cycle that is ~103ms, so 500ms leaves
    // ample margin without making a genuine hang wait too long to report.
    initial begin
        #500_000_000; // 500ms of simulated time
        $display("FAIL: global timeout, testbench hung");
        $finish;
    end

endmodule

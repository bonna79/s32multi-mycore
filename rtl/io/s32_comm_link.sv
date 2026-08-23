//============================================================================
//  Sega System 32 / Multi 32 -- comm-board physical link (NEW, non-authentic
//  transport; the register map it feeds is evidenced, the wire protocol is
//  not).
//
//  Hardware context (evidenced): the real "System 32 Multi COMM board"
//  (837-8792) links two cabinets with a point-to-point serial cable, using
//  connectors CN8 (TX) and CN9 (RX) on the board (see MAME sega/segas32.cpp
//  comments and the board's own silkscreen). MAME's own s32comm device is a
//  local HLE stub: it never actually opens a socket or a serial port, it just
//  answers "link not connected" -- so there is no MAME reference behaviour to
//  match here. Everything below the register-map layer (CN/FG semantics,
//  share RAM address map) is therefore a NEW transport we designed to move
//  bytes over a real cable between two physical MiSTer boards, not a
//  byte-exact reproduction of Sega's original serial protocol, which is not
//  in the evidence ledger.
//
//  Two boards are wired TXD(A) -> RXD(B) and TXD(B) -> RXD(A) through the
//  MiSTer USER_IO header (3.3V single-ended UART, not RS-422 like the real
//  cabinet cable -- fine for a short direct cable between two DE10-Nano
//  boards, but it is not electrically compatible with a genuine 837-8792
//  cable).
//
//  Modes (OSD-selected):
//    link_enable = 0  Standalone. Byte-identical to the pre-existing
//                     disconnected-link HLE: comm_ram is purely local, CN/FG
//                     behave exactly as before, no bytes ever go on the wire.
//    link_enable = 1  Network. Every CPU write to the 0x800000-0x800FFF share
//                     window is also queued and streamed to the peer; every
//                     valid packet received from the peer is applied to the
//                     local copy at the same address. Both boards' CPUs keep
//                     reading only their OWN comm_ram (and their own CN/FG),
//                     matching MAME's per-board register semantics -- only
//                     the backing store is now kept in sync over the cable.
//
//  link_master gives the two boards distinct roles only at link-establishment
//  time: when the link first comes up, the master pushes a full snapshot of
//  its comm_ram to the slave (so a board that joins late, or reset later,
//  converges to the master's state instead of racing it). After that initial
//  sweep both sides are symmetric: either side's writes propagate to the
//  other. There is no evidence for what role the real hardware assigns here;
//  this is our own tie-break rule.
//
//  cabinet_id is carried in the heartbeat packet and exposed read-only at
//  0x801004 (a NEW, non-authentic register -- stock ROMs do not query it).
//  It exists so a future multi-cabinet extension, or a custom ROM patch,
//  has somewhere to read the configured id from; today nothing in the
//  supported game set consumes it.
//============================================================================

module s32_comm_link #(
    parameter CLK_HZ  = 48_317_307,
    parameter BAUD    = 1_000_000,
    // Heartbeat cadence and peer timeout, in clk_sys cycles.
    parameter HEARTBEAT_CYCLES = CLK_HZ / 60,       // ~1 per video frame
    parameter LINK_TIMEOUT_CYCLES = CLK_HZ / 8      // ~125 ms of silence -> down
) (
    input             clk_sys,
    input             rst,

    // CPU side (same signals s32_core.sv already computes for the old stub)
    input             cpu_we_ram,     // m_req & m_we & sel_comm_ram & m_be[0]
    input      [10:0] cpu_addr,       // A[11:1]
    input       [7:0] cpu_wdata,
    output reg  [7:0] comm_q,         // registered read data, 1 cycle latency

    // extra non-authentic id readback (0x801004, byte D[7:0])
    output      [7:0] cabinet_id_q,

    // link configuration (OSD)
    input             link_enable,    // 0 = standalone, 1 = network
    input             link_master,    // meaningful only at link-up
    input       [1:0] cabinet_id,

    // physical pins (USER_IO)
    output            link_txd,
    input             link_rxd,

    output            link_up
);

// ---------------------------------------------------------------------------
// Shared RAM storage (unchanged from the original stub: 2048 bytes, byte
// D[7:0] only, power-up zero, no synchronous reset -- see the s32_core.sv
// comment this block was moved out of).
// ---------------------------------------------------------------------------
reg [7:0] comm_ram [0:2047];
integer   init_i;
initial begin
    for (init_i = 0; init_i < 2048; init_i = init_i + 1)
        comm_ram[init_i] = 8'h00;
end

assign cabinet_id_q = {6'h00, cabinet_id};

// ---------------------------------------------------------------------------
// UART bit engine (8N1, fixed divider). One transmitter, one receiver.
// ---------------------------------------------------------------------------
localparam integer DIV = CLK_HZ / BAUD;

// ---- TX ----
reg        tx_busy;
reg  [3:0] tx_bitcnt;
reg [15:0] tx_div;
reg  [9:0] tx_shift;   // {stop, data[7:0], start}
reg        txd_r;
assign link_txd = txd_r;

reg        tx_start;
reg  [7:0] tx_byte;

always @(posedge clk_sys) begin
    if (rst || !link_enable) begin
        tx_busy   <= 1'b0;
        txd_r     <= 1'b1;   // idle mark
        tx_div    <= 16'd0;
        tx_bitcnt <= 4'd0;
    end else if (tx_start && !tx_busy) begin
        tx_shift  <= {1'b1, tx_byte, 1'b0}; // stop,data[7:0],start (LSB first out)
        tx_busy   <= 1'b1;
        tx_div    <= DIV[15:0];
        tx_bitcnt <= 4'd10;
        txd_r     <= 1'b0; // start bit immediately
    end else if (tx_busy) begin
        if (tx_div == 16'd0) begin
            tx_div    <= DIV[15:0] - 16'd1;
            tx_shift  <= {1'b1, tx_shift[9:1]};
            txd_r     <= tx_shift[1];
            tx_bitcnt <= tx_bitcnt - 4'd1;
            if (tx_bitcnt == 4'd1) tx_busy <= 1'b0;
        end else begin
            tx_div <= tx_div - 16'd1;
        end
    end
end

// ---- RX ----
reg  [1:0] rxd_sync;
wire       rxd = rxd_sync[1];
always @(posedge clk_sys) rxd_sync <= {rxd_sync[0], link_rxd};

// Three explicit phases, not a single "busy" flag: IDLE (searching for a
// start edge), DATA (sampling the 8 data bits), STOP (waiting out one more
// bit period before it is safe to search for a new start bit again).
//
// A behavioural-model bug hunt (see PROFILE_CONTRACT.md, this session) found
// that collapsing STOP into "finalize and immediately go back to searching"
// is unsafe: the byte is correctly decoded as soon as the 8th data bit's
// mid-point is sampled, which is *before* that bit's period, let alone the
// stop bit, actually ends on the wire. Whenever the last data bit (MSB) is
// 0, the line is still logically low at that instant, and an idle-search
// state re-arms on the very next cycle -- misreading the tail of the SAME
// byte as a brand-new start bit and corrupting everything that follows.
// Waiting through an explicit STOP phase (ignoring its sampled value, same
// as the TX side does not check for framing errors either) fixes this.
localparam RX_IDLE = 2'd0, RX_DATA = 2'd1, RX_STOP = 2'd2;
reg  [1:0] rx_phase;
reg  [3:0] rx_bitcnt;
reg [15:0] rx_div;
reg  [7:0] rx_shift;
reg        rx_valid;   // one-cycle strobe
reg  [7:0] rx_byte;

always @(posedge clk_sys) begin
    rx_valid <= 1'b0;
    if (rst || !link_enable) begin
        rx_phase <= RX_IDLE;
    end else begin
        case (rx_phase)
            RX_IDLE: begin
                if (!rxd) begin // start bit edge (already synced/registered)
                    rx_phase <= RX_DATA;
                    rx_div   <= DIV[15:0] + {1'b0, DIV[15:1]}; // sample mid-bit (1.5*DIV)
                    // 7, not 8: the finalize branch below (bitcnt==0)
                    // performs the 8th and last sample itself, so only 7
                    // preceding decrements are needed. Starting at 8 would
                    // shift in a 9th (stop-bit) sample, pushing data bit 0
                    // out of the 8-bit shift register.
                    rx_bitcnt <= 4'd7;
                end
            end
            RX_DATA: begin
                if (rx_div == 16'd0) begin
                    rx_div   <= DIV[15:0] - 16'd1;
                    rx_shift <= {rxd, rx_shift[7:1]};
                    if (rx_bitcnt == 4'd0) begin
                        rx_byte  <= {rxd, rx_shift[7:1]};
                        rx_valid <= 1'b1;
                        rx_phase <= RX_STOP;
                        rx_div   <= DIV[15:0] - 16'd1; // one more full bit period
                    end else begin
                        rx_bitcnt <= rx_bitcnt - 4'd1;
                    end
                end else begin
                    rx_div <= rx_div - 16'd1;
                end
            end
            RX_STOP: begin
                if (rx_div == 16'd0) rx_phase <= RX_IDLE;
                else                 rx_div   <= rx_div - 16'd1;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// Dirty-byte TX queue: every local write to the share window, while
// link_enable, is queued as {addr,data} for the peer.
// ---------------------------------------------------------------------------
localparam FIFO_DEPTH_BITS = 5; // 32 entries
reg [18:0] fifo_mem [0:31]; // {addr[10:0], data[7:0]}
reg [FIFO_DEPTH_BITS-1:0] fifo_wp, fifo_rp;
wire fifo_empty = (fifo_wp == fifo_rp);
wire fifo_full  = ((fifo_wp + 1'b1) == fifo_rp);
// A write that arrives while the queue is full is dropped from the network
// (the local comm_ram write below still happens): that byte never reaches
// the peer on its own. Only the master can repair this cheaply, by rearming
// its post-link-up full-RAM sweep (see the next block) so the whole share
// window reconverges soon after. A slave-side overflow has no equivalent
// remedy here and is a known limitation of this non-authentic transport.
wire fifo_overflow_master = cpu_we_ram && fifo_full && link_master;

always @(posedge clk_sys) begin
    if (rst || !link_enable) begin
        fifo_wp <= 5'd0;
    end else if (cpu_we_ram && !fifo_full) begin
        fifo_mem[fifo_wp] <= {cpu_addr, cpu_wdata};
        fifo_wp <= fifo_wp + 1'b1;
    end
end

// ---------------------------------------------------------------------------
// Link-up detection + heartbeat timer.
// ---------------------------------------------------------------------------
reg [31:0] silence_cnt;   // since last valid RX packet
reg [31:0] hb_cnt;        // since last transmitted packet (data or heartbeat)
wire       heartbeat_due = (hb_cnt >= HEARTBEAT_CYCLES[31:0]);
assign     link_up = link_enable && (silence_cnt < LINK_TIMEOUT_CYCLES[31:0]);

// ---------------------------------------------------------------------------
// Master full-sync sweep on link-up.
//
// full_sync_active/full_sync_ctr are owned entirely by the TX scheduler
// always block below (which both arms and advances/clears them): a Verilog
// reg may only be driven from one always block, and the sweep needs to be
// armed (on a link-up edge or a FIFO overflow) and advanced (as each sweep
// byte finishes transmitting) in the same place to avoid a multi-driver
// conflict. This block only tracks the link_up edge that arms it.
// ---------------------------------------------------------------------------
reg        was_up;
always @(posedge clk_sys) begin
    if (rst || !link_enable) was_up <= 1'b0;
    else                     was_up <= link_up;
end
wire arm_full_sync = (link_up && !was_up && link_master) || fifo_overflow_master;

// ---------------------------------------------------------------------------
// Packet parser (RX): SYNC, ADDR_H, ADDR_L, DATA, CHK.
//   SYNC = 8'hA5 -> data-write packet (applies comm_ram[addr] <= data)
//   SYNC = 8'h5A -> heartbeat packet (keepalive only, carries cabinet id)
// ---------------------------------------------------------------------------
localparam SYNC_DATA = 8'hA5;
localparam SYNC_HB   = 8'h5A;

reg [2:0] rp_state;
localparam RP_SYNC=0, RP_AH=1, RP_AL=2, RP_D=3, RP_CHK=4;
reg [7:0] rp_sync, rp_ah, rp_al, rp_d;

reg        rx_apply;
reg [10:0] rx_apply_addr;
reg  [7:0] rx_apply_data;

always @(posedge clk_sys) begin
    rx_apply <= 1'b0;
    if (rst || !link_enable) begin
        rp_state    <= RP_SYNC;
        silence_cnt <= 32'd0;
    end else begin
        if (silence_cnt < LINK_TIMEOUT_CYCLES[31:0]) silence_cnt <= silence_cnt + 32'd1;
        if (rx_valid) begin
            case (rp_state)
                RP_SYNC: begin
                    if (rx_byte == SYNC_DATA || rx_byte == SYNC_HB) begin
                        rp_sync  <= rx_byte;
                        rp_state <= RP_AH;
                    end
                    // else: not a sync byte, keep scanning (byte dropped)
                end
                RP_AH: begin rp_ah <= rx_byte; rp_state <= RP_AL; end
                RP_AL: begin rp_al <= rx_byte; rp_state <= RP_D;  end
                RP_D:  begin rp_d  <= rx_byte; rp_state <= RP_CHK; end
                RP_CHK: begin
                    if (rx_byte == (rp_sync ^ rp_ah ^ rp_al ^ rp_d)) begin
                        // checksum OK
                        silence_cnt <= 32'd0;
                        if (rp_sync == SYNC_DATA) begin
                            rx_apply      <= 1'b1;
                            rx_apply_addr <= {rp_ah[2:0], rp_al};
                            rx_apply_data <= rp_d;
                        end
                    end
                    // whether checksum passed or not, go back to scanning
                    rp_state <= RP_SYNC;
                end
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// comm_ram write arbitration: local CPU write wins over a same-cycle peer
// update; read data keeps the original 1-cycle-latency semantics.
// ---------------------------------------------------------------------------
always @(posedge clk_sys) begin
    if (cpu_we_ram)
        comm_ram[cpu_addr] <= cpu_wdata;
    else if (rx_apply)
        comm_ram[rx_apply_addr] <= rx_apply_data;
    comm_q <= comm_ram[cpu_addr];
end

// ---------------------------------------------------------------------------
// TX scheduler: dirty FIFO first (keeps live gameplay latency low), then the
// master's post-link-up full sweep, then a heartbeat if nothing else is due.
// ---------------------------------------------------------------------------
reg [7:0] tx_sync_r, tx_ah_r, tx_al_r, tx_d_r;
reg       tx_is_fullsync; // latched at TP_IDLE: was THIS packet a full-sync
                          // byte? (fifo_empty can change during the ~50-bit
                          // transmission window, so re-testing it in TP_WAIT
                          // would misclassify the packet and stall the sweep)
reg [2:0] tx_pk_state;
localparam TP_IDLE=0, TP_SYNC=1, TP_AH=2, TP_AL=3, TP_D=4, TP_CHK=5, TP_WAIT=6;
reg        full_sync_active;
reg [10:0] full_sync_ctr;

always @(posedge clk_sys) begin
    tx_start <= 1'b0;
    if (rst || !link_enable) begin
        tx_pk_state <= TP_IDLE;
        fifo_rp     <= 5'd0;
        hb_cnt      <= 32'd0;
        full_sync_active <= 1'b0;
        full_sync_ctr    <= 11'd0;
    end else begin
        if (hb_cnt < HEARTBEAT_CYCLES[31:0]) hb_cnt <= hb_cnt + 32'd1;
        // Arming can land on any cycle, independent of tx_pk_state; a
        // same-cycle collision with the TP_WAIT clear/advance below (an
        // exceedingly rare coincidence -- arming needs a fresh link-up edge
        // or a FIFO overflow, TP_WAIT's own write needs a sweep byte to have
        // just finished transmitting) resolves in program order, i.e. this
        // re-arm loses to that TP_WAIT write; the next arm_full_sync pulse
        // (overflow keeps re-asserting every further dropped write) recovers
        // it, so nothing is lost permanently.
        if (arm_full_sync) begin
            full_sync_active <= 1'b1;
            full_sync_ctr    <= 11'd0;
        end
        case (tx_pk_state)
            TP_IDLE: begin
                tx_is_fullsync <= 1'b0;
                if (!fifo_empty) begin
                    tx_sync_r <= SYNC_DATA;
                    tx_ah_r   <= {5'h00, fifo_mem[fifo_rp][18:16]};
                    tx_al_r   <= fifo_mem[fifo_rp][15:8];
                    tx_d_r    <= fifo_mem[fifo_rp][7:0];
                    fifo_rp   <= fifo_rp + 1'b1;
                    tx_pk_state <= TP_SYNC;
                end else if (full_sync_active) begin
                    tx_sync_r <= SYNC_DATA;
                    tx_ah_r   <= {5'h00, full_sync_ctr[10:8]};
                    tx_al_r   <= full_sync_ctr[7:0];
                    tx_d_r    <= comm_ram[full_sync_ctr];
                    tx_is_fullsync <= 1'b1;
                    tx_pk_state <= TP_SYNC;
                end else if (heartbeat_due) begin
                    tx_sync_r <= SYNC_HB;
                    tx_ah_r   <= 8'h00;
                    tx_al_r   <= 8'h00;
                    tx_d_r    <= {6'h00, cabinet_id};
                    tx_pk_state <= TP_SYNC;
                end
            end
            TP_SYNC: if (!tx_busy) begin tx_byte <= tx_sync_r; tx_start <= 1'b1; tx_pk_state <= TP_AH; end
            TP_AH:   if (!tx_busy && !tx_start) begin tx_byte <= tx_ah_r; tx_start <= 1'b1; tx_pk_state <= TP_AL; end
            TP_AL:   if (!tx_busy && !tx_start) begin tx_byte <= tx_al_r; tx_start <= 1'b1; tx_pk_state <= TP_D; end
            TP_D:    if (!tx_busy && !tx_start) begin tx_byte <= tx_d_r;  tx_start <= 1'b1; tx_pk_state <= TP_CHK; end
            TP_CHK:  if (!tx_busy && !tx_start) begin
                        tx_byte  <= tx_sync_r ^ tx_ah_r ^ tx_al_r ^ tx_d_r;
                        tx_start <= 1'b1;
                        tx_pk_state <= TP_WAIT;
                     end
            TP_WAIT: if (!tx_busy && !tx_start) begin
                        hb_cnt <= 32'd0;
                        if (tx_is_fullsync) begin
                            if (full_sync_ctr == 11'd2047) begin
                                full_sync_active <= 1'b0;
                                full_sync_ctr    <= 11'd0;
                            end else begin
                                full_sync_ctr <= full_sync_ctr + 1'b1;
                            end
                        end
                        tx_pk_state <= TP_IDLE;
                     end
        endcase
    end
end

endmodule

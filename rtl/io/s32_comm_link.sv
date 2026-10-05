//============================================================================
//  Sega Multi 32 -- comm-board HLE ("virtual Z80 board") for OutRunners /
//  Stadium Cross, plus a point-to-point link between TWO MiSTer boards.
//
//  WHAT CHANGED vs the previous version
//  ------------------------------------
//  The old module only mirrored CPU writes of the share window to the peer.
//  The game never got the answers the real comm board (Z80 + EPR-15033)
//  gives, so it reported a network error no matter what the cable did.
//  This version emulates, at register level, what MAME's s32comm.cpp
//  (comm_tick_15033, linktype 15033 = OutRunners / Stadium Cross) does once
//  per vblank, and moves the data between the two boards over the UART.
//
//  GAME-VISIBLE CONTRACT (from MAME s32comm.cpp, comm_tick_15033)
//  --------------------------------------------------------------
//  Share RAM byte index i is at V70 address 0x800000 + 2*i (low byte only).
//    [0]  node count  (board writes; 0xFF = link failed)
//    [1]  node id     (board writes)
//    [2]  node mode   (GAME writes: 0 = slave, 1 = master, 2 = relay)
//    [3]  ready-to-send (GAME writes != 0; board clears it every tick)
//    [4]  link status (board writes: 0 = waiting, 1 = online)
//    [5..0xF]  11 "master additional bytes": master -> slave every tick
//    [0x10 ..]  RX ring, one 0xE0-byte slot per node: slot (id-1)
//    [0x710..0x7EF]  TX frame written by the game (0xE0 bytes)
//  Boot handshake: while the link is not up, if [0..2] == 'V','7','0'
//  (56 37 30) the board zeroes [3..0x7FF] and writes 'Z','8','0'
//  (5A 38 30) at [8..0xA].
//  CN (0x801000) enables the board; vblank is the board's tick.
//
//  WHAT IS (AND IS NOT) HANDLED
//  ----------------------------
//  * Exactly two nodes, master (mode 1) + slave (mode 0). Relay (mode 2)
//    and 3-4 node rings are NOT supported.
//  * The wire protocol is our own (compact, checksummed); MAME's ring frame
//    sizes and its optional frame-sync wait are not reproduced.
//  * Standalone (link_enable = 0) is byte-identical to the old disconnected
//    behaviour: share RAM is plain local RAM, nothing is answered.
//  * OSD "Link Role" / "Cabinet ID" are no longer used: role comes from
//    what the game writes at [2] (service menu).
//
//  Wire format (UART 8N1): A5 | TYPE | payload | CHK
//    TYPE 01 HELLO  payload 1  (sender mode byte; also the heartbeat)
//    TYPE 02 FD     payload 11 (master -> slave, share [5..0xF])
//    TYPE 03 DATA   payload 225 (sender id, then 224 bytes of TX frame)
//    CHK = 5C ^ TYPE ^ all payload bytes
//============================================================================

module s32_comm_link #(
    parameter CLK_HZ            = 48_317_307,
    parameter BAUD              = 250_000,
    // peer silence (in vblank ticks) after which a live link is declared failed
    parameter LOSS_TICKS        = 180,
    // a peer HELLO counts as "fresh" for this many ticks
    parameter HELLO_FRESH_TICKS = 8
) (
    input             clk_sys,
    input             rst,

    // CPU side
    input             cpu_we_ram,     // m_req & m_we & sel_comm_ram & m_be[0]
    input      [10:0] cpu_addr,       // A[11:1]
    input       [7:0] cpu_wdata,
    output reg  [7:0] comm_q,         // registered read data, 1 cycle latency

    output      [7:0] cabinet_id_q,   // legacy non-authentic id readback

    // configuration
    input             link_enable,    // OSD: 0 = standalone, 1 = network
    input             link_master,    // unused (role comes from the game)
    input       [1:0] cabinet_id,     // only feeds cabinet_id_q
    input       [1:0] baud_sel,       // 0: BAUD parameter, 1: 115200, 2: 57600, 3: 500000
    input             link_test,      // diagnostics: run the link engine without a game

    // board state from s32_core
    input             cn_enable,      // CN flip-flop (0x801000 bit 0)
    input             vbl_start,      // vblank start (pulse or level)

    // physical pins (USER_IO)
    output            link_txd,
    input             link_rxd,

    output            link_up,
    output            peer_seen       // a valid frame arrived in the last ~0.7 s
);

localparam integer DIV0 = CLK_HZ / BAUD;      // default: the BAUD parameter
localparam integer DIV1 = CLK_HZ / 115200;
localparam integer DIV2 = CLK_HZ / 57600;
localparam integer DIV3 = CLK_HZ / 500000;
reg [15:0] div_r;
initial div_r = DIV0[15:0];
always @(posedge clk_sys) begin
    case (baud_sel)
        2'd0:    div_r <= DIV0[15:0];
        2'd1:    div_r <= DIV1[15:0];
        2'd2:    div_r <= DIV2[15:0];
        default: div_r <= DIV3[15:0];
    endcase
end

assign cabinet_id_q = {6'h00, cabinet_id};

// link_test forces the engine on even when the game has not enabled the
// board (CN = 0): both MiSTers then exchange HELLO frames every vblank, so the
// cable, pins and baud rate can be checked with no game protocol involved.
wire cn_eff = cn_enable | link_test;
wire act = link_enable && cn_eff;

// ---------------------------------------------------------------------------
// Share RAM. ONE write port shared by the V70 (priority) and the HLE engine.
// Two identical copies are kept so each reader has its own registered read
// port (plain simple-dual-port RAMs, no true-dual-port inference needed).
// An HLE write that collides with a V70 write is held and retried; the HLE
// engine stalls until it has been committed, so no write is ever lost.
// ---------------------------------------------------------------------------
reg [7:0] comm_ram   [0:2047];     // read by the V70
reg [7:0] comm_ram_h [0:2047];     // identical copy, read by the HLE engine
integer   init_i;
initial begin
    for (init_i = 0; init_i < 2048; init_i = init_i + 1) begin
        comm_ram[init_i]   = 8'h00;
        comm_ram_h[init_i] = 8'h00;
    end
end

reg [10:0] h_addr;                 // HLE read address / write address
reg  [7:0] h_wdata;
reg        h_we;                   // one-cycle write request from the engine
reg  [7:0] h_q;
reg        h_pend;
reg [10:0] h_wa;
reg  [7:0] h_wd;
initial h_pend = 1'b0;

wire        wr_en = cpu_we_ram | h_pend;
wire [10:0] wr_a  = cpu_we_ram ? cpu_addr  : h_wa;
wire  [7:0] wr_d  = cpu_we_ram ? cpu_wdata : h_wd;
wire        h_busy = h_we | h_pend;

always @(posedge clk_sys) begin
    if (wr_en) begin
        comm_ram[wr_a]   <= wr_d;
        comm_ram_h[wr_a] <= wr_d;
    end
    comm_q <= comm_ram[cpu_addr];
    h_q    <= comm_ram_h[h_addr];
    if (h_we) begin
        h_pend <= 1'b1;
        h_wa   <= h_addr;
        h_wd   <= h_wdata;
    end else if (h_pend && !cpu_we_ram) begin
        h_pend <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// UART byte engines (8N1, fixed divider)
// ---------------------------------------------------------------------------
reg        tx_busy;
reg  [3:0] tx_bitcnt;
reg [15:0] tx_div;
reg  [9:0] tx_shift;
reg        txd_r;
assign link_txd = txd_r;

reg        tx_start;
reg  [7:0] tx_byte;

initial begin txd_r = 1'b1; tx_busy = 1'b0; end

always @(posedge clk_sys) begin
    if (rst || !link_enable) begin
        tx_busy   <= 1'b0;
        txd_r     <= 1'b1;
        tx_div    <= 16'd0;
        tx_bitcnt <= 4'd0;
    end else if (tx_start && !tx_busy) begin
        tx_shift  <= {1'b1, tx_byte, 1'b0};
        tx_busy   <= 1'b1;
        tx_div    <= div_r;
        tx_bitcnt <= 4'd10;
        txd_r     <= 1'b0;
    end else if (tx_busy) begin
        if (tx_div == 16'd0) begin
            tx_div    <= div_r - 16'd1;
            tx_shift  <= {1'b1, tx_shift[9:1]};
            txd_r     <= tx_shift[1];
            tx_bitcnt <= tx_bitcnt - 4'd1;
            if (tx_bitcnt == 4'd1) tx_busy <= 1'b0;
        end else begin
            tx_div <= tx_div - 16'd1;
        end
    end
end

reg  [1:0] rxd_sync;
wire       rxd = rxd_sync[1];
initial rxd_sync = 2'b11;
always @(posedge clk_sys) rxd_sync <= {rxd_sync[0], link_rxd};

localparam RX_IDLE = 2'd0, RX_DATA = 2'd1, RX_STOP = 2'd2;
reg  [1:0] rx_phase;
reg  [3:0] rx_bitcnt;
reg [15:0] rx_div;
reg  [7:0] rx_shift;
reg        rx_valid;
reg  [7:0] rx_byte;

always @(posedge clk_sys) begin
    rx_valid <= 1'b0;
    if (rst || !link_enable) begin
        rx_phase <= RX_IDLE;
    end else begin
        case (rx_phase)
            RX_IDLE: begin
                if (!rxd) begin
                    rx_phase  <= RX_DATA;
                    rx_div    <= div_r + {1'b0, div_r[15:1]};
                    rx_bitcnt <= 4'd7;
                end
            end
            RX_DATA: begin
                if (rx_div == 16'd0) begin
                    rx_div   <= div_r - 16'd1;
                    rx_shift <= {rxd, rx_shift[7:1]};
                    if (rx_bitcnt == 4'd0) begin
                        rx_byte  <= {rxd, rx_shift[7:1]};
                        rx_valid <= 1'b1;
                        rx_phase <= RX_STOP;
                        rx_div   <= div_r - 16'd1;
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
            default: rx_phase <= RX_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Frame constants
// ---------------------------------------------------------------------------
localparam [7:0] F_SYNC  = 8'hA5;
localparam [7:0] T_HELLO = 8'h01;
localparam [7:0] T_FD    = 8'h02;
localparam [7:0] T_DATA  = 8'h03;
localparam [7:0] CHK0    = 8'h5C;

// ---------------------------------------------------------------------------
// RX frame parser. Frames are staged and only committed when the checksum
// matches. DATA payload goes to a double-buffered RAM (512 x 8).
// ---------------------------------------------------------------------------
localparam RP_SYNC = 2'd0, RP_TYPE = 2'd1, RP_PAY = 2'd2, RP_CHK = 2'd3;

reg  [1:0] rp_state;
reg  [7:0] rp_type;
reg  [7:0] rp_chk;
reg  [7:0] rp_idx;
reg  [7:0] rp_len_m1;
reg  [7:0] rx_hello_tmp;
reg  [7:0] rx_fd_stage [0:15];
reg  [7:0] rx_fd_buf   [0:15];
integer    k;

reg        rxd_we;
reg  [8:0] rxd_waddr;
reg  [7:0] rxd_wdata;

reg        rx_wsel;       // half currently being written
reg        rx_data_sel;   // half holding the newest complete frame
reg  [1:0] rx_data_ev;    // counts DATA frames completed OK
reg  [1:0] rx_fd_ev;      // counts FD frames completed OK
reg  [7:0] peer_mode;
reg  [7:0] hello_age;     // ticks since last valid HELLO (255 = never)
reg  [8:0] rx_age;        // ticks since last valid frame of any type
reg [24:0] seen_cnt;      // hold-off for the peer_seen indicator (about 0.7 s)

wire       tick_go;       // one-cycle strobe: a tick is starting

initial begin
    rp_state = RP_SYNC; rx_wsel = 1'b0; rx_data_sel = 1'b0;
    rx_data_ev = 2'd0; rx_fd_ev = 2'd0; peer_mode = 8'hFF;
    hello_age = 8'hFF; rx_age = 9'd0; seen_cnt = 25'd0;
end

always @(posedge clk_sys) begin
    rxd_we <= 1'b0;
    if (seen_cnt != 25'd0) seen_cnt <= seen_cnt - 25'd1;
    if (rst || !link_enable) begin
        seen_cnt   <= 25'd0;
        rp_state   <= RP_SYNC;
        hello_age  <= 8'hFF;
        rx_age     <= 9'd0;
        peer_mode  <= 8'hFF;
        rx_wsel    <= 1'b0;
        rx_data_sel<= 1'b0;
        rx_data_ev <= 2'd0;
        rx_fd_ev   <= 2'd0;
    end else begin
        if (tick_go) begin
            if (hello_age != 8'hFF) hello_age <= hello_age + 8'd1;
            if (rx_age    != 9'h1FF) rx_age   <= rx_age + 9'd1;
        end
        if (rx_valid) begin
            case (rp_state)
                RP_SYNC: begin
                    if (rx_byte == F_SYNC) rp_state <= RP_TYPE;
                end
                RP_TYPE: begin
                    rp_idx  <= 8'd0;
                    rp_chk  <= CHK0 ^ rx_byte;
                    rp_type <= rx_byte;
                    if      (rx_byte == T_HELLO) begin rp_len_m1 <= 8'd0;   rp_state <= RP_PAY; end
                    else if (rx_byte == T_FD)    begin rp_len_m1 <= 8'd10;  rp_state <= RP_PAY; end
                    else if (rx_byte == T_DATA)  begin rp_len_m1 <= 8'd224; rp_state <= RP_PAY; end
                    else                              rp_state <= RP_SYNC;
                end
                RP_PAY: begin
                    rp_chk <= rp_chk ^ rx_byte;
                    if (rp_type == T_HELLO)     rx_hello_tmp <= rx_byte;
                    else if (rp_type == T_FD)   rx_fd_stage[rp_idx[3:0]] <= rx_byte;
                    else begin
                        rxd_we    <= 1'b1;
                        rxd_waddr <= {rx_wsel, rp_idx};
                        rxd_wdata <= rx_byte;
                    end
                    if (rp_idx == rp_len_m1) rp_state <= RP_CHK;
                    else                     rp_idx   <= rp_idx + 8'd1;
                end
                RP_CHK: begin
                    rp_state <= RP_SYNC;
                    if (rx_byte == rp_chk) begin
                        rx_age   <= 9'd0;
                        seen_cnt <= 25'h1FFFFFF;
                        if (rp_type == T_HELLO) begin
                            peer_mode <= rx_hello_tmp;
                            hello_age <= 8'd0;
                        end else if (rp_type == T_FD) begin
                            for (k = 0; k < 16; k = k + 1)
                                rx_fd_buf[k] <= rx_fd_stage[k];
                            rx_fd_ev <= rx_fd_ev + 2'd1;
                        end else begin
                            rx_data_sel <= rx_wsel;
                            rx_wsel     <= ~rx_wsel;
                            rx_data_ev  <= rx_data_ev + 2'd1;
                        end
                    end
                end
            endcase
        end
    end
end

reg [8:0] rxm_addr;
reg [7:0] rxm_q;
reg [7:0] rxd_mem [0:511];
always @(posedge clk_sys) begin
    if (rxd_we) rxd_mem[rxd_waddr] <= rxd_wdata;
    rxm_q <= rxd_mem[rxm_addr];
end

// ---------------------------------------------------------------------------
// TX frame sender. The tick engine prepares buffers and toggles req_*;
// the sender streams the frame and toggles ack_* when the CHK is queued.
// ---------------------------------------------------------------------------
localparam SN_IDLE = 3'd0, SN_SYNC = 3'd1, SN_TYPE = 3'd2,
           SN_FETCH = 3'd3, SN_PAY = 3'd4, SN_CHK = 3'd5;
localparam [1:0] K_HELLO = 2'd0, K_FD = 2'd1, K_DATA = 2'd2;

reg  [2:0] sn_state;
reg  [1:0] sn_kind;
reg  [7:0] sn_idx;
reg  [7:0] sn_len_m1;
reg  [7:0] sn_chk;

reg        req_hello, req_fd, req_data;   // driven by the tick engine
reg        ack_hello, ack_fd, ack_data;   // driven by the sender
wire hello_pending = req_hello ^ ack_hello;
wire fd_pending    = req_fd    ^ ack_fd;
wire data_pending  = req_data  ^ ack_data;

reg  [7:0] hello_byte;
reg  [7:0] fd_buf [0:15];

reg        db_we;
reg  [7:0] db_waddr;
reg  [7:0] db_wdata;
reg  [7:0] dbuf_q;
reg  [7:0] data_buf [0:255];
always @(posedge clk_sys) begin
    if (db_we) data_buf[db_waddr] <= db_wdata;
    dbuf_q <= data_buf[sn_idx];
end

wire [7:0] pay_byte = (sn_kind == K_HELLO) ? hello_byte :
                      (sn_kind == K_FD)    ? fd_buf[sn_idx[3:0]] : dbuf_q;
wire [7:0] type_byte = (sn_kind == K_HELLO) ? T_HELLO :
                       (sn_kind == K_FD)    ? T_FD    : T_DATA;

initial begin
    sn_state = SN_IDLE;
    req_hello = 1'b0; req_fd = 1'b0; req_data = 1'b0;
    ack_hello = 1'b0; ack_fd = 1'b0; ack_data = 1'b0;
    tx_start = 1'b0;
end

always @(posedge clk_sys) begin
    tx_start <= 1'b0;
    if (rst || !link_enable) begin
        sn_state  <= SN_IDLE;
        ack_hello <= 1'b0;
        ack_fd    <= 1'b0;
        ack_data  <= 1'b0;
    end else begin
        case (sn_state)
            SN_IDLE: begin
                sn_idx <= 8'd0;
                if (!tx_busy && !tx_start) begin
                    if (hello_pending) begin
                        sn_kind <= K_HELLO; sn_len_m1 <= 8'd0;   sn_state <= SN_SYNC;
                    end else if (fd_pending) begin
                        sn_kind <= K_FD;    sn_len_m1 <= 8'd10;  sn_state <= SN_SYNC;
                    end else if (data_pending) begin
                        sn_kind <= K_DATA;  sn_len_m1 <= 8'd224; sn_state <= SN_SYNC;
                    end
                end
            end
            SN_SYNC: if (!tx_busy && !tx_start) begin
                tx_byte  <= F_SYNC;
                tx_start <= 1'b1;
                sn_state <= SN_TYPE;
            end
            SN_TYPE: if (!tx_busy && !tx_start) begin
                tx_byte  <= type_byte;
                sn_chk   <= CHK0 ^ type_byte;
                tx_start <= 1'b1;
                sn_state <= SN_FETCH;
            end
            SN_FETCH: sn_state <= SN_PAY;       // one cycle for dbuf_q
            SN_PAY: if (!tx_busy && !tx_start) begin
                tx_byte  <= pay_byte;
                sn_chk   <= sn_chk ^ pay_byte;
                tx_start <= 1'b1;
                if (sn_idx == sn_len_m1) sn_state <= SN_CHK;
                else begin
                    sn_idx   <= sn_idx + 8'd1;
                    sn_state <= SN_FETCH;
                end
            end
            SN_CHK: if (!tx_busy && !tx_start) begin
                tx_byte  <= sn_chk;
                tx_start <= 1'b1;
                if      (sn_kind == K_HELLO) ack_hello <= req_hello;
                else if (sn_kind == K_FD)    ack_fd    <= req_fd;
                else                         ack_data  <= req_data;
                sn_state <= SN_IDLE;
            end
            default: sn_state <= SN_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Tick engine: what MAME does in comm_tick_15033() once per vblank.
// ---------------------------------------------------------------------------
localparam [5:0]
    TF_IDLE = 6'd0,  TF_W   = 6'd1,
    TF_P1   = 6'd2,  TF_P2  = 6'd3,  TF_P3  = 6'd4,  TF_CLR = 6'd5,
    TF_Z0   = 6'd6,  TF_Z1  = 6'd7,  TF_Z2  = 6'd8,  TF_P4  = 6'd9,
    TF_P5   = 6'd10, TF_L0  = 6'd11, TF_L1  = 6'd12, TF_L2  = 6'd13,
    TF_A0   = 6'd14, TF_RX0 = 6'd15, TF_RX1 = 6'd16, TF_RX2 = 6'd17,
    TF_RX3  = 6'd18, TF_A3  = 6'd19, TF_FD0 = 6'd20, TF_A4  = 6'd21,
    TF_A5   = 6'd22, TF_T0  = 6'd23, TF_T1  = 6'd24, TF_T2  = 6'd25,
    TF_A7   = 6'd26, TF_F0  = 6'd27, TF_F1  = 6'd28, TF_A9  = 6'd29,
    TF_A10  = 6'd30;

reg  [5:0] tf, tf_ret;
reg  [1:0] alive;        // 0 = not up, 1 = up, 2 = failed
reg  [1:0] my_id;        // 1 = master, 2 = slave
reg        my_master;
reg        sig_hit;
reg  [7:0] s0, s1, s2;
reg [10:0] ctr;
reg        tick_req;
reg        vbl_q, cn_q;
reg  [1:0] rx_data_ack, rx_fd_ack;
reg        rx_sel_l;

wire rx_data_pending = (rx_data_ev != rx_data_ack);
wire rx_fd_pending   = (rx_fd_ev   != rx_fd_ack);

wire [10:0] peer_base = (my_id == 2'd1) ? 11'h0F0 : 11'h010;
wire [10:0] own_base  = (my_id == 2'd1) ? 11'h010 : 11'h0F0;
wire  [7:0] peer_id8  = (my_id == 2'd1) ? 8'd2 : 8'd1;

assign tick_go = (tf == TF_IDLE) && tick_req && act && !h_busy;
assign link_up = act && (alive == 2'd1);
assign peer_seen = link_enable && (seen_cnt != 25'd0);

initial begin
    tf = TF_IDLE; alive = 2'd0; my_id = 2'd0; my_master = 1'b0;
    tick_req = 1'b0; rx_data_ack = 2'd0; rx_fd_ack = 2'd0;
    vbl_q = 1'b0; cn_q = 1'b0; h_we = 1'b0; db_we = 1'b0;
end

always @(posedge clk_sys) begin
    h_we  <= 1'b0;
    db_we <= 1'b0;
    vbl_q <= vbl_start;
    cn_q  <= cn_eff;

    if (rst || !link_enable) begin
        tf <= TF_IDLE; alive <= 2'd0; my_id <= 2'd0; my_master <= 1'b0;
        tick_req <= 1'b0;
        req_hello <= 1'b0; req_fd <= 1'b0; req_data <= 1'b0;
        rx_data_ack <= 2'd0; rx_fd_ack <= 2'd0;
    end else if (!cn_eff) begin
        // board disabled by the game: forget the link, drop pending work
        tf <= TF_IDLE; alive <= 2'd0; my_id <= 2'd0; my_master <= 1'b0;
        tick_req <= 1'b0;
        req_hello <= ack_hello; req_fd <= ack_fd; req_data <= ack_data;
        rx_data_ack <= rx_data_ev; rx_fd_ack <= rx_fd_ev;
    end else if (!h_busy) begin
        case (tf)
            TF_IDLE: begin
                if (tick_req) begin
                    tick_req <= 1'b0;
                    if (alive == 2'd2) begin
                        h_addr <= 11'd0; h_wdata <= 8'hFF; h_we <= 1'b1;   // link failed
                    end else if (alive == 2'd0) begin
                        sig_hit <= 1'b0;
                        h_addr  <= 11'd0;
                        tf <= TF_W; tf_ret <= TF_P1;
                    end else begin
                        tf <= TF_A0;
                    end
                end
            end

            TF_W: tf <= tf_ret;     // one wait cycle for the registered RAM read

            // ---- link not yet established ----
            TF_P1: begin s0 <= h_q; h_addr <= 11'd1; tf <= TF_W; tf_ret <= TF_P2; end
            TF_P2: begin s1 <= h_q; h_addr <= 11'd2; tf <= TF_W; tf_ret <= TF_P3; end
            TF_P3: begin
                s2 <= h_q;
                if (s0 == 8'h56 && s1 == 8'h37 && h_q == 8'h30) begin
                    sig_hit <= 1'b1; ctr <= 11'd3; tf <= TF_CLR;       // "V70" seen
                end else tf <= TF_P4;
            end
            TF_CLR: begin
                h_addr <= ctr; h_wdata <= 8'h00; h_we <= 1'b1;
                ctr <= ctr + 11'd1;
                if (ctr == 11'h7FF) tf <= TF_Z0;
            end
            TF_Z0: begin h_addr <= 11'd8;  h_wdata <= 8'h5A; h_we <= 1'b1; tf <= TF_Z1; end
            TF_Z1: begin h_addr <= 11'd9;  h_wdata <= 8'h38; h_we <= 1'b1; tf <= TF_Z2; end
            TF_Z2: begin h_addr <= 11'd10; h_wdata <= 8'h30; h_we <= 1'b1; tf <= TF_P4; end
            TF_P4: begin                                               // status = waiting
                h_addr <= 11'd4; h_wdata <= 8'h00; h_we <= 1'b1;
                tf <= sig_hit ? TF_IDLE : TF_P5;
            end
            TF_P5: begin
                if (s2 == 8'h00 || s2 == 8'h01) begin
                    hello_byte <= s2;
                    if (!hello_pending) req_hello <= ~req_hello;
                    if (hello_age <= HELLO_FRESH_TICKS &&
                        peer_mode == (s2[0] ? 8'h00 : 8'h01)) begin
                        alive     <= 2'd1;
                        my_master <= s2[0];
                        my_id     <= s2[0] ? 2'd1 : 2'd2;
                        tf        <= TF_L0;
                    end else tf <= TF_IDLE;
                end else tf <= TF_IDLE;
            end
            TF_L0: begin h_addr <= 11'd4; h_wdata <= 8'h01;           h_we <= 1'b1; tf <= TF_L1; end
            TF_L1: begin h_addr <= 11'd1; h_wdata <= {6'b0, my_id};   h_we <= 1'b1; tf <= TF_L2; end
            TF_L2: begin h_addr <= 11'd0; h_wdata <= 8'h02;           h_we <= 1'b1; tf <= TF_IDLE; end

            // ---- link established ----
            TF_A0: begin
                if (rx_age > LOSS_TICKS) begin
                    alive <= 2'd2;
                    h_addr <= 11'd0; h_wdata <= 8'hFF; h_we <= 1'b1;
                    tf <= TF_IDLE;
                end else if (rx_data_pending) begin
                    rx_sel_l <= rx_data_sel;
                    rxm_addr <= {rx_data_sel, 8'd0};
                    tf <= TF_RX0;
                end else tf <= TF_A3;
            end
            TF_RX0: tf <= TF_RX1;
            TF_RX1: begin
                rx_data_ack <= rx_data_ev;
                if (rxm_q == peer_id8) begin
                    ctr <= 11'd0;
                    rxm_addr <= {rx_sel_l, 8'd1};
                    tf <= TF_RX2;
                end else tf <= TF_A3;
            end
            TF_RX2: tf <= TF_RX3;
            TF_RX3: begin
                h_addr <= peer_base + ctr; h_wdata <= rxm_q; h_we <= 1'b1;
                ctr <= ctr + 11'd1;
                if (ctr == 11'd223) tf <= TF_A3;
                else begin
                    rxm_addr <= {rx_sel_l, 8'd0} + ctr[8:0] + 9'd2;
                    tf <= TF_RX2;
                end
            end
            TF_A3: begin
                if (!my_master && rx_fd_pending) begin
                    rx_fd_ack <= rx_fd_ev; ctr <= 11'd0; tf <= TF_FD0;
                end else tf <= TF_A4;
            end
            TF_FD0: begin
                h_addr <= 11'd5 + ctr; h_wdata <= rx_fd_buf[ctr[3:0]]; h_we <= 1'b1;
                ctr <= ctr + 11'd1;
                if (ctr == 11'd10) tf <= TF_A4;
            end
            TF_A4: begin h_addr <= 11'd3; tf <= TF_W; tf_ret <= TF_A5; end
            TF_A5: begin
                if (h_q != 8'h00 && !data_pending) begin ctr <= 11'd0; tf <= TF_T0; end
                else tf <= TF_A7;
            end
            TF_T0: begin h_addr <= 11'h710 + ctr; tf <= TF_W; tf_ret <= TF_T1; end
            TF_T1: begin
                db_waddr <= ctr[7:0] + 8'd1; db_wdata <= h_q; db_we <= 1'b1;
                h_addr <= own_base + ctr; h_wdata <= h_q; h_we <= 1'b1;   // own copy in RX ring
                ctr <= ctr + 11'd1;
                if (ctr == 11'd223) tf <= TF_T2; else tf <= TF_T0;
            end
            TF_T2: begin
                db_waddr <= 8'd0; db_wdata <= {6'b0, my_id}; db_we <= 1'b1;
                req_data <= ~req_data;
                tf <= TF_A7;
            end
            TF_A7: begin
                if (my_master && !fd_pending) begin ctr <= 11'd0; tf <= TF_F0; end
                else tf <= TF_A9;
            end
            TF_F0: begin h_addr <= 11'd5 + ctr; tf <= TF_W; tf_ret <= TF_F1; end
            TF_F1: begin
                fd_buf[ctr[3:0]] <= h_q;
                ctr <= ctr + 11'd1;
                if (ctr == 11'd10) begin req_fd <= ~req_fd; tf <= TF_A9; end
                else tf <= TF_F0;
            end
            TF_A9: begin
                hello_byte <= {7'b0, my_master};
                if (!hello_pending) req_hello <= ~req_hello;
                tf <= TF_A10;
            end
            TF_A10: begin                                            // clear ready-to-send
                h_addr <= 11'd3; h_wdata <= 8'h00; h_we <= 1'b1;
                tf <= TF_IDLE;
            end
            default: tf <= TF_IDLE;
        endcase
    end

    // tick sources (set last so a simultaneous clear in TF_IDLE cannot hide a request)
    if (act && vbl_start && !vbl_q) tick_req <= 1'b1;
    if (act && cn_eff && !cn_q)     tick_req <= 1'b1;
end

endmodule

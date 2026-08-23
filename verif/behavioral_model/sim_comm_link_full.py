#!/usr/bin/env python3
"""
Full protocol-level behavioural model of rtl/io/s32_comm_link.sv, built on
top of the bit-accurate, now-corrected UART engine in sim_comm_link.py.
Two Node instances stand in for two DE10-Nano boards wired TXD<->RXD, and
this drives the same packet framing (SYNC,ADDR_H,ADDR_L,DATA,CHK), the same
dirty-byte FIFO, and the same master-only full-sync-on-link-up sweep as the
SystemVerilog.
"""
import random
from sim_comm_link import UartTx

SYNC_DATA = 0xA5
SYNC_HB = 0x5A


class UartRxFixed:
    """The corrected 3-phase RX engine (IDLE/DATA/STOP), matching the
    SystemVerilog after this session's third-bug fix."""
    IDLE, DATA, STOP = range(3)

    def __init__(self, div):
        self.div = div
        self.phase = self.IDLE
        self.bitcnt = 0
        self.divcnt = 0
        self.shift = 0
        self.valid = False
        self.byte_out = None

    def step(self, rxd):
        self.valid = False
        if self.phase == self.IDLE:
            if rxd == 0:
                self.phase = self.DATA
                self.divcnt = self.div + self.div // 2
                self.bitcnt = 7
        elif self.phase == self.DATA:
            if self.divcnt == 0:
                old = self.shift
                self.divcnt = self.div - 1
                self.shift = ((rxd << 7) | (old >> 1)) & 0xFF
                if self.bitcnt == 0:
                    self.byte_out = ((rxd << 7) | (old >> 1)) & 0xFF
                    self.valid = True
                    self.phase = self.STOP
                    self.divcnt = self.div - 1
                else:
                    self.bitcnt -= 1
            else:
                self.divcnt -= 1
        else:
            if self.divcnt == 0:
                self.phase = self.IDLE
            else:
                self.divcnt -= 1
        return self.valid, self.byte_out


class Node:
    """One board's s32_comm_link instance."""

    def __init__(self, div, master, cabinet_id, fifo_depth=32):
        self.div = div
        self.master = master
        self.cabinet_id = cabinet_id
        self.comm_ram = [0] * 2048
        self.tx = UartTx(div)
        self.rx = UartRxFixed(div)
        self.rxd_sync = [1, 1]

        self.fifo = []
        self.fifo_depth = fifo_depth

        self.silence = 0
        self.hb_cnt = 0
        self.HEARTBEAT = div * 60      # mirrors CLK_HZ/60 in the real parameters
        self.LINK_TIMEOUT = div * 450  # mirrors CLK_HZ/8: several heartbeats of margin

        self.was_up = False
        self.full_sync_active = False
        self.full_sync_ctr = 0

        # RX packet parser state
        self.rp_state = 0  # 0 sync,1 ah,2 al,3 d,4 chk
        self.rp = [0, 0, 0, 0]

        # TX packet scheduler state
        self.tp_state = 0  # 0 idle,1 sync,2 ah,3 al,4 d,5 chk,6 wait
        self.tp_bytes = [0, 0, 0, 0]
        self.tx_is_fullsync = False

        self.pending_apply = []  # bytes applied by peer, this "tick", for test observation

    @property
    def link_up(self):
        return self.silence < self.LINK_TIMEOUT

    def cpu_write(self, addr, data):
        self.comm_ram[addr] = data
        if len(self.fifo) < self.fifo_depth:
            self.fifo.append((addr, data))
        else:
            if self.master:
                self.full_sync_active = True
                self.full_sync_ctr = 0

    def _rx_line(self, sync1):
        valid, byte = self.rx.step(sync1)
        if not valid:
            return
        if self.rp_state == 0:
            if byte in (SYNC_DATA, SYNC_HB):
                self.rp[0] = byte
                self.rp_state = 1
        elif self.rp_state == 1:
            self.rp[1] = byte
            self.rp_state = 2
        elif self.rp_state == 2:
            self.rp[2] = byte
            self.rp_state = 3
        elif self.rp_state == 3:
            self.rp[3] = byte
            self.rp_state = 4
        elif self.rp_state == 4:
            calc = self.rp[0] ^ self.rp[1] ^ self.rp[2] ^ self.rp[3]
            if byte == calc:
                self.silence = 0
                if self.rp[0] == SYNC_DATA:
                    addr = ((self.rp[1] & 0x7) << 8) | self.rp[2]
                    data = self.rp[3]
                    self.comm_ram[addr] = data
                    self.pending_apply.append((addr, data))
            self.rp_state = 0

    def step_tx(self, arm_full_sync):
        self.hb_cnt += 1
        if arm_full_sync:
            self.full_sync_active = True
            self.full_sync_ctr = 0

        if self.tp_state == 0:  # IDLE
            self.tx_is_fullsync = False
            if self.fifo:
                addr, data = self.fifo.pop(0)
                self.tp_bytes = [SYNC_DATA, (addr >> 8) & 0x7, addr & 0xFF, data]
                self.tp_state = 1
            elif self.full_sync_active:
                addr = self.full_sync_ctr
                data = self.comm_ram[addr]
                self.tp_bytes = [SYNC_DATA, (addr >> 8) & 0x7, addr & 0xFF, data]
                self.tx_is_fullsync = True
                self.tp_state = 1
            elif self.hb_cnt >= self.HEARTBEAT:
                self.tp_bytes = [SYNC_HB, 0, 0, self.cabinet_id]
                self.tp_state = 1
        elif self.tp_state in (1, 2, 3, 4):  # SYNC,AH,AL,D
            if not self.tx.busy and not self.tx.start_req:
                self.tx.send(self.tp_bytes[self.tp_state - 1])
                self.tp_state += 1
        elif self.tp_state == 5:  # CHK
            if not self.tx.busy and not self.tx.start_req:
                chk = self.tp_bytes[0] ^ self.tp_bytes[1] ^ self.tp_bytes[2] ^ self.tp_bytes[3]
                self.tx.send(chk)
                self.tp_state = 6
        elif self.tp_state == 6:  # WAIT
            if not self.tx.busy and not self.tx.start_req:
                self.hb_cnt = 0
                if self.tx_is_fullsync:
                    if self.full_sync_ctr == 2047:
                        self.full_sync_active = False
                        self.full_sync_ctr = 0
                    else:
                        self.full_sync_ctr += 1
                self.tp_state = 0

    def step(self, peer_line_in):
        # silence counter
        if self.silence < self.LINK_TIMEOUT:
            self.silence += 1
        # rx synchronizer (2 flops)
        self.rxd_sync = [self.rxd_sync[1], peer_line_in]
        self._rx_line(self.rxd_sync[1])
        # link-up edge -> arm full sync (master only)
        up_now = self.link_up
        arm = up_now and not self.was_up and self.master
        self.was_up = up_now
        self.step_tx(arm)
        # tx bit engine advances every cycle regardless of scheduler state
        line_out = self.tx.step()
        return line_out


def run(div=20, cycles=200000, seed=7, fifo_depth=32):
    random.seed(seed)
    A = Node(div, master=True, cabinet_id=0)
    B = Node(div, master=False, cabinet_id=1)
    lineA = lineB = 1

    writes = []  # (side, addr, data, cycle)
    for c in range(cycles):
        # occasional random writes from both sides
        if c > div * 20 and random.random() < 0.01:
            side = random.choice([A, B])
            addr = random.randint(0, 2047)
            data = random.randint(0, 255)
            side.cpu_write(addr, data)
            writes.append((side, addr, data, c))
        lineA_new = A.step(lineB)
        lineB_new = B.step(lineA)
        lineA, lineB = lineA_new, lineB_new

    return A, B, writes


if __name__ == "__main__":
    div = 12  # arbitrary bit-time divider; the state machines are div-agnostic

    print("=== Test 1: bidirectional dirty-byte propagation, moderate write rate ===")
    random.seed(11)
    A = Node(div=div, master=True, cabinet_id=0)
    B = Node(div=div, master=False, cabinet_id=1)
    lineA = lineB = 1
    writes = []
    WRITE_WINDOW, DRAIN = 60000, 200000
    for c in range(WRITE_WINDOW + DRAIN):
        if c < WRITE_WINDOW and c > div * 20 and random.random() < 0.001:
            side = random.choice([A, B])
            addr, data = random.randint(0, 2047), random.randint(0, 255)
            side.cpu_write(addr, data)
            writes.append((side, addr, data, c))
        lineA, lineB = A.step(lineB), B.step(lineA)
    last = {addr: data for _, addr, data, _ in writes}
    bad = [(a, d, A.comm_ram[a], B.comm_ram[a]) for a, d in last.items()
           if A.comm_ram[a] != d or B.comm_ram[a] != d]
    print(f"  {len(writes)} writes, {len(last)} distinct addresses, "
          f"{len(bad)} mismatched at end of run (0 expected)")

    print()
    print("=== Test 2: master full-sync sweep converges a late/blank peer ===")
    Am = Node(div=div, master=True, cabinet_id=2)
    Bs = Node(div=div, master=False, cabinet_id=0)
    random.seed(3)
    preload = {addr: random.randint(1, 255) for addr in random.sample(range(2048), 40)}
    for addr, data in preload.items():
        Am.comm_ram[addr] = data  # simulates writes made before Bs ever connected
    lineA = lineB = 1
    cycles = 2048 * (5 * 10 * div + 30) + 100000  # full 2048-byte sweep + margin
    for c in range(cycles):
        lineA, lineB = Am.step(lineB), Bs.step(lineA)
    mism = sum(1 for a in range(2048) if Am.comm_ram[a] != Bs.comm_ram[a])
    print(f"  {mism} of 2048 bytes mismatched after the sweep (0 expected)")

    print()
    print("=== Test 3: clean control + checksum-corruption rejection ===")
    random.seed(1)
    A3a = Node(div=div, master=True, cabinet_id=0)
    B3a = Node(div=div, master=False, cabinet_id=1)
    A3a.cpu_write(100, 0x42)
    lineA = lineB = 1
    for c in range(30000):
        lineA, lineB = A3a.step(lineB), B3a.step(lineA)
    print(f"  3a clean channel: B.comm_ram[100]={hex(B3a.comm_ram[100])} (expect 0x42)")

    random.seed(1)
    A3b = Node(div=div, master=True, cabinet_id=0)
    B3b = Node(div=div, master=False, cabinet_id=1)
    A3b.cpu_write(100, 0x42)
    lineA = lineB = 1
    for c in range(30000):
        lineA_new = A3b.step(lineB)
        if 30 <= c <= 30 + div:  # flip one bit period of the first packet
            lineA_new ^= 1
        lineB = B3b.step(lineA)
        lineA = lineA_new
    print(f"  3b corrupted first packet: B.comm_ram[100]={hex(B3b.comm_ram[100])} "
          f"(expect 0x0 -- dropped, not applied)")

    print()
    print("=== Test 4: FIFO overflow triggers a master resync that recovers ===")
    random.seed(9)
    div4 = 8
    A4 = Node(div=div4, master=True, cabinet_id=0, fifo_depth=8)  # tiny FIFO
    B4 = Node(div=div4, master=False, cabinet_id=1)
    lineA = lineB = 1
    burst = {addr: random.randint(1, 255) for addr in random.sample(range(2048), 30)}
    for addr, data in burst.items():
        A4.cpu_write(addr, data)  # far more than the 8-entry FIFO can hold at once
    cycles = 2048 * (5 * 10 * div4 + 30) + 200000
    for c in range(cycles):
        lineA, lineB = A4.step(lineB), B4.step(lineA)
    bad4 = [(a, d) for a, d in burst.items() if B4.comm_ram[a] != d]
    print(f"  {len(bad4)} of {len(burst)} burst-written bytes still wrong after "
          f"resync (0 expected)")

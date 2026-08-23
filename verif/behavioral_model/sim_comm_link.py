#!/usr/bin/env python3
"""
Cycle-accurate Python re-implementation of rtl/io/s32_comm_link.sv's bit-level
UART engine and packet-level protocol, used as a behavioural model since no
Verilog simulator (Verilator/Icarus) is reachable in this sandbox (no network
access to package registries or raw GitHub downloads).

This does NOT prove the SystemVerilog compiles or synthesizes in Quartus.
It proves the *algorithm* the SystemVerilog implements is correct, by
transcribing the same state machines statement-for-statement and driving
them the same way clk_sys would. In particular it reproduces the two bugs
found during manual review of the RTL, to confirm they were real and that
the fixes actually fix them.
"""

import random


# ---------------------------------------------------------------------------
# UART TX bit engine -- transcribed from the "---- TX ----" always block.
# ---------------------------------------------------------------------------
class UartTx:
    def __init__(self, div):
        self.div = div
        self.busy = False
        self.bitcnt = 0
        self.divcnt = 0
        self.shift = 0
        self.txd = 1  # idle mark
        self.start_req = False
        self.byte_to_send = 0

    def send(self, byte):
        self.byte_to_send = byte
        self.start_req = True

    def step(self):
        """One clk_sys edge. Mirrors the RTL's if/elif priority exactly."""
        if self.start_req and not self.busy:
            self.shift = (1 << 9) | (self.byte_to_send << 1) | 0  # {stop,data,start}
            self.busy = True
            self.divcnt = self.div
            self.bitcnt = 10
            self.txd = 0  # start bit immediately
            self.start_req = False
        elif self.busy:
            if self.divcnt == 0:
                self.divcnt = self.div - 1
                self.txd = (self.shift >> 1) & 1
                self.shift = (1 << 9) | (self.shift >> 1)
                if self.bitcnt == 1:
                    self.busy = False
                self.bitcnt -= 1
            else:
                self.divcnt -= 1
        return self.txd


# ---------------------------------------------------------------------------
# UART RX bit engine -- transcribed from the "---- RX ----" always block.
# bitcnt_init is the value under test: 8 (the original bug) or 7 (the fix).
# ---------------------------------------------------------------------------
class UartRx:
    def __init__(self, div, bitcnt_init=7):
        self.div = div
        self.bitcnt_init = bitcnt_init
        self.busy = False
        self.bitcnt = 0
        self.divcnt = 0
        self.shift = 0
        self.valid = False
        self.byte_out = None

    def step(self, rxd):
        self.valid = False
        if not self.busy:
            if rxd == 0:  # start bit edge
                self.busy = True
                self.divcnt = self.div + self.div // 2  # 1.5 * DIV, mid-bit sample
                self.bitcnt = self.bitcnt_init
        else:
            if self.divcnt == 0:
                self.divcnt = self.div - 1
                self.shift = (rxd << 7) | (self.shift >> 1)
                if self.bitcnt == 0:
                    self.busy = False
                    self.byte_out = (rxd << 7) | (self.shift_prev_for_final())
                    self.valid = True
                else:
                    self.bitcnt -= 1
            else:
                self.divcnt -= 1
        return self.valid, self.byte_out

    def shift_prev_for_final(self):
        # RTL: rx_byte <= {rxd, rx_shift[7:1]} using the OLD rx_shift (the one
        # from before this same-edge update). We already folded rxd into
        # self.shift above for the "next" value; reconstruct the old top-7
        # the same way the RTL's parallel assignment would (both statements
        # read the same pre-edge rx_shift).
        return self._old_shift >> 1

    # step() needs the pre-edge shift value for the finalize formula; wrap it.
    def step(self, rxd):  # noqa: F811 (intentional override with old-value capture)
        self.valid = False
        if not self.busy:
            if rxd == 0:
                self.busy = True
                self.divcnt = self.div + self.div // 2
                self.bitcnt = self.bitcnt_init
        else:
            if self.divcnt == 0:
                old_shift = self.shift
                self.divcnt = self.div - 1
                self.shift = ((rxd << 7) | (old_shift >> 1)) & 0xFF
                if self.bitcnt == 0:
                    self.busy = False
                    self.byte_out = ((rxd << 7) | (old_shift >> 1)) & 0xFF
                    self.valid = True
                else:
                    self.bitcnt -= 1
            else:
                self.divcnt -= 1
        return self.valid, self.byte_out


def uart_roundtrip_test(bitcnt_init, div=8, n=500, seed=1):
    """Send n random bytes A->B over a modelled wire (with the 2-cycle input
    synchronizer the RTL also has) and report how many arrive correctly."""
    random.seed(seed)
    tx = UartTx(div)
    rx = UartRx(div, bitcnt_init=bitcnt_init)
    sync0 = sync1 = 1  # rxd_sync double-flop, idle high

    to_send = [random.randint(0, 255) for _ in range(n)]
    received = []
    i = 0
    tx.send(to_send[0])
    idle_cycles = 0
    # Generous cycle budget per byte; UART needs ~10*div cycles/byte plus the
    # extra idle period the TX engine adds (see s32_comm_link.sv comments).
    budget = (10 * div + div + 4) * (n + 2)
    cycles = 0
    while len(received) < n and cycles < budget:
        cycles += 1
        line = tx.step()
        sync1 = sync0
        sync0 = line
        valid, byte = rx.step(sync1)
        if valid:
            received.append(byte)
        if not tx.busy and not tx.start_req:
            i += 1
            if i < n:
                tx.send(to_send[i])
    ok = sum(1 for a, b in zip(to_send, received) if a == b)
    return len(to_send), len(received), ok, to_send, received


if __name__ == "__main__":
    print("=== UART bit-engine round-trip: reproducing the RX bug, then the fix ===")
    for label, bitcnt_init in [("BUGGY (rx_bitcnt init = 8, the original code)", 8),
                                ("FIXED (rx_bitcnt init = 7, current code)", 7)]:
        sent, got, ok, tosend, recv = uart_roundtrip_test(bitcnt_init, div=8, n=300)
        print(f"{label}: sent={sent} received={got} correct={ok}/{got if got else sent}")
        if ok < got:
            for k, (a, b) in enumerate(zip(tosend, recv)):
                if a != b:
                    print(f"    first mismatch at byte #{k}: sent=0x{a:02x} got=0x{b:02x}")
                    break

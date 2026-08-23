# Comm-link behavioural model (NOT a Verilog simulation)

`sim_comm_link.py` and `sim_comm_link_full.py` are a Python, cycle-by-cycle
transcription of `rtl/io/s32_comm_link.sv`'s state machines (UART bit engine,
packet framing, dirty-byte FIFO, master full-sync sweep). They exist because
the session that wrote `s32_comm_link.sv` had no Verilator/Icarus available
(no network access to package registries or raw GitHub downloads in that
sandbox) and needed some way to check the design's logic beyond reading the
SystemVerilog by eye.

**What this proves:** the state machines, as transcribed, behave correctly
under the scenarios exercised below -- byte-level UART round trips (including
back-to-back bytes with no idle gap), bidirectional dirty-byte propagation
between two boards, the master's full-RAM sweep converging a blank/late peer,
a corrupted packet being dropped by the checksum instead of applied, and a
FIFO-overflow-triggered resync recovering full consistency.

**What this does NOT prove:** that `s32_comm_link.sv` itself compiles,
synthesizes, or behaves identically in real hardware. A hand transcription
can silently diverge from the actual Verilog (different operator precedence,
a signal width mismatch, a race the two languages resolve differently, etc).
Treat every earlier line as "this design should work"; only an actual
Verilator/Icarus run against the real `.sv` (see the project's own `verif/`
conventions) and a real two-board hardware test close that gap.

**History used to catch three bugs during development** (see
`PROFILE_CONTRACT.md`, 2026-08-23 comm-link entry, for the full narrative):

1. The RX bit counter started one sample too high, corrupting every
   received byte (found by hand, confirmed here).
2. `full_sync_active`/`full_sync_ctr` were written from two different
   `always` blocks -- an illegal multi-driver conflict (found by hand;
   this model can't catch synthesis-level issues, only logic ones).
3. The RX engine re-armed start-bit detection immediately after decoding a
   byte, before the actual stop bit had elapsed on the wire -- whenever the
   last data bit was 0, it would misread the tail of the SAME byte as a new
   start bit and corrupt every following byte. This one was NOT visible from
   reading the code; it only showed up once this model exercised
   back-to-back multi-byte transfers.

Run: `python3 sim_comm_link_full.py`

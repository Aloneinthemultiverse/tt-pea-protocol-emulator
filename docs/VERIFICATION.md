# PEA verification write-up

## Summary

| Layer | Tool | What it shows | Result |
|---|---|---|---|
| Lint | Verilator `-Wall`, Yosys `check -assert` | no multiple drivers, latches, width bugs | clean |
| Formal | SymbiYosys (Yosys + yices), k-induction | FIFO safety and data integrity; fetch arbiter fairness | **all proven** (unbounded) |
| Protocol simulation | Icarus Verilog, `test/tb_pea.sv` | every shipped program against an independent model of the other side | **65/65 checks** |
| Constrained random | same bench, fixed seed `0x5EA02027` | UART RX random bytes at random baud error; SPI random full-duplex bursts in all 4 modes; SPI target random bytes | included in the 46 |
| RTL + gate level | cocotb (`test/test.py`), Tiny Tapeout flow | host port, UART TX, UART RX on the RTL **and on the routed netlist** | pass |
| Physical | LibreLane, Tiny Tapeout precheck | GDS, DRC/LVS, 0 routing violations, 25 MHz timing in all corners | pass |

Everything runs in GitHub Actions on each push (`protocol_tb`, `formal`, `test`, `gds`), so results are reproducible
by anyone from the public repo.

## 1. Approach

The device is programmable, so "verification" has two halves:

1. **Hardware**: are the engine, FIFOs, arbiter and host port correct for *any* program?
   Small, reusable structures (FIFO, arbiter) are proven formally. The engine is exercised by many very different
   programs, which is a broad functional test of every opcode.
2. **Firmware**: does each protocol program produce a standards-correct waveform? Each is checked against a
   behavioural model of the *other* device, written independently from the firmware (a UART monitor, an SPI slave
   for all 4 modes, an I2C target with ACK/NACK and clock stretching, an IEEE 1149.1 TAP state machine, an SWD target,
   an NRZI/stuffing/CRC reference coder). The model is the oracle; it does not reuse firmware code.

## 2. Formal proofs (`formal/`, properties inside the RTL under `ifdef FORMAL`)

**FIFO (`pea_fifo`)**, with unconstrained push, pop and data:
- occupancy is always 0..4 (no overflow, no underflow);
- `full` ⇔ occupancy = 4, `empty` ⇔ occupancy = 0; an empty FIFO reads 0x00 (never stale storage);
- integrity: an arbitrary byte (`anyconst`) pushed at an arbitrary time is the next byte out after exactly the
  bytes in front of it: unchanged, in order. A cover trace confirms the scenario is reachable.

**Fetch arbiter (`pea_fetch_arb`)**, with unconstrained requests and program-write holds:
- work-conserving: a grant is issued whenever any engine requests;
- a grant only goes to a requester;
- starvation freedom: an engine that keeps requesting waits at most 3 other grants. An inductive strengthening
  (`waits + distance-to-pointer ≤ 3`) makes this an unbounded proof, not a bounded check.

Together these show that, for any program mix, no engine is starved of instructions and no FIFO corrupts data.

## 3. Protocol checks (`test/tb_pea.tmpl` → `test/tb_pea.sv`)

| Area | Checks |
|---|---|
| Host port | register write/read; flags appear on `uo_out` |
| UART | TX 0x55/0xA3 at 115200 by an independent monitor; RX loopback; RX from an external driver at nominal, +3 % and −3 % baud; FIFO empty after reads; **40 random bytes at random baud error** |
| SPI controller | mode 0 bytes each way, 16 clocks, SCK idle level; **48 random bytes each way**; **modes 1, 2, 3** with random bytes and idle-level checks |
| SPI target | external 1 MHz controller, **8 random bytes each way** over 4 transactions |
| I2C | write at **400 kHz** with ACK then NACK captured, clock stretching, STOP, bus released; read at **100 kHz**: address ACK, 3 bytes, master ACK/ACK/NACK, STOP |
| JTAG | walk of the TAP state machine: read IDCODE, IR scan loads BYPASS (captures `0001`), 8 bits through BYPASS with 1-bit delay, back in Run-Test/Idle |
| SWD | read transaction: request 0xA5, ACK OK, 32-bit data, parity, turnaround |
| Line coding | NRZI TX decoded by reference, 3 stuffed bits inserted, CRC-16 matches; NRZI RX destuffs, CRC-16 matches; TX-done flag |
| WS2812 | 2 LEDs (48 bits) decoded from pulse widths; every high time inside the datasheet window (T0H 250–550 ns, T1H 650–950 ns); line held low to latch |
| 1-Wire | 480 µs reset, presence detected; Read ROM (0x33) returns the 8-byte ROM of a device model; ROM CRC-8 verified |
| CAN 2.0A | two frames at 500 kbit/s to a receiver model that hard-syncs on SOF, destuffs, checks CRC-15 and drives ACK; engine sees the ACK; stuff bits present and all correct |
| Low-speed USB device | A USB host model runs a GET_DESCRIPTOR control transfer: SETUP + DATA0 → device ACK; IN → device DATA1 with 8 descriptor bytes. Checked: ACK and DATA1 received by the host, both within 7.5 bit times, the CRC-16 generated on chip is valid at the host (residual 0x800D), the device's receiver decoded the SETUP token and the setup bytes with residual 0x800D, no overruns. Three engines cooperate (receiver, handshake, data transmitter in program bank 1) through shared flags |
| Concurrency | UART TX → UART RX loopback, SPI and I2C running on **all four engines at once**, all correct, no overruns |
| Global | no FIFO overruns or IRQs where none are expected |

Random tests use a fixed seed, so every run is identical and failures can be replayed.

## 3a. Flexibility test: protocols the hardware was not designed for

The judging criterion is whether the chip can be reprogrammed for protocols it was not designed for. After the
hardware was frozen (GDS and precheck passing), three protocols were added **as firmware only**, with no RTL change,
each checked against an independent model of the other device:

| Protocol | Program size | What it needed | Hardware changes |
|---|---|---|---|
| WS2812 LEDs | 4 instructions | side-set + delays for sub-bit pulse widths | none |
| 1-Wire | 20 instructions | open-drain pin, loops for 480 µs reset, sample inside a 15 µs window | none |
| CAN 2.0A TX | 56 instructions | equal-bit run counter (`stuff_mode`) for 5-bit stuffing, CRC unit set to 15-bit poly 0x4599, wired-AND bus for ACK, every bit (incl. stuff bits) exactly 8 ticks | none |

CAN passed on the first simulation run. One finding was a test-timing bug, not a design bug (the 1-Wire test read the
FIFO a few µs before the 8th slot finished). Known gap: CAN arbitration loss and CAN receive are not written yet.

## 4. Gate level and physical

The cocotb tests run on the RTL and again on the post-route netlist produced by the Tiny Tapeout flow. The
hardening run reports 24.4 % utilization, 0 detailed-routing violations, and timing met at 25 MHz; precheck passes.

## 5. Bugs found and what caught them

| Bug | Caught by | Fix |
|---|---|---|
| Host read popped the RX FIFO twice | protocol sim (13/23 passing) | pop only after the byte has shifted out |
| Testbench SPI model counted the power-up X→1 edge | protocol sim | reset model counters after pin setup |
| Shared `integer` loop variable between clocked and combinational blocks → conflicting drivers in synthesis | GDS run failure | separate loop variables; `yosys check -assert` added before every push |
| Empty FIFO read returned X | cocotb | empty FIFO reads 0x00 (now also a formal property) |
| Setup violation at 50 MHz | STA in the flow | registered fetch, 25 MHz target |
| Detailed routing did not finish in 6 h (4 private 64:1 program muxes) | routing logs | shared round-robin fetch port: core 12.6k → 6.2k cells |
| Stale arbiter pointer assignment after refactor | protocol sim build | removed |
| Formal harness used hierarchical references unsupported by the flow | SymbiYosys | properties moved inside the modules under `ifdef FORMAL` |
| Assembler placed bank-1 code at base 64: label bit 6 spilled into the jump-condition field (`jmp y--` became `jmp pin`) | USB simulation, program-counter trace | bases are bank-relative; the assembler rejects bases outside 0–63 |
| USB data packet (PID + 8 bytes) one byte larger than the TX FIFO | USB simulation (transmitter stalled) | SYNC generated in code, PID held in the shift register |
| USB device answered so fast (~3 bit times) that its own receiver had not re-armed and mis-decoded the echo | USB simulation, flag trace | ~1.5 bit times of delay in spare delay slots (still inside the 7.5 bit-time limit) |

## 6. Limits

- The engine itself is verified by simulation, not formally (its state space is too large for a full proof here).
- Firmware is checked against behavioural models, not real devices; silicon has not been measured.
- Tick periods below ~5 clocks can see 1 clock of jitter when all four engines miss the instruction cache at once.
- USB: a control transfer's SETUP and IN data stages are shown at packet level against a host model; enumeration
  beyond that (status stage, SET_ADDRESS, NAK/STALL handling, data-toggle tracking, CRC5 checking of tokens) is
  left to the host MCU or not written. At 25 MHz the USB transmit tick is ~4 clocks, below the ~5-clock figure
  for fully jitter-free shared fetch (only 3 engines are active, so collisions are rare). 10 Mbit Ethernet is out
  of reach at 25 MHz.

## 7. AI use

The design was built with an AI assistant (Anthropic Claude, in Claude Code) driving the Auralis engineering workflow.
The AI wrote the architecture, RTL, assembler, firmware, testbench models, formal properties and these documents.
A human set goals and constraints, reviewed results and decided what to pursue. Correctness was never taken on the
AI's word: every claim above is backed by a check that runs in CI (lint, formal proof, simulation against
independent models, gate-level simulation, precheck). Several AI mistakes listed in §5 were caught that way.

## Reproduce

```
python test/gen_tb.py
iverilog -g2012 -o sim test/tb_pea.sv src/*.v && vvp sim      # 65 protocol checks
cd formal && sby -f fifo.sby && sby -f arb.sby                # formal proofs
cd test && make                                               # cocotb (RTL); GATES=yes for gate level
```

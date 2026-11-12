# PEA verification write-up

## Summary

| Layer | Tool | What it shows | Result |
|---|---|---|---|
| Lint | Verilator `-Wall`, Yosys `check -assert` | no multiple drivers, latches, width bugs | clean |
| Formal | SymbiYosys (Yosys + yices), k-induction | FIFO safety and data integrity; fetch arbiter fairness | **all proven** (unbounded) |
| Protocol simulation | Icarus Verilog, `test/tb_pea.sv` | every shipped program against an independent model of the other side | **46/46 checks** |
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
| Concurrency | UART TX → UART RX loopback, SPI and I2C running on **all four engines at once**, all correct, no overruns |
| Global | no FIFO overruns or IRQs where none are expected |

Random tests use a fixed seed, so every run is identical and failures can be replayed.

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

## 6. Limits

- The engine itself is verified by simulation, not formally (its state space is too large for a full proof here).
- Firmware is checked against behavioural models, not real devices; silicon has not been measured.
- Tick periods below ~5 clocks can see 1 clock of jitter when all four engines miss the instruction cache at once.
- No full USB stack yet; only its line-level primitives are verified. 10 Mbit Ethernet is out of reach at 25 MHz.

## 7. AI use

The design was built with an AI assistant (Anthropic Claude, in Claude Code) driving the Auralis engineering workflow.
The AI wrote the architecture, RTL, assembler, firmware, testbench models, formal properties and these documents.
A human set goals and constraints, reviewed results and decided what to pursue. Correctness was never taken on the
AI's word: every claim above is backed by a check that runs in CI (lint, formal proof, simulation against
independent models, gate-level simulation, precheck). Several AI mistakes listed in §5 were caught that way.

## Reproduce

```
python test/gen_tb.py
iverilog -g2012 -o sim test/tb_pea.sv src/*.v && vvp sim      # 46 protocol checks
cd formal && sby -f fifo.sby && sby -f arb.sby                # formal proofs
cd test && make                                               # cocotb (RTL); GATES=yes for gate level
```

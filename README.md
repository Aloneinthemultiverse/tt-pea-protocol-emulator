# PEA — Protocol Emulator ASIC (Auralis design)

Spec: an open-source, general-purpose protocol emulator for the Jane Street / Tiny Tapeout challenge. IHP sg13cmos5l 130 nm, 8x4 tiles. Protocols are firmware, not fixed logic: four small programmable engines read pins, write pins and hit timing exactly, so new protocols can be added after fabrication.

How it was made: designed with the Auralis workflow. RTL was linted (Verilator `-Wall`), simulated (Icarus) and synthesized (Yosys) on the Auralis semiconductor server's EDA image; Laya gave the PASS/FIX verdict.

## Architecture

```
 host SPI (ui_in) ──► registers ──► 64 x 16-bit program store (shared)
                         │                 │
                         ▼                 ▼
      4 x engine: PC, X, Y, ISR, OSR, 16.8 fractional tick divider, CRC/LFSR,
                  run-length counter, 4-deep TX and RX FIFOs
                         │
                         ▼
      8 protocol pins (uio, push-pull or open-drain) · 8 shared flags (6 on uo_out)
```

- **One instruction per tick, 16 bits:** `[15:13]` opcode, `[12:11]` side-set (none / toggle / low / high), `[10:9]` delay, `[8:0]` operand. Opcodes: JMP, WAIT, IN, OUT, PUSH/PULL, MOV, SET, ALU.
- **Host port:** SPI slave, mode 0. Byte 0 = `{write, addr[6:0]}`, then data bytes for that register. Loads programs, configures engines, reads/writes FIFOs.

## What is different from RP2040 PIO

| PIO limit | PEA |
|---|---|
| Divider phase is free-running | `WAIT ... resync` and `auto_resync` restart the tick divider on an edge: clock recovery for UART, USB, CAN |
| No line coding | NRZI encode/decode as an OUT destination / IN source, optionally on a differential pair |
| Bit stuffing costs many instructions | Run-length counter + `JMP stuff` branch (USB: 6 ones, CAN: 5 equal bits) |
| CRC must be done by the host | Programmable CRC/LFSR (width and polynomial) updated by shifted bits |
| Open-drain needs pindir tricks | Per-pin open-drain mode (I2C, 1-Wire) |
| Only `X--`/`Y--` | Small ALU (add, sub, xor, and, shift, swap) and `X != Y` branch |
| No trigger outputs | 8 shared flags, set/waited on by engines and the host, 6 visible on pins |

## Blocks and verification

| Block | File | What it does | Checks | Laya |
|---|---|---|---|---|
| Engine | `src/pea_engine.v` | Instruction execution, tick divider with resync, shifters, CRC, run counter, NRZI | exercised by all tests below | PASS (0.73) |
| Core | `src/pea_core.v` | 4 engines, program store, FIFOs, pins, flags, SPI host port | host register read/write, flags on pins: 2/2 | PASS (0.73) |
| UART firmware | `fw/programs.pea` `uart_tx`, `uart_rx` | 8N1 at 115200 baud; TX checked by an independent monitor; RX with loopback, external driver, ±3 % baud error | 7/7 | PASS (0.73) |
| SPI firmware | `spi_master` | Mode 0 full duplex, 2 instructions per bit, against a slave model | 3/3 | PASS (0.73) |
| I2C firmware | `i2c_master` | Open-drain master write, ACK and NACK capture, clock stretching, START/STOP, against a slave model | 4/4 | PASS (0.73) |
| Line coding | `nrzi_tx`, `nrzi_rx` | NRZI + bit stuffing + CRC-16 both directions against a reference coder | 7/7 | PASS (0.73) |
| **Top** | `src/tt_um_auralis_pea.v` | Tiny Tapeout wrapper | **23/23**, lint clean, synthesizes: 25,472 generic cells, 2,347 flip-flops | **PASS (0.73)** |

Run the full suite: `python test/gen_tb.py` builds `test/tb_pea.sv` (firmware embedded), then
`iverilog -g2012 -o sim test/tb_pea.sv src/*.v && vvp sim`.

## Register map (7-bit address)

| Addr | Register |
|---|---|
| `0x00` | engine enables `[3:0]` |
| `0x01` | IRQ flags `[3:0]`, FIFO overruns `[7:4]` (write 1 to clear) |
| `0x02` | shared flags |
| `0x03`, `0x04` | program address; program data (low byte, high byte, auto-increment) |
| `0x05` | pin inputs (read) |
| `0x06`, `0x07`, `0x08` | pin open-drain mask, pin direction, pin output |
| `0x10+16e+0..2` | engine `e` tick divider: fraction, low, high |
| `+3`, `+4`, `+5` | `{out_base, in_base}`, `{side_pin, set_base}`, `{set_count, jmp_pin}` |
| `+6`, `+7`, `+8` | wrap bottom, wrap top, `{out_threshold, in_threshold}` |
| `+9` | mode: in_right, out_right, autopush, autopull, auto_resync, resync_half, stuff_mode, diff |
| `+A`, `+B`, `+C` | `{crc_width-1, stuff_n}`, CRC polynomial low, high |
| `+D`, `+E`, `+F` | FIFO (write TX / read RX), FIFO status, PC (write = jump) |

## Silicon flow results (IHP sg13cmos5l, Tiny Tapeout flow, 8x4 tiles)

| Check | Result |
|---|---|
| GDS (LibreLane place-and-route) | passed |
| Gate-level simulation (cocotb on the routed netlist) | passed |
| Tiny Tapeout precheck | **passed** |
| Placement utilization | 24.4% of the 8x4 core area |
| Detailed routing | 0 violations |
| Clock | 25 MHz, setup and hold met in all corners |

How it got there: the first routable version used one 64:1 program-store read mux per engine and never finished detailed routing within 6 hours. One shared round-robin read port cut the core from 12,591 to 6,165 cells and the design from 25,699 to 19,341, and it then routed in about 2 hours.

## Limits (stated plainly)

- **Clock target is 25 MHz** for the first hardening pass. The four engines share one program-store read port (round-robin, fetch only when the PC changes). A tick waits for its instruction, so timing stays exact for tick periods of about 5 clocks or more; shorter periods can add a clock of jitter when fetches collide.

- **Not placed and routed.** The IHP area is an estimate: about 0.3 mm² of cells against about 1.0 mm² for 8x4 tiles. The Tiny Tapeout GDS flow has not been run yet.
- **Low-speed USB and CAN:** the line-coding primitives (NRZI, stuffing, CRC, resync) are verified, but no complete USB or CAN stack has been written or tested.
- **10 Mbit Ethernet is out of reach** for this version: the 4-byte FIFOs and the oversampled SPI host cannot carry 10 Mbit/s payloads.
- I2C firmware is master-write only; read is not written yet.
- Constrained-random tests cover UART RX (random bytes at random baud error) and SPI (random full-duplex bursts). No formal verification yet.

## AI use

Designed with AI assistance (Claude, driving the Auralis engineering workflow): architecture, RTL, assembler, firmware and tests were AI-written and checked by lint, simulation against independent protocol models, and synthesis.

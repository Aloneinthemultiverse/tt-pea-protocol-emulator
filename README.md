# PEA — Protocol Emulator ASIC (Auralis design)

Spec: an open-source, general-purpose protocol emulator for the Jane Street / Tiny Tapeout challenge. IHP sg13cmos5l 130 nm, 8x4 tiles. Protocols are firmware, not fixed logic: four small programmable engines read pins, write pins and hit timing exactly, so new protocols can be added after fabrication.

How it was made: designed with the Auralis workflow. RTL was linted (Verilator `-Wall`), simulated (Icarus) and synthesized (Yosys) on the Auralis semiconductor server's EDA image; Laya gave the PASS/FIX verdict.

## Documents

- [Architecture and instruction set](docs/ARCHITECTURE.md)
- [Verification write-up](docs/VERIFICATION.md) (includes AI use)
- [Host setup](docs/HOST.md)
- Assembler `fw/pea_asm.py`, example programs `fw/programs.pea`

**Protocols verified:** UART (any baud, ±3 %), SPI controller modes 0–3, SPI target, I2C write and read at 100/400 kHz with clock stretching, JTAG (full TAP), SWD read, USB-style NRZI + bit stuffing + CRC-16, and four protocols running concurrently. Added after the hardware was frozen, as firmware only: **WS2812 LEDs, 1-Wire, CAN 2.0A** (stuffing, CRC-15, ACK). **Low-speed USB device**: answers a host's GET_DESCRIPTOR (SETUP + IN stages) with on-chip NRZI, stuffing, SE0 and CRC-16, within USB turnaround time. Engine checked clock-by-clock against an independent ISA model on 1.2M random-instruction clocks (91/91 coverage bins, 10/10 planted bugs caught). 65/65 simulation checks, formal proofs of FIFO and fetch-arbiter correctness, gate-level test and precheck pass.

## Architecture

```
 host SPI (ui_in) ──► registers ──► 128 x 16-bit program store (2 banks, shared)
                         │                 │
                         ▼                 ▼
      4 x engine: PC, X, Y, ISR, OSR, 16.8 fractional tick divider, CRC/LFSR,
                  run-length counter, 8-deep TX and RX FIFOs
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

## Verification

See [docs/VERIFICATION.md](docs/VERIFICATION.md). Run: `python test/gen_tb.py && iverilog -g2012 -o sim test/tb_pea.sv src/*.v && vvp sim`; formal: `cd formal && sby -f fifo.sby && sby -f arb.sby`.

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

- Clock target 25 MHz. Shared instruction fetch keeps timing exact for tick periods of about 5 clocks or more.
- USB: SETUP and IN stages of a control transfer at packet level; the rest of enumeration is not written. CAN: transmit only.
- 10 Mbit Ethernet is out of reach at 25 MHz.
- The engine is verified by simulation; formal proofs cover the FIFOs and the fetch arbiter.
- Silicon has not been measured; all results are from simulation and the Tiny Tapeout flow.

## AI use

Built with an AI assistant (Anthropic Claude in Claude Code, driving the Auralis workflow). Details and how every claim was checked: [docs/VERIFICATION.md §7](docs/VERIFICATION.md#7-ai-use).

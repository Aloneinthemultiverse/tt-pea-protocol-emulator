# PEA architecture and instruction set

PEA (Protocol Emulator ASIC) is a small multi-engine I/O processor for IHP sg13cmos5l (Tiny Tapeout, 8x4 tiles, 25 MHz).
Protocols are firmware. Nothing protocol-specific is hard-wired except a few generic primitives that make
serial protocols cheap: divider resync (clock recovery), NRZI, a run-length counter (bit stuffing) and a programmable CRC.

## 1. Block diagram

```
 ui_in[0..2] host SPI ──► host port ──► register file ──► 64 x 16-bit program store
 uo_out[0]   MISO  ◄──┘                     │                   │ one read port
 uo_out[1]   IRQ                            │            round-robin fetch arbiter
                                            ▼                   ▼
        ┌────────────── engine 0..3 (identical) ─────────────────────────┐
        │ PC, X, Y (8 bit), ISR, OSR, cached instruction                 │
        │ 16.8 fractional tick divider, resync on edges                  │
        │ CRC/LFSR (width 1..16, any polynomial), run-length counter     │
        │ NRZI coder, 4-deep TX FIFO, 4-deep RX FIFO                     │
        └────────────────────────────────────────────────────────────────┘
                     │ pin out/dir requests (merged)        │ flags
                     ▼                                       ▼
        uio[7:0] 8 protocol pins (push-pull or open-drain)   8 shared flags (0..5 on uo_out[7:2])
```

### Engines
Each engine executes one 16-bit instruction per **tick**. The tick comes from a 16.8 fixed-point divider
(`div_int` + `div_frac/256` clocks, minimum 2), so baud rates are hit to <0.4 % without a matched crystal.
An instruction can add 0–3 delay ticks and drive one side-set pin in the same tick, so most bit loops
are 2 instructions per bit.

### Shared program store and fetch
The four engines share one 64x16 program store with a single read port. Each engine caches the instruction
at its current PC; when the PC changes, the engine raises `need` and the round-robin arbiter (`pea_fetch_arb`)
grants one engine per clock. A tick waits until its instruction is cached, so timing is exact whenever the tick
period is ≥ ~5 clocks (worst case: all four engines miss at once). The arbiter is formally proven to be
work-conserving and starvation-free (any requester is served within 3 other grants). Program writes invalidate
every cache. This sharing halved the core area and made the 8x4 layout route (4 private read muxes did not).

### Pins and flags
- 8 protocol pins on `uio`. Each pin has an output value, a direction and an open-drain bit. In open-drain mode
  the pin is only driven low, and releases (input + external pull-up) for a 1. This is how I2C SDA/SCL work.
- Engines address pins **relative** to configurable bases (`in_base`, `out_base`, `set_base`, `side_pin`)
  for IN/OUT/SET/side-set, and by **absolute** index for WAIT and `jmp pin`. The same program can therefore be
  moved to other pins by reconfiguration only.
- 8 shared flags: engines set/clear/wait on them (inter-engine handshakes, e.g. "TX done"); the host reads and
  writes them; flags 0–5 are on `uo_out[7:2]` as trigger outputs for a scope or another chip.

### FIFOs
Each engine has a 4-byte TX FIFO (host → engine) and a 4-byte RX FIFO (engine → host). Autopull/autopush move
whole bytes at programmable thresholds (1–8 bits). Overruns are latched in register `0x01[7:4]`.
Proven formally: no overflow/underflow, flags always agree with occupancy, data leaves unchanged and in order.

## 2. Instruction set

Format: `[15:13] opcode | [12:11] side-set | [10:9] delay | [8:0] operand`

- side-set: `0` none, `1` toggle, `2` drive low, `3` drive high (pin = `side_pin`); applied once, when the
  instruction first executes, even if it then stalls.
- delay: 0–3 extra ticks after the instruction.

| Op | Mnemonic | Operand | Meaning |
|---|---|---|---|
| 0 | `jmp [cond] label` | `[8:6]` cond, `[5:0]` target | cond: always, `!x`, `x--`, `!y`, `y--`, `pin` (jmp_pin high), `stuff` (run length ≥ stuff_n, then clears it), `x!=y`. `x--`/`y--` jump if non-zero, then decrement. |
| 1 | `wait pol src idx [resync]` | `[8]` polarity, `[7:6]` src, `[5:3]` index, `[2]` resync | src: `pin` (level), `edge` (transition to pol), `flag`, `anyedge`. `resync` restarts the tick divider on the event (clock recovery). |
| 2 | `in src n [discard]` | `[8:6]` src, `[5]` discard, `[3:0]` bits | src: pins, x, y, null, osr, nrzi (decoded line bit), crclo, crchi. n = 0 or ≥8 means 8. `discard` updates CRC/run counter without shifting into ISR. |
| 3 | `out dst n` | `[8:6]` dst, `[3:0]` bits | dst: pins, x, y, null, pindirs, nrzi (encoded on the line), pc. |
| 4 | `push`/`pull [iffull\|ifempty] [noblock]` | `[8]` pull, `[7]` if-condition, `[6]` block | Blocking by default. `noblock` push to a full FIFO drops and flags an overrun. |
| 5 | `mov dst src` / `mov dst ~src` / `mov dst ::src` / `nop` | `[8:6]` dst, `[5:4]` mode, `[2:0]` src | dst: pins, x, y, pindirs, pc, isr, osr, crc. src: pins, x, y, null, crclo, crchi, isr, osr. mode 1 = invert, 2 = bit-reverse. |
| 6 | `set dst v` | `[8:6]` dst, `[5:0]` value | dst: pins, x, y, pindirs (set_count pins from set_base), flag (`[3]` set/clear, `[2:0]` index), irq, nrzi (line state), ctl (`[0]` CRC on input bits, `[1]` CRC on output bits, `[2]` clear run counter). |
| 7 | `addx/addy/addxy/subxy/xorxy/andxy/shrx/swap [imm]` | `[8:6]` op, `[5:0]` immediate | Small ALU on X/Y. |

Wrap: after the instruction at `wrap_top` the PC continues at `wrap_bot`, at no cost, so loops need no `jmp`.

## 3. Per-engine configuration (host registers `0x10 + 16·e`)

| Offset | Field |
|---|---|
| 0, 1, 2 | divider fraction, integer low, integer high |
| 3 | `[2:0]` in_base, `[5:3]` out_base |
| 4 | `[2:0]` set_base, `[5:3]` side_pin |
| 5 | `[2:0]` jmp_pin, `[5:3]` set_count |
| 6, 7 | wrap bottom, wrap top |
| 8 | in threshold, out threshold |
| 9 | bit0 in_right, 1 out_right, 2 autopush, 3 autopull, 4 auto_resync, 5 resync_half, 6 stuff_mode, 7 diff (differential NRZI pair) |
| A | stuff_n, CRC width |
| B, C | CRC polynomial |
| D | FIFO: write = TX, read = RX |
| E | status `{wait, rx_empty, rx_full, tx_empty, tx_full}` |
| F | PC (write = jump; used as the entry point) |

Global registers: see the README register map.

## 4. Toolchain

`fw/pea_asm.py` assembles `.program` sections from `fw/programs.pea` (labels, `side 0|1|t`, `[delay]`, `;` comments)
into 16-bit words placed at any base address (`assemble(text, base)`). `test/gen_tb.py` embeds assembled programs
into the Verilog testbench; `test/test.py` (cocotb) assembles at run time. Shipped programs:

| Program | Words | Protocol |
|---|---|---|
| `uart_tx`, `uart_rx` | 5, 6 | UART 8N1, any baud; RX re-syncs on the start bit |
| `spi_master`, `spi_mode1/2/3` | 2, 5, 2, 5 | SPI controller, modes 0–3 |
| `spi_target` | 7 | SPI target (slave), mode 0 |
| `i2c_master`, `i2c_read` | 18, 33 | I2C controller write / read, ACK/NACK, clock stretching, 100–400 kHz |
| `jtag` | 5 | JTAG: host streams {TMS,TDI} pairs, full TAP control, TDO captured |
| `swd_read` | 21 | SWD read transaction with turnaround, ACK and parity |
| `nrzi_tx`, `nrzi_rx` | 22, 21 | USB-style NRZI + bit stuffing + CRC-16 |
| `ws2812` | 4 | WS2812 / NeoPixel LEDs, 800 kHz pulse-width coding |
| `onewire` | 20 | 1-Wire: reset/presence, read/write slots, Read ROM |
| `can_tx` | 56 | CAN 2.0A transmitter: bit stuffing, CRC-15, ACK slot, EOF, 500 kbit/s |

Adding a protocol = writing a `.program` section; no hardware change.

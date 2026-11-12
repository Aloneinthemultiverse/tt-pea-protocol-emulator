# Host setup (Tiny Tapeout demo board)

## Connections
| Chip pin | Function |
|---|---|
| `ui_in[0]` | host SPI SCLK |
| `ui_in[1]` | host SPI CSn |
| `ui_in[2]` | host SPI MOSI |
| `uo_out[0]` | host SPI MISO |
| `uo_out[1]` | IRQ (any engine `set irq`) |
| `uo_out[7:2]` | shared flags 0–5 (trigger outputs) |
| `uio[7:0]` | the 8 protocol pins (on a Pmod) |
| `clk` | 25 MHz from the RP2350 |
| `rst_n` | reset button or RP2350 GPIO |

The host is the demo board's RP2350 (MicroPython or C). Any SPI mode-0 master works; keep SCLK ≤ clk/8
(≈3 MHz at 25 MHz) because the port is oversampled.

## Frame format
CSn low, then byte 0 = `{write, addr[6:0]}`, then one or more data bytes to that address
(reads return data on the following bytes), CSn high.

## Bring-up sequence
1. Pulse `rst_n` low. Flops do not start at 0; reset is required. After the design is deselected and reselected
   on the board it loses power and state, so repeat from here.
2. Load the program: write `0x00` = 0 (stop engines), `0x03` = 0 (address), then a burst to `0x04`:
   low byte, high byte for each word (auto-increment).
3. Pins: `0x06` open-drain mask, `0x07` directions, `0x08` idle output levels.
4. For each engine: divider, pin bases, wrap, thresholds, mode, CRC (offsets 0–C), then entry PC (offset F).
5. Write enables to `0x00`.
6. Stream data through each engine's FIFO (offset D) and poll status (offset E) or use the IRQ pin.

The testbench task `esetup` and the cocotb `Host` class (`test/test.py`) are reference implementations of this
sequence.

## External parts
- I2C: pull-ups (e.g. 4.7 kΩ to 3.3 V) on SDA and SCL. Pins run open-drain.
- I/O is 3.3 V. Use level shifters or transceivers for other levels (RS-232, RS-485, CAN, USB differential).
- Approximate pad round trip ~10 ns, outputs to ~66 MHz (Tiny Tapeout estimates); the design runs far below this.

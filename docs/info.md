## How it works

PEA is a protocol emulator: four small programmable engines share a 64-instruction program store and eight protocol pins. Each engine runs one 16-bit instruction per tick of its own fractional divider. Instructions read pins, write pins, shift data to and from FIFOs, wait for edges and branch. Hardware helpers cover what is awkward in firmware: divider resync on an edge (clock recovery), NRZI coding, a bit-stuffing run counter, a programmable CRC and open-drain pins. A host loads programs and exchanges data over an SPI slave port. See README.md for the instruction set and register map.

## How to test

Drive SPI mode 0 on ui[0..2] and read MISO on uo[0]. Load a program from `fw/programs.pea` (assemble with `fw/pea_asm.py`), set the engine's divider, pins and wrap registers, write its PC and enable it. Example: `uart_tx` on engine 0 sends each byte written to the TX FIFO on protocol pin 0.

## External hardware

An SPI host (microcontroller or USB-SPI adapter). Pull-up resistors on pins used as open-drain (I2C).

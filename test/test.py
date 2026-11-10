# SPDX-License-Identifier: Apache-2.0
"""cocotb tests for the PEA protocol emulator: host port, UART transmit and UART receive.

The firmware is assembled from fw/programs.pea by fw/pea_asm.py. The same tests run on the
RTL and on the gate-level netlist. The wider protocol suite (SPI, I2C, NRZI + bit stuffing +
CRC against reference models) is in test/tb_pea.sv.
"""
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fw"))
import pea_asm  # noqa: E402

PROGS = pea_asm.programs(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fw", "programs.pea"))
BIT_CLOCKS = 434  # 115200 baud at 50 MHz: two ticks of 217 clocks


class Host:
    """SPI mode 0 host on ui_in[0]=SCLK, ui_in[1]=CSn, ui_in[2]=MOSI; MISO on uo_out[0]."""

    def __init__(self, dut):
        self.dut = dut
        self.ui = 0b010

    async def _set(self, sclk=None, csn=None, mosi=None):
        for bit, v in ((0, sclk), (1, csn), (2, mosi)):
            if v is not None:
                self.ui = (self.ui & ~(1 << bit)) | (v << bit)
        self.dut.ui_in.value = self.ui

    async def byte(self, d):
        q = 0
        for k in range(7, -1, -1):
            await self._set(mosi=(d >> k) & 1)
            await ClockCycles(self.dut.clk, 4)
            await self._set(sclk=1)
            q = (q << 1) | (int(self.dut.uo_out.value) & 1)
            await ClockCycles(self.dut.clk, 4)
            await self._set(sclk=0)
        return q

    async def frame(self, first, data):
        await self._set(csn=0)
        await ClockCycles(self.dut.clk, 4)
        await self.byte(first)
        out = [await self.byte(d) for d in data]
        await ClockCycles(self.dut.clk, 4)
        await self._set(csn=1)
        await ClockCycles(self.dut.clk, 8)
        return out

    async def wr(self, addr, d):
        await self.frame(0x80 | addr, [d])

    async def rd(self, addr):
        return (await self.frame(addr, [0]))[0]

    async def ecfg(self, e, reg, d):
        await self.wr(0x10 + 16 * e + reg, d)

    async def load(self, placed):
        """placed: list of (program name, base address). Loads all 64 words."""
        mem = [0] * 64
        for name, base in placed:
            words, _ = pea_asm.assemble(PROGS[name], base)
            mem[base:base + len(words)] = words
        await self.wr(0x00, 0)
        await self.wr(0x03, 0)
        data = []
        for w in mem:
            data += [w & 0xFF, w >> 8]
        await self.frame(0x84, data)

    async def setup(self, e, div, frac, p0, p1, p2, wrap_bot, wrap_top, mode, entry):
        for reg, v in ((0, frac), (1, div & 0xFF), (2, div >> 8), (3, p0), (4, p1), (5, p2),
                       (6, wrap_bot), (7, wrap_top), (8, 0), (9, mode), (15, entry)):
            await self.ecfg(e, reg, v)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0b010
    dut.uio_in.value = 0xFF
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    return Host(dut)


@cocotb.test()
async def test_host_port(dut):
    host = await start(dut)
    await host.wr(0x02, 0xA5)
    assert await host.rd(0x02) == 0xA5
    assert (int(dut.uo_out.value) >> 2) == 0b100101, "flags 0-5 appear on uo_out[7:2]"


@cocotb.test()
async def test_uart_tx(dut):
    host = await start(dut)
    await host.load([("uart_tx", 0)])
    await host.wr(0x07, 0x01)                       # pin 0 is an output
    await host.setup(0, 217, 3, 0x00, 0x00, 0x00, 0, 4, 0x02, 0)
    await host.wr(0x00, 0x01)
    for sent in (0x55, 0xA3):
        await host.ecfg(0, 13, sent)                # TX FIFO
        for _ in range(4000):                       # wait for the start bit
            await ClockCycles(dut.clk, 1)
            if (int(dut.uio_out.value) & 1) == 0:
                break
        await ClockCycles(dut.clk, BIT_CLOCKS + BIT_CLOCKS // 2)
        got = 0
        for k in range(8):
            got |= (int(dut.uio_out.value) & 1) << k
            await ClockCycles(dut.clk, BIT_CLOCKS)
        assert (int(dut.uio_out.value) & 1) == 1, "stop bit"
        assert got == sent, f"UART TX sent {sent:#x}, line carried {got:#x}"


@cocotb.test()
async def test_uart_rx(dut):
    host = await start(dut)
    await host.load([("uart_rx", 8)])
    await host.setup(1, 217, 3, 0x01, 0x00, 0x00, 0, 63, 0x01, 8)
    await host.wr(0x00, 0x02)
    for sent in (0x3C, 0xE1):
        bits = [0] + [(sent >> k) & 1 for k in range(8)] + [1, 1]
        for b in bits:
            dut.uio_in.value = 0xFD | (b << 1)      # pin 1 is RX
            await ClockCycles(dut.clk, BIT_CLOCKS)
        assert await host.rd(0x10 + 16 + 13) == sent
    assert (await host.rd(0x10 + 16 + 14)) & 0x08, "RX FIFO empty after reads"

#!/usr/bin/env python3
"""Draw one waveform PNG per protocol from waves.txt (written by tb_pea.sv) into docs/waveforms/.
Each picture starts at the first edge of the section's clock/data pin and spans its first N edges."""
import os
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# section marker -> (title, [(pin, label)], pin whose edges set the window, number of edges, file)
VIEWS = {
    'UART': ('UART 115200 baud: engine 0 TX looped into engine 1 RX', [(0, 'TX'), (1, 'RX')], 0, 24, 'uart'),
    'SPI master': ('SPI controller, mode 0', [(2, 'SCK'), (3, 'MOSI'), (4, 'MISO')], 2, 34, 'spi'),
    'I2C master': ('I2C controller 400 kHz: START, address, ACK', [(6, 'SCL'), (5, 'SDA')], 6, 37, 'i2c'),
    'NRZI + bit stuffing + CR': ('NRZI + bit stuffing + CRC-16 frame', [(7, 'LINE')], 7, 60, 'nrzi'),
    'JTAG': ('JTAG: TAP walk and shift', [(0, 'TCK'), (2, 'TMS'), (1, 'TDI'), (4, 'TDO')], 0, 40, 'jtag'),
    'SWD read': ('SWD read: request, turnaround, ACK, data', [(0, 'SWCLK'), (1, 'SWDIO')], 0, 60, 'swd'),
    'concurrency': ('Engines running at once: UART TX -> RX loopback, SPI and I2C in the same 100 µs',
                    [(0, 'UART TX'), (1, 'UART RX'), (2, 'SCK'), (3, 'MOSI'), (6, 'SCL'), (5, 'SDA')], 6, 0,
                    'concurrency', {'span': 100000}),
    'SPI target': ('SPI target: external controller drives SCK, CSn, MOSI', [(1, 'CSn'), (0, 'SCK'), (2, 'MOSI'),
                   (3, 'MISO')], 0, 34, 'spi_target'),
    'WS2812': ('WS2812 LEDs: 800 kHz pulse-width code', [(0, 'DIN')], 0, 40, 'ws2812'),
    '1-Wire': ('1-Wire: reset, presence, Read ROM', [(5, 'DQ')], 5, 24, 'onewire'),
    'CAN 2.0A': ('CAN 2.0A 500 kbit/s frame (bus = TX wired-AND receiver ACK)', [(0, 'TX'), (1, 'BUS')], 0, 70, 'can'),
    'Low-speed USB device': ('Low-speed USB: host SETUP + DATA0, device ACK, host IN, device DATA1',
                             [(6, 'D-'), (7, 'D+')], 6, 400, 'usb'),
}
EXTRA = {   # zoomed views: window around the k-th SE0 (end of packet) of the section
    'Low-speed USB device': [
        ('USB zoom: host DATA0 ends (SE0), the chip answers ACK within the 7.5-bit turnaround',
         [(6, 'D-'), (7, 'D+')], 'usb_ack', {'dev': 0, 'before': 12000, 'after': 16000}),
        ('USB zoom: host IN token, then the chip sends DATA1 + 8 bytes + on-chip CRC-16',
         [(6, 'D-'), (7, 'D+')], 'usb_data1', {'dev': 1, 'before': 22000, 'after': 72000}),
    ],
}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else 'waves.txt'
    out = sys.argv[2] if len(sys.argv) > 2 else 'docs/waveforms'
    os.makedirs(out, exist_ok=True)
    marks, ev = [], []
    for ln in open(src):
        t = ln.split()
        if not t:
            continue
        if t[0] == 'M':
            marks.append((int(t[1]), ' '.join(t[2:])))
        else:
            try:
                e = (int(t[0]), int(t[1], 16), int(t[2], 16))
            except ValueError:          # X/Z before reset
                continue
            if ev and ev[-1][0] == e[0]:
                ev[-1] = e              # same timestamp: keep the settled value
            else:
                ev.append(e)
    made = 0
    for i, (t0, name) in enumerate(marks):
        if name not in VIEWS:
            continue
        views = [VIEWS[name]] + [(x[0], x[1], 6, 0, x[2], x[3]) for x in EXTRA.get(name, [])]
        for view in views:
            made += draw(view, t0, marks[i + 1][0] if i + 1 < len(marks) else ev[-1][0], ev, out, name)
    total = len(VIEWS) + sum(len(v) for v in EXTRA.values())
    print(f'{made}/{total} waveform pictures')
    sys.exit(0 if made == total else 1)


def draw(view, t0, t_end, ev, out, name):
    if True:
        title, pins, cpin, nedge, fname = view[:5]
        opt = view[5] if len(view) > 5 else {}
        sec = [e for e in ev if t0 <= e[0] < t_end]
        prev = [v for (tt, v, _) in ev if tt < t0]
        v0 = prev[-1] if prev else 0
        edges, last = [], (v0 >> cpin) & 1
        for tt, v, _ in sec:
            b = (v >> cpin) & 1
            if b != last:
                edges.append(tt)
                last = b
        if len(edges) < 2:
            print(f'{name}: no activity on pin {cpin}')
            return 0
        if 'dev' in opt:                        # k-th packet driven by the chip (uio_oe[6] rises)
            st = [tt for k, (tt, v, oe) in enumerate(sec) if k and (oe >> 6) & 1 and not (sec[k - 1][2] >> 6) & 1]
            if len(st) <= opt['dev']:
                print(f'{fname}: only {len(st)} chip-driven packets')
                return 0
            a, b = st[opt['dev']] - opt['before'], st[opt['dev']] + opt['after']
        elif 'span' in opt:
            a, b = edges[0] - opt['span'] * 0.02, edges[0] + opt['span']
        else:
            span = edges[min(nedge, len(edges) - 1)] - edges[0]
            a, b = edges[0] - span * 0.05, edges[min(nedge, len(edges) - 1)] + span * 0.05
        us = (b - a) >= 20000
        sc, unit = (1e-3, 'µs') if us else (1.0, 'ns')
        fig, ax = plt.subplots(figsize=(12, 0.75 * len(pins) + 1.2))
        for row, (pin, label) in enumerate(pins):
            y0 = (len(pins) - 1 - row) * 1.5
            xs, ys, cur = [a], [], v0
            for tt, v, _ in ev:
                if tt <= a:
                    cur = v
            ys.append((cur >> pin) & 1)
            for tt, v, _ in sec:
                if a < tt < b:
                    xs += [tt, tt]
                    ys += [ys[-1], (v >> pin) & 1]
            xs.append(b)
            ys.append(ys[-1])
            ax.plot([x * sc for x in xs], [y0 + y for y in ys], lw=1.4, color='#1f5fa8')
            ax.text(a * sc, y0 + 0.5, label + '  ', ha='right', va='center', fontsize=10)
        if fname.startswith('usb'):             # shade where the chip drives the bus
            s0 = None
            pts = [e for e in sec if a < e[0] < b]
            oe0 = [oe for (tt, v, oe) in ev if tt <= a]
            cur = oe0[-1] if oe0 else 0
            if (cur >> 6) & 1: s0 = a
            for tt, v, oe in pts + [(b, 0, 0)]:
                on = (oe >> 6) & 1
                if on and s0 is None: s0 = tt
                if not on and s0 is not None:
                    ax.axvspan(s0 * sc, tt * sc, color='#f2b134', alpha=0.3, lw=0)
                    s0 = None
            ax.set_title('shaded: driven by the chip, unshaded: host model', loc='right', fontsize=8,
                         color='#a06d00')
        ax.set_yticks([])
        ax.set_xlim(a * sc, b * sc)
        ax.set_xlabel(f'simulation time ({unit}), RTL simulation, Icarus Verilog')
        ax.set_title(title, fontsize=11, loc='left')
        for s in ('top', 'right', 'left'):
            ax.spines[s].set_visible(False)
        fig.tight_layout()
        fig.savefig(os.path.join(out, fname + '.png'), dpi=110)
        plt.close(fig)
        print(f'{name}: {fname}.png')
        return 1


if __name__ == '__main__':
    main()

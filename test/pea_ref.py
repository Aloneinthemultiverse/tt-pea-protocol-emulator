#!/usr/bin/env python3
"""Independent ISA reference model of one PEA engine, written from docs/ARCHITECTURE.md.

Replays engine_trace.txt (from tb_engine_rand.sv): for every clock it feeds the logged inputs to the
model, and checks that the model's outputs and architectural state equal the RTL's. Also measures
functional coverage (every opcode/sub-op, both outcomes of every branch, stalls, waits, autopush/pull,
overrun, side-set kinds, divider resync) and fails if any bin is never hit.
Usage: python3 test/pea_ref.py [engine_trace.txt]
"""
import sys
from collections import Counter

M8, M16 = 0xFF, 0xFFFF


def rotl(v, s):
    return ((v << s) | (v >> (8 - s))) & M8 if s else v & M8


def rotr(v, s):
    return ((v >> s) | (v << (8 - s))) & M8 if s else v & M8


def brev(v):
    return int(f'{v:08b}'[::-1], 2)


def bit(v, i):
    return (v >> i) & 1


STATE = ['dly', 'fresh', 'x', 'y', 'isr', 'osr', 'isr_cnt', 'osr_cnt', 'crc', 'crc_in', 'crc_out',
         'run', 'last_s', 'last_b', 'dcnt', 'facc']
OUTS = ['pc', 'pout_mask', 'pout_val', 'pdir_mask', 'pdir_val', 'flag_set', 'flag_clr', 'irq', 'tx_pop',
        'rx_push', 'rx_data', 'overrun', 'waiting']


class Engine:
    def __init__(self, cfg):
        self.c = cfg
        self.s = dict(pc=0, dly=0, fresh=1, waiting=0, x=0, y=0, isr=0, osr=0, isr_cnt=0, osr_cnt=8,
                      crc=0, crc_in=0, crc_out=0, run=0, last_s=1, last_b=0, dcnt=0, facc=0)

    def step(self, ir, pins, prev, pout, flags, tx_data, tx_empty, rx_full, cov):
        c, s = self.c, self.s
        n_ = dict(s)
        o = dict(pc=s['pc'], pout_mask=0, pout_val=0, pdir_mask=0, pdir_val=0, flag_set=0, flag_clr=0,
                 irq=0, tx_pop=0, rx_push=0, rx_data=0, overrun=0, waiting=s['waiting'])
        op, side, dl, a = ir >> 13, (ir >> 11) & 3, (ir >> 9) & 3, ir & 0x1FF
        sub = a >> 6
        n = 8 if (a & 0xF) == 0 or (a & 8) else a & 0xF
        nmask = M8 >> (8 - n)
        ithr = 8 if c['in_thr'] in (0,) or c['in_thr'] > 8 else c['in_thr']
        othr = 8 if c['out_thr'] in (0,) or c['out_thr'] > 8 else c['out_thr']
        div_eff = max(c['div_int'], 2)
        tick = s['dcnt'] == 0
        exe = tick and s['dly'] == 0 and not s['waiting']
        resync = done = stall = jt = bit_valid = crc_upd = False
        bitv = data = 0
        pin_in0 = bit(pins, c['in_base'])
        if tick and s['dly']:
            n_['dly'] = s['dly'] - 1

        wp = (a >> 3) & 7
        wtype = (a >> 6) & 3
        pol = a >> 8
        if wtype == 0:
            wc = bit(pins, wp) == pol
        elif wtype == 1:
            wc = bit(pins, wp) == pol and bit(prev, wp) != pol
        elif wtype == 2:
            wc = bit(flags, wp) == pol
        else:
            wc = bit(pins, wp) != bit(prev, wp)

        if (exe or s['waiting']) and op == 1:
            if wc:
                done, n_['waiting'], resync = True, 0, bool(a & 4)
                cov[f'wait{wtype} done' + (' after waiting' if s['waiting'] else ' at once')] += 1
            else:
                n_['waiting'] = 1
        elif exe:
            done = True
            cov[f'op{op} sub{sub}'] += 1
            if op == 0:
                x, y = s['x'], s['y']
                if sub == 0: jt = True
                elif sub == 1: jt = x == 0
                elif sub == 2: jt, n_['x'] = x != 0, (x - 1) & M8
                elif sub == 3: jt = y == 0
                elif sub == 4: jt, n_['y'] = y != 0, (y - 1) & M8
                elif sub == 5:
                    jp = c['jmp_pin']
                    jt = (bit(pins, jp) == 0 and bit(pins, (jp + 1) & 7) == 0) if c['diff'] else bool(bit(pins, jp))
                elif sub == 6:
                    jt = s['run'] >= c['stuff_n']
                    if jt: n_['run'] = 0
                else: jt = x != y
                cov[f'jmp{sub} ' + ('taken' if jt else 'not taken')] += 1
            elif op == 2:
                srcs = [rotr(pins, c['in_base']), s['x'], s['y'], 0, s['osr'], None, s['crc'] & M8, s['crc'] >> 8]
                if sub == 5:
                    src = 1 ^ (pin_in0 ^ s['last_s'])
                    n_['last_s'] = pin_in0
                else:
                    src = srcs[sub]
                data = src & nmask
                bitv = data & 1
                if a & 0x20:
                    n_['run'] = 0
                    cov['in discard'] += 1
                else:
                    bit_valid = n == 1
                    crc_upd = bool(s['crc_in']) and n == 1
                    isr = s['isr']
                    n_['isr'] = (((isr >> n) | (data << (8 - n))) if c['in_right'] else ((isr << n) | data)) & M8
                    cnt = s['isr_cnt'] + n
                    n_['isr_cnt'] = min(cnt, 8)
                    if c['autopush'] and cnt >= ithr:
                        o['rx_data'] = n_['isr']
                        o['rx_push'], o['overrun'] = int(not rx_full), int(rx_full)
                        n_['isr'], n_['isr_cnt'] = 0, 0
                        cov['autopush' + (' overrun' if rx_full else '')] += 1
            elif op == 3:
                osr, ocnt = s['osr'], s['osr_cnt']
                if ocnt >= othr and c['autopull']:
                    if tx_empty:
                        stall = True
                        cov['out autopull stall'] += 1
                    else:
                        osr, ocnt, o['tx_pop'] = tx_data, 0, 1
                        cov['out autopull'] += 1
                if not stall:
                    data = (osr & nmask) if c['out_right'] else (osr >> (8 - n))
                    n_['osr'] = (osr >> n) if c['out_right'] else ((osr << n) & M8)
                    n_['osr_cnt'] = min(ocnt + n, 8)
                    bitv = data & 1
                    ob = c['out_base']
                    if sub == 0:
                        o['pout_mask'], o['pout_val'] = rotl(nmask, ob), rotl(data, ob)
                        bit_valid = n == 1
                    elif sub == 1: n_['x'] = data
                    elif sub == 2: n_['y'] = data
                    elif sub == 4:
                        o['pdir_mask'], o['pdir_val'] = rotl(nmask, ob), rotl(data, ob)
                    elif sub == 5:
                        nrz = bit(pout, ob) ^ (1 - (data & 1))
                        o['pout_mask'] = rotl(3 if c['diff'] else 1, ob)
                        o['pout_val'] = rotl(((1 - nrz) << 1) | nrz, ob)
                        bit_valid = True
                    elif sub == 6:
                        jt = True
                    crc_upd = bool(s['crc_out']) and n == 1
            elif op == 4:
                if not (a & 0x100):  # PUSH
                    if not (a & 0x80) or s['isr_cnt'] >= ithr:
                        if rx_full and (a & 0x40):
                            stall = True
                            cov['push stall'] += 1
                        else:
                            o['rx_data'], o['rx_push'], o['overrun'] = s['isr'], int(not rx_full), int(rx_full)
                            n_['isr'], n_['isr_cnt'] = 0, 0
                            cov['push' + (' overrun' if rx_full else '')] += 1
                else:  # PULL
                    if not (a & 0x80) or s['osr_cnt'] >= othr:
                        if tx_empty:
                            if a & 0x40:
                                stall = True
                                cov['pull stall'] += 1
                            else:
                                n_['osr'], n_['osr_cnt'] = s['x'], 0
                                cov['pull empty -> x'] += 1
                        else:
                            n_['osr'], n_['osr_cnt'], o['tx_pop'] = tx_data, 0, 1
                            cov['pull'] += 1
            elif op == 5:
                src = [rotr(pins, c['in_base']), s['x'], s['y'], 0, s['crc'] & M8, s['crc'] >> 8,
                       s['isr'], s['osr']][a & 7]
                mo = (a >> 4) & 3
                data = (~src & M8) if mo == 1 else brev(src) if mo == 2 else src
                ob = c['out_base']
                if sub == 0: o['pout_mask'], o['pout_val'] = M8, rotl(data, ob)
                elif sub == 1: n_['x'] = data
                elif sub == 2: n_['y'] = data
                elif sub == 3: o['pdir_mask'], o['pdir_val'] = M8, rotl(data, ob)
                elif sub == 4: jt = True
                elif sub == 5: n_['isr'], n_['isr_cnt'] = data, 0
                elif sub == 6: n_['osr'], n_['osr_cnt'] = data, 0
                else: n_['crc'] = (data << 8) | data
            elif op == 6:
                v6 = a & 0x3F
                cm = M8 >> (8 - c['set_cnt'])
                if sub == 0: o['pout_mask'], o['pout_val'] = rotl(cm, c['set_base']), rotl(v6, c['set_base'])
                elif sub == 1: n_['x'] = v6
                elif sub == 2: n_['y'] = v6
                elif sub == 3: o['pdir_mask'], o['pdir_val'] = rotl(cm, c['set_base']), rotl(v6, c['set_base'])
                elif sub == 4:
                    if a & 8: o['flag_set'] = 1 << (a & 7)
                    else: o['flag_clr'] = 1 << (a & 7)
                elif sub == 5: o['irq'] = 1
                elif sub == 6:
                    ob = c['out_base']
                    nrz = bit(pout, ob) ^ (1 - (a & 1))
                    o['pout_mask'] = rotl(3 if c['diff'] else 1, ob)
                    o['pout_val'] = rotl(((1 - nrz) << 1) | nrz, ob)
                    n_['run'] = 0
                else:
                    n_['crc_in'], n_['crc_out'] = a & 1, (a >> 1) & 1
                    if a & 4: n_['run'] = 0
            else:
                x, y = s['x'], s['y']
                imm = (a & 0x3F) | (0xC0 if a & 0x20 else 0)
                if sub == 0: n_['x'] = (x + imm) & M8
                elif sub == 1: n_['y'] = (y + imm) & M8
                elif sub == 2: n_['x'] = (x + y) & M8
                elif sub == 3: n_['x'] = (x - y) & M8
                elif sub == 4: n_['x'] = x ^ y
                elif sub == 5: n_['x'] = x & y
                elif sub == 6: n_['x'] = x >> 1
                else: n_['x'], n_['y'] = y, x
            if stall:
                done = bit_valid = crc_upd = jt = False
                for k in ('x', 'y', 'isr', 'osr', 'isr_cnt', 'osr_cnt', 'run', 'last_s'):
                    n_[k] = s[k]

        if bit_valid:
            if not c['stuff_mode']:
                n_['run'] = min(s['run'] + 1, 7) if bitv else 0
            else:
                n_['run'] = min(s['run'] + 1, 7) if bitv == s['last_b'] else 1
                n_['last_b'] = bitv
        if crc_upd:
            fb = bit(s['crc'], c['crc_w']) ^ bitv
            n_['crc'] = ((s['crc'] << 1) & M16) ^ (c['crc_poly'] if fb else 0)
            cov['crc step'] += 1

        if exe and s['fresh'] and side:
            sp = 1 << c['side_pin']
            o['pout_mask'] |= sp
            v = (~pout & sp) if side == 1 else (sp if side & 1 else 0)
            o['pout_val'] = (o['pout_val'] & ~sp & M8) | v
            cov[f'side-set {side}'] += 1
        if exe:
            n_['fresh'] = 0
        if done:
            n_['fresh'] = 1
            n_['dly'] = dl
            if dl: cov['delay'] += 1
            if not jt:
                n_['pc'] = c['wrap_bot'] if s['pc'] == c['wrap_top'] else (s['pc'] + 1) & 63
                if s['pc'] == c['wrap_top']: cov['wrap'] += 1
            elif op == 0:
                n_['pc'] = a & 63
            else:
                n_['pc'] = data & 63
                cov['computed jump'] += 1
        if c['auto_resync'] and pin_in0 != bit(prev, c['in_base']):
            resync = True
        if resync:
            n_['dcnt'] = (div_eff >> 1) if c['resync_half'] else div_eff - 1
            cov['resync'] += 1
        elif tick:
            fs = s['facc'] + c['div_frac']
            n_['facc'] = fs & M8
            n_['dcnt'] = div_eff - 1 + (fs >> 8)
        else:
            n_['dcnt'] = s['dcnt'] - 1
        self.s = n_
        return o


CFG = ['div_int', 'div_frac', 'in_base', 'out_base', 'set_base', 'set_cnt', 'side_pin', 'jmp_pin', 'stuff_n',
       'wrap_bot', 'wrap_top', 'in_thr', 'out_thr', 'crc_w', 'in_right', 'out_right', 'autopush', 'autopull',
       'auto_resync', 'resync_half', 'stuff_mode', 'diff', 'crc_poly', 'pad']


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'engine_trace.txt'
    cov, eng, runs, clocks, fails, bad_run = Counter(), None, 0, 0, 0, False
    for ln in open(path):
        t = ln.split()
        if not t:
            continue
        if t[0] == 'R':
            cfg = dict(zip(CFG, (int(v, 16) for v in t[2:])))
            eng, runs, bad_run, run_id = Engine(cfg), runs + 1, False, t[1]
            continue
        if t[0] != 'C' or bad_run:
            continue
        v = [int(x, 16) for x in t[1:]]
        inp, rtl_o, rtl_s = v[0:8], dict(zip(OUTS, v[8:21])), dict(zip(STATE, v[21:37]))
        clocks += 1
        pre = dict(eng.s)
        o = eng.step(*inp, cov)
        mism = [(k, rtl_s[k], pre[k]) for k in STATE if pre[k] != rtl_s[k]]
        mism += [(k, rtl_o[k], o[k]) for k in OUTS if o[k] != rtl_o[k]]
        if mism:
            fails += 1
            bad_run = True
            if fails <= 5:
                print(f'MISMATCH run {run_id} clock {clocks}: ir={inp[0]:04x} pc={pre["pc"]} '
                      + ', '.join(f'{k}: rtl={r:x} model={m:x}' for k, r, m in mism))
    need = [f'op{op} sub{sub}' for op in (0, 2, 3, 5, 6, 7) for sub in range(8)]
    need += [f'jmp{j} {w}' for j in range(8) for w in ('taken', 'not taken') if not (j == 0 and w == 'not taken')]
    need += [f'wait{w} done {h}' for w in range(4) for h in ('at once', 'after waiting')]
    need += ['push', 'push overrun', 'push stall', 'pull', 'pull stall', 'pull empty -> x', 'autopush',
             'autopush overrun', 'out autopull', 'out autopull stall', 'in discard', 'crc step', 'side-set 1',
             'side-set 2', 'side-set 3', 'delay', 'wrap', 'computed jump', 'resync']
    holes = [b for b in need if cov[b] == 0]
    print(f'engine vs ISA model: {runs} random programs, {clocks} clocks compared, {fails} mismatching runs')
    print(f'coverage: {len(need) - len(holes)}/{len(need)} bins hit; least-hit bins:',
          ', '.join(f'{b}={cov[b]}' for b in sorted(need, key=lambda b: cov[b])[:6]))
    if holes:
        print('COVERAGE HOLES:', holes)
    if fails or holes or runs == 0:
        print('FAIL')
        sys.exit(1)
    print('PASS')


if __name__ == '__main__':
    main()

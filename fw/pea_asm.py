"""PEA assembler.

    python pea_asm.py programs.pea            # list programs and their words
A source file holds programs introduced by `.program name`. Syntax: `label:`, `;` comments,
suffixes `side 0|1|t` and `[delay]` (0-3). Labels resolve to base + offset.
"""
import re
import sys

JC = {'': 0, '!x': 1, 'x--': 2, '!y': 3, 'y--': 4, 'pin': 5, 'stuff': 6, 'x!=y': 7}
INS = {'pins': 0, 'x': 1, 'y': 2, 'null': 3, 'osr': 4, 'nrzi': 5, 'crclo': 6, 'crchi': 7}
OUTD = {'pins': 0, 'x': 1, 'y': 2, 'null': 3, 'pindirs': 4, 'nrzi': 5, 'pc': 6}
MOVD = {'pins': 0, 'x': 1, 'y': 2, 'pindirs': 3, 'pc': 4, 'isr': 5, 'osr': 6, 'crc': 7}
MOVS = {'pins': 0, 'x': 1, 'y': 2, 'null': 3, 'crclo': 4, 'crchi': 5, 'isr': 6, 'osr': 7}
SETD = {'pins': 0, 'x': 1, 'y': 2, 'pindirs': 3, 'flag': 4, 'irq': 5, 'nrzi': 6, 'ctl': 7}
WSRC = {'pin': 0, 'edge': 1, 'flag': 2, 'anyedge': 3}
ALU = {'addx': 0, 'addy': 1, 'addxy': 2, 'subxy': 3, 'xorxy': 4, 'andxy': 5, 'shrx': 6, 'swap': 7}


def assemble(text, base=0):
    lines, labels = [], {}
    for raw in text.splitlines():
        line = raw.split(';')[0].strip()
        m = re.match(r'^(\w+):\s*(.*)$', line)
        if m:
            labels[m.group(1)] = base + len(lines)
            line = m.group(2).strip()
        if line:
            lines.append(line)
    out = []
    for line in lines:
        side = dly = 0
        m = re.search(r'\[(\d)\]', line)
        if m:
            dly = int(m.group(1))
            line = line.replace(m.group(0), '')
        m = re.search(r'\bside\s+([01t])', line)
        if m:
            side = {'t': 1, '0': 2, '1': 3}[m.group(1)]
            line = line.replace(m.group(0), '')
        t = line.split()
        op, a = t[0], t[1:]
        if op == 'jmp':
            code, arg = 0, (JC[a[0]] if len(a) == 2 else 0) << 6 | labels[a[-1]]
        elif op == 'wait':
            code, arg = 1, int(a[0]) << 8 | WSRC[a[1]] << 6 | int(a[2]) << 3 | ('resync' in a) << 2
        elif op == 'in':
            code, arg = 2, INS[a[0]] << 6 | ('discard' in a) << 5 | int(a[1])
        elif op == 'out':
            code, arg = 3, OUTD[a[0]] << 6 | int(a[1])
        elif op in ('push', 'pull'):
            code = 4
            arg = (op == 'pull') << 8 | (('iffull' in a) or ('ifempty' in a)) << 7 | ('noblock' not in a) << 6
        elif op == 'mov':
            s, mode = a[1], 0
            if s[0] == '~':
                s, mode = s[1:], 1
            elif s.startswith('::'):
                s, mode = s[2:], 2
            code, arg = 5, MOVD[a[0]] << 6 | mode << 4 | MOVS[s]
        elif op == 'nop':
            code, arg = 5, MOVD['y'] << 6 | MOVS['y']
        elif op == 'set':
            code, arg = 6, SETD[a[0]] << 6 | (int(a[1], 0) & 63)
        elif op in ALU:
            code, arg = 7, ALU[op] << 6 | ((int(a[0], 0) & 63) if a else 0)
        else:
            raise SystemExit('unknown instruction: ' + line)
        out.append(code << 13 | side << 11 | dly << 9 | arg)
    return out, labels


def programs(path):
    """{name: source text} for every `.program name` section of a file."""
    progs, name = {}, None
    for line in open(path, encoding='utf-8').read().splitlines():
        m = re.match(r'^\.program\s+(\w+)', line.strip())
        if m:
            name = m.group(1)
            progs[name] = ''
        elif name:
            progs[name] += line + '\n'
    return progs


if __name__ == '__main__':
    for name, text in programs(sys.argv[1]).items():
        words, _ = assemble(text)
        print(name, len(words), ' '.join('%04x' % w for w in words))

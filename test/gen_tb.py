"""Builds test/tb_pea.sv from tb_pea.tmpl: each `//@PROG name base` line becomes the
assembled program. Run from the repo root:

    python test/gen_tb.py
    iverilog -g2012 -o sim test/tb_pea.sv src/*.v && vvp sim
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fw'))
import pea_asm  # noqa: E402

progs = pea_asm.programs(os.path.join(HERE, '..', 'fw', 'programs.pea'))
out = []
for line in open(os.path.join(HERE, 'tb_pea.tmpl'), encoding='utf-8').read().splitlines():
    m = re.match(r'^//@PROG\s+(\w+)\s+(\d+)', line)
    if not m:
        out.append(line)
        continue
    base = int(m.group(2))
    words, _ = pea_asm.assemble(progs[m.group(1)], base)
    out.append('        // %s: %d words at %d' % (m.group(1), len(words), base))
    out += ["        pm[%d] = 16'h%04x;" % (base + i, w) for i, w in enumerate(words)]
with open(os.path.join(HERE, 'tb_pea.sv'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(out) + '\n')
print('wrote test/tb_pea.sv')

#!/bin/bash
# Mutation check: each planted bug in a copy of the engine must be caught by the ISA-model comparison.
set -u
caught=0; total=0
while IFS='|' read -r name from to; do
  total=$((total+1))
  sed "s/$from/$to/" src/pea_engine.v > /tmp/mut.v
  cmp -s src/pea_engine.v /tmp/mut.v && { echo "MUTANT $name: pattern not found"; exit 1; }
  iverilog -g2012 -o /tmp/msim test/tb_engine_rand.sv /tmp/mut.v && (cd /tmp && vvp -n msim +runs=60 >/dev/null)
  if python3 test/pea_ref.py /tmp/engine_trace.txt >/tmp/mut.log; then echo "MUTANT $name: NOT caught"; else caught=$((caught+1)); echo "MUTANT $name: caught"; fi
done <<'LIST'
alu xor->or|x_n = x ^ y|x_n = x \| y
jmp x!=y->x==y|jtaken = (x != y)|jtaken = (x == y)
in shift-right off by one|(isr >> n)|(isr >> (n - 4'd1))
autopush threshold >= -> >|cnt5 >= {1'b0, ithr}|cnt5 > {1'b0, ithr}
stuff counter saturate 7->6|(run == 3'd7) ? 3'd7 : run + 3'd1) : 3'd0|(run == 3'd6) ? 3'd6 : run + 3'd1) : 3'd0
crc feedback tap|crc\[crc_w\] ^ bitv|crc[crc_w] ^ ~bitv
side-set toggle uses pout_val|((~pout_cur) \& (8'h01 << side_pin))|((pout_cur) \& (8'h01 << side_pin))
wrap ignored|(pc == wrap_top) ? wrap_bot : pc + 6'd1|pc + 6'd1
pull-empty loads x->y|else begin osr_n = x; osr_cnt_n|else begin osr_n = y; osr_cnt_n
divider fraction carry dropped|div_m1 + {15'd0, fsum\[8\]}|div_m1
LIST
echo "mutation check: $caught/$total planted bugs caught"
[ "$caught" = "$total" ]

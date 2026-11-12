// Random-instruction test of one PEA engine against an independent ISA model (test/pea_ref.py).
// Each run: random configuration, random 64-word program, random pins/flags/FIFO status every clock.
// Every clock the inputs, outputs and architectural state are logged; the Python model replays the
// inputs and must reproduce every output and every state register, clock by clock.
`timescale 1ns/1ps
`default_nettype none
module tb_engine_rand;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [15:0] prog [0:63];
    wire [5:0]  pc;
    wire [15:0] ir = prog[pc];
    reg  [15:0] div_int; reg [7:0] div_frac;
    reg  [2:0]  in_base, out_base, set_base, set_cnt, side_pin, jmp_pin, stuff_n;
    reg  [5:0]  wrap_bot, wrap_top;
    reg  [3:0]  in_thr, out_thr, crc_w;
    reg         in_right, out_right, autopush, autopull, auto_resync, resync_half, stuff_mode, diff;
    reg  [15:0] crc_poly;
    reg  [7:0]  pins = 0, pins_prev = 0, pout = 0, flags = 0, tx_data = 0;
    reg         tx_empty = 1, rx_full = 0;
    wire [7:0]  pout_mask, pout_val, pdir_mask, pdir_val, flag_set, flag_clr, rx_data;
    wire        irq, tx_pop, rx_push, overrun, waiting;

    pea_engine dut (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .pc_o(pc), .ir(ir), .ir_ok(1'b1),
        .force_pc(1'b0), .force_addr(6'd0),
        .div_int(div_int), .div_frac(div_frac), .in_base(in_base), .out_base(out_base),
        .set_base(set_base), .set_cnt(set_cnt), .side_pin(side_pin), .jmp_pin(jmp_pin),
        .wrap_bot(wrap_bot), .wrap_top(wrap_top), .in_thr(in_thr), .out_thr(out_thr),
        .in_right(in_right), .out_right(out_right), .autopush(autopush), .autopull(autopull),
        .auto_resync(auto_resync), .resync_half(resync_half), .stuff_mode(stuff_mode), .diff(diff),
        .stuff_n(stuff_n), .crc_poly(crc_poly), .crc_w(crc_w),
        .pins(pins), .pins_prev(pins_prev), .pout_cur(pout), .flags(flags),
        .pout_mask(pout_mask), .pout_val(pout_val), .pdir_mask(pdir_mask), .pdir_val(pdir_val),
        .flag_set(flag_set), .flag_clr(flag_clr), .irq(irq),
        .tx_data(tx_data), .tx_empty(tx_empty), .tx_pop(tx_pop),
        .rx_data(rx_data), .rx_full(rx_full), .rx_push(rx_push), .overrun(overrun), .waiting_o(waiting)
    );

    integer f, r, c, i, runs, clocks;
    reg [31:0] rnd;
    initial begin
        if (!$value$plusargs("runs=%d", runs)) runs = 400;
        if (!$value$plusargs("clocks=%d", clocks)) clocks = 3000;
        f = $fopen("engine_trace.txt", "w");
        for (r = 0; r < runs; r = r + 1) begin
            rst_n = 0;
            for (i = 0; i < 64; i = i + 1) prog[i] = $urandom;
            // every 4th program is a tight bit-shifting loop (long runs of equal bits: stuffing counter)
            if (r % 4 == 3) begin
                prog[0] = 16'h6000 | ($urandom & 16'h01C7);                  // out/in 1 bit to a random dest
                prog[0][15:13] = ($urandom & 1) ? 3'd3 : 3'd2; prog[0][3:0] = 4'd1; prog[0][5] = 1'b0;
                prog[1] = 16'h0000;                                            // jmp 0
                if ($urandom & 1) prog[1] = 16'h0180 | 16'd0;                  // jmp stuff 0 (6 << 6)
            end
            rnd = $urandom; div_int = rnd[2:0]; div_frac = (rnd[3]) ? rnd[15:8] : 8'd0;
            rnd = $urandom;
            {in_base, out_base, set_base, set_cnt, side_pin, jmp_pin, stuff_n} = rnd[20:0];
            rnd = $urandom;
            wrap_bot = rnd[5:0]; wrap_top = rnd[11:6]; in_thr = rnd[15:12]; out_thr = rnd[19:16];
            crc_w = rnd[23:20];
            {in_right, out_right, autopush, autopull, auto_resync, resync_half, stuff_mode, diff} = rnd[31:24];
            crc_poly = $urandom;
            if (wrap_top < wrap_bot) wrap_top = 6'd63;   // usual case; wrap bypass still covered
            pins = $urandom; pins_prev = pins; pout = 0; flags = $urandom;
            $fdisplay(f, "R %0d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                r, div_int, div_frac, in_base, out_base, set_base, set_cnt, side_pin, jmp_pin, stuff_n,
                wrap_bot, wrap_top, in_thr, out_thr, crc_w, in_right, out_right, autopush, autopull,
                auto_resync, resync_half, stuff_mode, diff, crc_poly, 8'h00);
            for (i = 0; i < 64; i = i + 1) $fdisplay(f, "P %h", prog[i]);
            @(negedge clk); @(negedge clk); rst_n = 1;
            for (c = 0; c < clocks; c = c + 1) begin
                // inputs change after the falling edge; pins and flags change slowly
                rnd = $urandom;
                pins_prev = pins;
                if (rnd[2:0] == 0) pins = pins ^ (8'h01 << rnd[5:3]);
                if (rnd[8:6] == 0) flags = flags ^ (8'h01 << rnd[11:9]);
                tx_empty = rnd[13:12] == 0; rx_full = rnd[15:14] == 0;
                tx_data = rnd[23:16];
                #4;
                $fdisplay(f, "C %h %h %h %h %h %h %h %h  %h %h %h %h %h %h %h %h %h %h %h %h %h  %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                    ir, pins, pins_prev, pout, flags, tx_data, tx_empty, rx_full,
                    pc, pout_mask, pout_val, pdir_mask, pdir_val, flag_set, flag_clr, irq, tx_pop,
                    rx_push, rx_data, overrun, waiting,
                    dut.dly, dut.fresh, dut.x, dut.y, dut.isr, dut.osr, dut.isr_cnt, dut.osr_cnt,
                    dut.crc, dut.crc_in_en, dut.crc_out_en, dut.run, dut.last_s, dut.last_b, dut.dcnt, dut.facc);
                @(posedge clk);
                pout = (pout & ~pout_mask) | (pout_val & pout_mask);
                @(negedge clk);
            end
        end
        $fclose(f);
        $display("engine random test: %0d runs x %0d clocks logged", runs, clocks);
        $finish;
    end
endmodule
`default_nettype wire

// PEA engine: one programmable protocol state machine.
// 16-bit instructions, one per tick: [15:13] op, [12:11] side-set (0 none, 1 toggle, 2 low, 3 high),
// [10:9] delay ticks, [8:0] operand. Beyond RP2040 PIO it adds: divider resync on edges (clock
// recovery), NRZI encode/decode, a run-length (bit-stuffing) counter, a programmable CRC/LFSR,
// open-drain pins, small ALU ops and X!=Y / stuff branch conditions.
`default_nettype none
module pea_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    // program
    output wire [5:0]  pc_o,
    input  wire [15:0] ir,
    input  wire        force_pc,
    input  wire [5:0]  force_addr,
    // configuration
    input  wire [15:0] div_int,
    input  wire [7:0]  div_frac,
    input  wire [2:0]  in_base,
    input  wire [2:0]  out_base,
    input  wire [2:0]  set_base,
    input  wire [2:0]  set_cnt,
    input  wire [2:0]  side_pin,
    input  wire [2:0]  jmp_pin,
    input  wire [5:0]  wrap_bot,
    input  wire [5:0]  wrap_top,
    input  wire [3:0]  in_thr,
    input  wire [3:0]  out_thr,
    input  wire        in_right,
    input  wire        out_right,
    input  wire        autopush,
    input  wire        autopull,
    input  wire        auto_resync,
    input  wire        resync_half,
    input  wire        stuff_mode,
    input  wire        diff,
    input  wire [2:0]  stuff_n,
    input  wire [15:0] crc_poly,
    input  wire [3:0]  crc_w,
    // pins and flags
    input  wire [7:0]  pins,
    input  wire [7:0]  pins_prev,
    input  wire [7:0]  pout_cur,
    input  wire [7:0]  flags,
    output reg  [7:0]  pout_mask,
    output reg  [7:0]  pout_val,
    output reg  [7:0]  pdir_mask,
    output reg  [7:0]  pdir_val,
    output reg  [7:0]  flag_set,
    output reg  [7:0]  flag_clr,
    output reg         irq,
    // FIFOs
    input  wire [7:0]  tx_data,
    input  wire        tx_empty,
    output reg         tx_pop,
    output reg  [7:0]  rx_data,
    input  wire        rx_full,
    output reg         rx_push,
    output reg         overrun,
    output wire        waiting_o
);
    reg [5:0]  pc;
    reg [1:0]  dly;
    reg        fresh, waiting;
    reg [7:0]  x, y, isr, osr;
    reg [3:0]  isr_cnt, osr_cnt;
    reg [15:0] crc;
    reg        crc_in_en, crc_out_en;
    reg [2:0]  run;
    reg        last_s, last_b;
    reg [15:0] dcnt;
    reg [7:0]  facc;

    assign pc_o = pc;
    assign waiting_o = waiting;

    wire [2:0]  op   = ir[15:13];
    wire [1:0]  side = ir[12:11];
    wire [8:0]  a    = ir[8:0];
    wire [3:0]  n    = (a[3:0] == 4'd0 || a[3]) ? 4'd8 : a[3:0];
    wire [7:0]  nmask = 8'hFF >> (4'd8 - n);
    wire [3:0]  ithr = (in_thr == 4'd0 || in_thr > 4'd8) ? 4'd8 : in_thr;
    wire [3:0]  othr = (out_thr == 4'd0 || out_thr > 4'd8) ? 4'd8 : out_thr;

    wire tick = en && (dcnt == 16'd0);
    wire exec = tick && (dly == 2'd0) && !waiting;

    /* verilator lint_off UNUSEDSIGNAL */
    function [7:0] rotl(input [7:0] v, input [2:0] s);
        reg [15:0] t;
        begin t = {v, v} << s; rotl = t[15:8]; end
    endfunction
    function [7:0] rotr(input [7:0] v, input [2:0] s);
        reg [15:0] t;
        begin t = {v, v} >> s; rotr = t[7:0]; end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function [7:0] brev(input [7:0] v);
        brev = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
    endfunction

    wire        pin_in0  = pins[in_base];
    wire        edge_any = pins[a[5:3]] != pins_prev[a[5:3]];
    wire [5:0]  pc_inc   = (pc == wrap_top) ? wrap_bot : pc + 6'd1;
    wire [15:0] div_m1   = (div_int == 16'd0) ? 16'd0 : div_int - 16'd1;
    wire [8:0]  fsum     = {1'b0, facc} + {1'b0, div_frac};

    // next-state (blocking temporaries, assigned once: one writer per register)
    reg [5:0]  pc_n;
    reg [1:0]  dly_n;
    reg        fresh_n, waiting_n;
    reg [7:0]  x_n, y_n, isr_n, osr_n;
    reg [3:0]  isr_cnt_n, osr_cnt_n;
    reg [15:0] crc_n;
    reg        crc_in_n, crc_out_n;
    reg [2:0]  run_n;
    reg        last_s_n, last_b_n;
    reg        resync, done, stall, wcond, jtaken;
    reg        bitv, bit_valid, crc_upd;
    reg [7:0]  src, data, osr_eff;
    reg [3:0]  ocnt_eff;
    reg [4:0]  cnt5;
    reg        nrz;

    always @* begin
        pc_n = pc; dly_n = dly; fresh_n = fresh; waiting_n = waiting;
        x_n = x; y_n = y; isr_n = isr; osr_n = osr; isr_cnt_n = isr_cnt; osr_cnt_n = osr_cnt;
        crc_n = crc; crc_in_n = crc_in_en; crc_out_n = crc_out_en; run_n = run;
        last_s_n = last_s; last_b_n = last_b;
        pout_mask = 8'h00; pout_val = 8'h00; pdir_mask = 8'h00; pdir_val = 8'h00;
        flag_set = 8'h00; flag_clr = 8'h00; irq = 1'b0;
        tx_pop = 1'b0; rx_push = 1'b0; rx_data = 8'h00; overrun = 1'b0;
        resync = 1'b0; done = 1'b0; stall = 1'b0; wcond = 1'b0; jtaken = 1'b0;
        bitv = 1'b0; bit_valid = 1'b0; crc_upd = 1'b0;
        src = 8'h00; data = 8'h00; osr_eff = osr; ocnt_eff = osr_cnt; cnt5 = 5'd0; nrz = 1'b0;

        if (tick && dly != 2'd0) dly_n = dly - 2'd1;

        // WAIT: starts on a tick, then its condition is checked every clock
        case (a[7:6])
            2'd0: wcond = pins[a[5:3]] == a[8];
            2'd1: wcond = (pins[a[5:3]] == a[8]) && (pins_prev[a[5:3]] != a[8]);
            2'd2: wcond = flags[a[5:3]] == a[8];
            default: wcond = edge_any;
        endcase

        if ((exec || waiting) && op == 3'd1) begin
            if (wcond) begin
                done = 1'b1; waiting_n = 1'b0; resync = a[2];
            end else begin
                waiting_n = 1'b1;
            end
        end else if (exec) begin
            done = 1'b1;
            case (op)
                3'd0: begin // JMP
                    case (a[8:6])
                        3'd0: jtaken = 1'b1;
                        3'd1: jtaken = (x == 8'd0);
                        3'd2: begin jtaken = (x != 8'd0); x_n = x - 8'd1; end
                        3'd3: jtaken = (y == 8'd0);
                        3'd4: begin jtaken = (y != 8'd0); y_n = y - 8'd1; end
                        3'd5: jtaken = pins[jmp_pin];
                        3'd6: begin jtaken = (run >= stuff_n); if (jtaken) run_n = 3'd0; end
                        default: jtaken = (x != y);
                    endcase
                end
                3'd2: begin // IN
                    case (a[8:6])
                        3'd0: src = rotr(pins, in_base);
                        3'd1: src = x;
                        3'd2: src = y;
                        3'd3: src = 8'h00;
                        3'd4: src = osr;
                        3'd5: begin src = {7'd0, ~(pin_in0 ^ last_s)}; last_s_n = pin_in0; end
                        3'd6: src = crc[7:0];
                        default: src = crc[15:8];
                    endcase
                    data = src & nmask;
                    bitv = data[0];
                    if (a[5]) begin
                        run_n = 3'd0;
                    end else begin
                        bit_valid = (n == 4'd1);
                        crc_upd = crc_in_en && (n == 4'd1);
                        isr_n = in_right ? ((isr >> n) | (data << (4'd8 - n))) : ((isr << n) | data);
                        cnt5 = {1'b0, isr_cnt} + {1'b0, n};
                        isr_cnt_n = (cnt5 > 5'd8) ? 4'd8 : cnt5[3:0];
                        if (autopush && cnt5 >= {1'b0, ithr}) begin
                            rx_data = isr_n; rx_push = !rx_full; overrun = rx_full;
                            isr_n = 8'h00; isr_cnt_n = 4'd0;
                        end
                    end
                end
                3'd3: begin // OUT
                    if (osr_cnt >= othr && autopull) begin
                        if (tx_empty) stall = 1'b1;
                        else begin osr_eff = tx_data; ocnt_eff = 4'd0; tx_pop = 1'b1; end
                    end
                    if (!stall) begin
                        data = out_right ? (osr_eff & nmask) : (osr_eff >> (4'd8 - n));
                        osr_n = out_right ? (osr_eff >> n) : (osr_eff << n);
                        cnt5 = {1'b0, ocnt_eff} + {1'b0, n};
                        osr_cnt_n = (cnt5 > 5'd8) ? 4'd8 : cnt5[3:0];
                        bitv = data[0];
                        case (a[8:6])
                            3'd0: begin
                                pout_mask = rotl(nmask, out_base); pout_val = rotl(data, out_base);
                                bit_valid = (n == 4'd1);
                            end
                            3'd1: x_n = data;
                            3'd2: y_n = data;
                            3'd4: begin pdir_mask = rotl(nmask, out_base); pdir_val = rotl(data, out_base); end
                            3'd5: begin
                                nrz = pout_cur[out_base] ^ ~data[0];
                                pout_mask = rotl(diff ? 8'h03 : 8'h01, out_base);
                                pout_val  = rotl({6'd0, ~nrz, nrz}, out_base);
                                bit_valid = 1'b1;
                            end
                            3'd6: begin jtaken = 1'b1; end
                            default: ;
                        endcase
                        crc_upd = crc_out_en && (n == 4'd1);
                    end
                end
                3'd4: begin // PUSH / PULL
                    if (!a[8]) begin
                        if (!a[7] || isr_cnt >= ithr) begin
                            if (rx_full && a[6]) stall = 1'b1;
                            else begin
                                rx_data = isr; rx_push = !rx_full; overrun = rx_full;
                                isr_n = 8'h00; isr_cnt_n = 4'd0;
                            end
                        end
                    end else begin
                        if (!a[7] || osr_cnt >= othr) begin
                            if (tx_empty) begin
                                if (a[6]) stall = 1'b1;
                                else begin osr_n = x; osr_cnt_n = 4'd0; end
                            end else begin
                                osr_n = tx_data; osr_cnt_n = 4'd0; tx_pop = 1'b1;
                            end
                        end
                    end
                end
                3'd5: begin // MOV
                    case (a[2:0])
                        3'd0: src = rotr(pins, in_base);
                        3'd1: src = x;
                        3'd2: src = y;
                        3'd3: src = 8'h00;
                        3'd4: src = crc[7:0];
                        3'd5: src = crc[15:8];
                        3'd6: src = isr;
                        default: src = osr;
                    endcase
                    data = (a[5:4] == 2'd1) ? ~src : (a[5:4] == 2'd2) ? brev(src) : src;
                    case (a[8:6])
                        3'd0: begin pout_mask = 8'hFF; pout_val = rotl(data, out_base); end
                        3'd1: x_n = data;
                        3'd2: y_n = data;
                        3'd3: begin pdir_mask = 8'hFF; pdir_val = rotl(data, out_base); end
                        3'd4: jtaken = 1'b1;
                        3'd5: begin isr_n = data; isr_cnt_n = 4'd0; end
                        3'd6: begin osr_n = data; osr_cnt_n = 4'd0; end
                        default: crc_n = {data, data};
                    endcase
                end
                3'd6: begin // SET
                    case (a[8:6])
                        3'd0: begin
                            pout_mask = rotl(8'hFF >> (4'd8 - {1'b0, set_cnt}), set_base);
                            pout_val  = rotl({2'd0, a[5:0]}, set_base);
                        end
                        3'd1: x_n = {2'd0, a[5:0]};
                        3'd2: y_n = {2'd0, a[5:0]};
                        3'd3: begin
                            pdir_mask = rotl(8'hFF >> (4'd8 - {1'b0, set_cnt}), set_base);
                            pdir_val  = rotl({2'd0, a[5:0]}, set_base);
                        end
                        3'd4: begin
                            if (a[3]) flag_set = 8'h01 << a[2:0];
                            else      flag_clr = 8'h01 << a[2:0];
                        end
                        3'd5: irq = 1'b1;
                        3'd6: begin
                            nrz = pout_cur[out_base] ^ ~a[0];
                            pout_mask = rotl(diff ? 8'h03 : 8'h01, out_base);
                            pout_val  = rotl({6'd0, ~nrz, nrz}, out_base);
                            run_n = 3'd0;
                        end
                        default: begin
                            crc_in_n = a[0]; crc_out_n = a[1];
                            if (a[2]) run_n = 3'd0;
                        end
                    endcase
                end
                default: begin // ALU
                    case (a[8:6])
                        3'd0: x_n = x + {a[5], a[5], a[5:0]};
                        3'd1: y_n = y + {a[5], a[5], a[5:0]};
                        3'd2: x_n = x + y;
                        3'd3: x_n = x - y;
                        3'd4: x_n = x ^ y;
                        3'd5: x_n = x & y;
                        3'd6: x_n = {1'b0, x[7:1]};
                        default: begin x_n = y; y_n = x; end
                    endcase
                end
            endcase
            if (stall) begin
                done = 1'b0;
                x_n = x; y_n = y; isr_n = isr; osr_n = osr; isr_cnt_n = isr_cnt; osr_cnt_n = osr_cnt;
                run_n = run; last_s_n = last_s;
                bit_valid = 1'b0; crc_upd = 1'b0; jtaken = 1'b0;
            end
        end

        // run-length counter and CRC follow single-bit shifts
        if (bit_valid) begin
            if (!stuff_mode) run_n = bitv ? ((run == 3'd7) ? 3'd7 : run + 3'd1) : 3'd0;
            else begin
                run_n = (bitv == last_b) ? ((run == 3'd7) ? 3'd7 : run + 3'd1) : 3'd1;
                last_b_n = bitv;
            end
        end
        if (crc_upd)
            crc_n = {crc[14:0], 1'b0} ^ ((crc[crc_w] ^ bitv) ? crc_poly : 16'h0000);

        // side-set applies once, when an instruction first executes (even if it then stalls)
        if (exec && fresh && side != 2'd0) begin
            pout_mask = pout_mask | (8'h01 << side_pin);
            if (side == 2'd1) pout_val = (pout_val & ~(8'h01 << side_pin)) | ((~pout_cur) & (8'h01 << side_pin));
            else              pout_val = (pout_val & ~(8'h01 << side_pin)) | ({7'd0, side[0]} << side_pin);
        end
        if (exec) fresh_n = 1'b0;

        if (done) begin
            fresh_n = 1'b1;
            dly_n = ir[10:9];
            if (!jtaken) pc_n = pc_inc;
            else if (op == 3'd0) pc_n = a[5:0];
            else pc_n = data[5:0];
        end

        if (auto_resync && pin_in0 != pins_prev[in_base]) resync = 1'b1;

        if (force_pc) begin
            pc_n = force_addr; dly_n = 2'd0; fresh_n = 1'b1; waiting_n = 1'b0;
            isr_cnt_n = 4'd0; osr_cnt_n = 4'd8;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 6'd0; dly <= 2'd0; fresh <= 1'b1; waiting <= 1'b0;
            x <= 8'd0; y <= 8'd0; isr <= 8'd0; osr <= 8'd0; isr_cnt <= 4'd0; osr_cnt <= 4'd8;
            crc <= 16'd0; crc_in_en <= 1'b0; crc_out_en <= 1'b0; run <= 3'd0;
            last_s <= 1'b1; last_b <= 1'b0; dcnt <= 16'd0; facc <= 8'd0;
        end else begin
            pc <= pc_n; dly <= dly_n; fresh <= fresh_n; waiting <= waiting_n;
            x <= x_n; y <= y_n; isr <= isr_n; osr <= osr_n; isr_cnt <= isr_cnt_n; osr_cnt <= osr_cnt_n;
            crc <= crc_n; crc_in_en <= crc_in_n; crc_out_en <= crc_out_n; run <= run_n;
            last_s <= last_s_n; last_b <= last_b_n;
            if (resync) begin
                dcnt <= resync_half ? {1'b0, div_int[15:1]} : div_m1;
            end else if (tick) begin
                facc <= fsum[7:0];
                dcnt <= div_m1 + {15'd0, fsum[8]};
            end else if (en) begin
                dcnt <= dcnt - 16'd1;
            end
        end
    end
endmodule
`default_nettype wire

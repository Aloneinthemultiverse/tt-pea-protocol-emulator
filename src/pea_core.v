// PEA core: 4 engines sharing a 64-word program store, 8 protocol pins, 8 flags,
// per-engine TX/RX FIFOs and an SPI-slave host port (mode 0, oversampled by clk).
// Host frame: byte0 = {write, addr[6:0]}, then data bytes to/from that same register.
`default_nettype none
module pea_fifo (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       push,
    input  wire [7:0] din,
    input  wire       pop,
    output wire [7:0] dout,
    output wire       full,
    output wire       empty
);
    reg [7:0] mem [0:3];
    reg [2:0] wp, rp;
    assign empty = (wp == rp);
    assign full  = (wp[1:0] == rp[1:0]) && (wp[2] != rp[2]);
    assign dout  = empty ? 8'h00 : mem[rp[1:0]];   // never present unwritten storage
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wp <= 3'd0; rp <= 3'd0; end
        else begin
            if (push && !full) begin mem[wp[1:0]] <= din; wp <= wp + 3'd1; end
            if (pop && !empty) rp <= rp + 3'd1;
        end
    end
endmodule

module pea_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       spi_sclk,
    input  wire       spi_csn,
    input  wire       spi_mosi,
    output wire       spi_miso,
    output wire       irq_o,
    input  wire [7:0] pin_i,
    output wire [7:0] pin_o,
    output wire [7:0] pin_oe,
    output wire [7:0] flags_o
);
    // ---------------- synchronisers
    reg [7:0] p1, pins, pins_prev;
    reg [2:0] sck_s, csn_s;
    reg [1:0] mosi_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1 <= 8'hFF; pins <= 8'hFF; pins_prev <= 8'hFF;
            sck_s <= 3'd0; csn_s <= 3'b111; mosi_s <= 2'd0;
        end else begin
            p1 <= pin_i; pins <= p1; pins_prev <= pins;
            sck_s <= {sck_s[1:0], spi_sclk}; csn_s <= {csn_s[1:0], spi_csn}; mosi_s <= {mosi_s[0], spi_mosi};
        end
    end
    wire sck_rise = (sck_s[2:1] == 2'b01);
    wire sck_fall = (sck_s[2:1] == 2'b10);
    wire csn = csn_s[1];
    wire mosi = mosi_s[1];

    // ---------------- SPI host port
    reg [2:0] bitc;
    reg [6:0] shin;
    reg [7:0] shout;
    reg       have_cmd, cmd_wr;
    reg [6:0] addr;
    wire [7:0] byte_in = {shin, mosi};
    wire       byte_done = !csn && sck_rise && (bitc == 3'd7);
    wire       is_cmd = byte_done && !have_cmd;
    wire [6:0] cur_addr = is_cmd ? byte_in[6:0] : addr;
    wire       wr_stb = byte_done && have_cmd && cmd_wr;
    // A read presents the register when the command byte ends. A FIFO entry is popped only once
    // its byte has been shifted out; the next value is loaded one clock later.
    wire       rd_pop = byte_done && have_cmd && !cmd_wr;
    reg        rd_pop_d;
    wire       rd_stb = (is_cmd && !byte_in[7]) || rd_pop_d;
    reg  [7:0] rdata;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bitc <= 3'd0; shin <= 7'd0; shout <= 8'd0; have_cmd <= 1'b0; cmd_wr <= 1'b0; addr <= 7'd0;
            rd_pop_d <= 1'b0;
        end else if (csn) begin
            bitc <= 3'd0; have_cmd <= 1'b0; rd_pop_d <= 1'b0;
        end else begin
            rd_pop_d <= rd_pop;
            if (sck_rise) begin
                shin <= byte_in[6:0];
                bitc <= bitc + 3'd1;
            end
            if (is_cmd) begin have_cmd <= 1'b1; cmd_wr <= byte_in[7]; addr <= byte_in[6:0]; end
            if (rd_stb) shout <= rdata;
            else if (sck_fall && bitc != 3'd0) shout <= {shout[6:0], 1'b0};
        end
    end
    assign spi_miso = shout[7];

    // ---------------- registers
    wire spi_csn_start = (csn_s[2:1] == 2'b10);
    reg [3:0]  en;
    reg [7:0]  irqs, flags, pin_od, pin_dir, pin_out;
    reg [5:0]  paddr;
    reg [7:0]  plo;
    reg        phase;
    reg [15:0] prog [0:63];
    reg [7:0]  ecfg [0:63];

    wire        w_glob = wr_stb && (addr[6:4] == 3'd0);
    wire        e_sel  = (cur_addr[6:4] >= 3'd1) && (cur_addr[6:4] <= 3'd4);
    wire [1:0]  e_idx  = cur_addr[5:4] - 2'd1;

    wire [5:0]  e_pc   [0:3];
    wire [7:0]  e_pm   [0:3];
    wire [7:0]  e_pv   [0:3];
    wire [7:0]  e_dm   [0:3];
    wire [7:0]  e_dv   [0:3];
    wire [7:0]  e_fs   [0:3];
    wire [7:0]  e_fc   [0:3];
    wire [3:0]  e_irq, e_ovr, e_wait, tx_full, tx_empty, rx_full, rx_empty;
    wire [7:0]  rx_dout [0:3];

    integer i, k;                                  // i: clocked reset loop, k: combinational loop
    reg [7:0] po_n, pd_n, fl_n;
    always @* begin
        po_n = pin_out; pd_n = pin_dir; fl_n = flags;
        if (w_glob && addr[3:0] == 4'h8) po_n = byte_in;
        if (w_glob && addr[3:0] == 4'h7) pd_n = byte_in;
        if (w_glob && addr[3:0] == 4'h2) fl_n = byte_in;
        for (k = 0; k < 4; k = k + 1) begin
            po_n = (po_n & ~e_pm[k]) | (e_pv[k] & e_pm[k]);
            pd_n = (pd_n & ~e_dm[k]) | (e_dv[k] & e_dm[k]);
            fl_n = (fl_n | e_fs[k]) & ~e_fc[k];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            en <= 4'd0; irqs <= 8'd0; flags <= 8'd0; pin_od <= 8'd0; pin_dir <= 8'd0; pin_out <= 8'hFF;
            paddr <= 6'd0; plo <= 8'd0; phase <= 1'b0;
            for (i = 0; i < 64; i = i + 1) ecfg[i] <= 8'd0;
        end else begin
            pin_out <= po_n; pin_dir <= pd_n; flags <= fl_n;
            irqs <= (irqs | {e_ovr, e_irq}) & ~((w_glob && addr[3:0] == 4'h1) ? byte_in : 8'h00);
            if (spi_csn_start) phase <= 1'b0;
            if (w_glob) begin
                case (addr[3:0])
                    4'h0: en <= byte_in[3:0];
                    4'h3: paddr <= byte_in[5:0];
                    4'h4: begin
                        phase <= ~phase;
                        if (!phase) plo <= byte_in;
                        else begin prog[paddr] <= {byte_in, plo}; paddr <= paddr + 6'd1; end
                    end
                    4'h6: pin_od <= byte_in;
                    default: ;
                endcase
            end
            if (wr_stb && e_sel && addr[3:0] <= 4'hC) ecfg[{e_idx, addr[3:0]}] <= byte_in;
        end
    end

    always @* begin
        rdata = 8'h00;
        if (cur_addr[6:4] == 3'd0) begin
            case (cur_addr[3:0])
                4'h0: rdata = {4'd0, en};
                4'h1: rdata = irqs;
                4'h2: rdata = flags;
                4'h3: rdata = {2'd0, paddr};
                4'h5: rdata = pins;
                4'h6: rdata = pin_od;
                4'h7: rdata = pin_dir;
                4'h8: rdata = pin_out;
                default: rdata = 8'h00;
            endcase
        end else if (e_sel) begin
            case (cur_addr[3:0])
                4'hD: rdata = rx_dout[e_idx];
                4'hE: rdata = {3'd0, e_wait[e_idx], rx_empty[e_idx], rx_full[e_idx], tx_empty[e_idx], tx_full[e_idx]};
                4'hF: rdata = {2'd0, e_pc[e_idx]};
                default: rdata = ecfg[{e_idx, cur_addr[3:0]}];
            endcase
        end
    end

    // ---------------- engines
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : eng
            wire [1:0] gi = g[1:0];
            wire       mine = e_sel && (e_idx == gi);
            wire [7:0] tx_dout, rx_din;
            wire       tx_pop, rx_push;
            // Registered instruction fetch: breaks the 64-way program mux out of the execute path.
            // The engine's tick period is at least 2 clocks, so the instruction is always ready.
            reg [15:0] ir_r;
            always @(posedge clk) ir_r <= prog[e_pc[g]];
            pea_fifo u_tx (.clk(clk), .rst_n(rst_n), .push(wr_stb && mine && addr[3:0] == 4'hD), .din(byte_in),
                           .pop(tx_pop), .dout(tx_dout), .full(tx_full[g]), .empty(tx_empty[g]));
            pea_fifo u_rx (.clk(clk), .rst_n(rst_n), .push(rx_push), .din(rx_din),
                           .pop(rd_pop && mine && addr[3:0] == 4'hD), .dout(rx_dout[g]),
                           .full(rx_full[g]), .empty(rx_empty[g]));
            pea_engine u_e (
                .clk(clk), .rst_n(rst_n), .en(en[g]),
                .pc_o(e_pc[g]), .ir(ir_r),
                .force_pc(wr_stb && mine && addr[3:0] == 4'hF), .force_addr(byte_in[5:0]),
                .div_int({ecfg[{gi, 4'h2}], ecfg[{gi, 4'h1}]}), .div_frac(ecfg[{gi, 4'h0}]),
                .in_base(ecfg[{gi, 4'h3}][2:0]), .out_base(ecfg[{gi, 4'h3}][5:3]),
                .set_base(ecfg[{gi, 4'h4}][2:0]), .side_pin(ecfg[{gi, 4'h4}][5:3]),
                .jmp_pin(ecfg[{gi, 4'h5}][2:0]), .set_cnt(ecfg[{gi, 4'h5}][5:3]),
                .wrap_bot(ecfg[{gi, 4'h6}][5:0]), .wrap_top(ecfg[{gi, 4'h7}][5:0]),
                .in_thr(ecfg[{gi, 4'h8}][3:0]), .out_thr(ecfg[{gi, 4'h8}][7:4]),
                .in_right(ecfg[{gi, 4'h9}][0]), .out_right(ecfg[{gi, 4'h9}][1]),
                .autopush(ecfg[{gi, 4'h9}][2]), .autopull(ecfg[{gi, 4'h9}][3]),
                .auto_resync(ecfg[{gi, 4'h9}][4]), .resync_half(ecfg[{gi, 4'h9}][5]),
                .stuff_mode(ecfg[{gi, 4'h9}][6]), .diff(ecfg[{gi, 4'h9}][7]),
                .stuff_n(ecfg[{gi, 4'hA}][2:0]), .crc_w(ecfg[{gi, 4'hA}][7:4]),
                .crc_poly({ecfg[{gi, 4'hC}], ecfg[{gi, 4'hB}]}),
                .pins(pins), .pins_prev(pins_prev), .pout_cur(pin_out), .flags(flags),
                .pout_mask(e_pm[g]), .pout_val(e_pv[g]), .pdir_mask(e_dm[g]), .pdir_val(e_dv[g]),
                .flag_set(e_fs[g]), .flag_clr(e_fc[g]), .irq(e_irq[g]),
                .tx_data(tx_dout), .tx_empty(tx_empty[g]), .tx_pop(tx_pop),
                .rx_data(rx_din), .rx_full(rx_full[g]), .rx_push(rx_push),
                .overrun(e_ovr[g]), .waiting_o(e_wait[g])
            );
        end
    endgenerate

    // open-drain pins drive low or release
    assign pin_o   = pin_out & ~pin_od;
    assign pin_oe  = pin_dir & ~(pin_od & pin_out);
    assign irq_o   = |irqs;
    assign flags_o = flags;
endmodule
`default_nettype wire

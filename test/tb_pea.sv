// Self-checking testbench for the PEA protocol emulator (generated from tb_pea.tmpl by
// test/gen_tb.py, which embeds the assembled firmware). Protocol partners are independent
// behavioural models: a UART monitor/driver, an SPI slave, an I2C slave with ACK/NACK and
// clock stretching, and an NRZI + bit-stuffing + CRC-16 reference coder.
`timescale 1ns/1ps
module tb_pea;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                       // 50 MHz

    reg sclk = 0, csn = 1, mosi = 0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire miso = uo_out[0];
    wire [7:0] line = uio_out | ~uio_oe;         // released pins read high (pull-ups)

    reg  tb_utx = 1, urx_sel = 0, tb_nrzi = 1, nrzi_sel = 0;
    reg  s_miso = 1, sl_sda_low = 0, sl_scl_low = 0;
    wire sda = line[5] & ~sl_sda_low;
    wire scl = line[6] & ~sl_scl_low;
    wire [7:0] uio_in = {nrzi_sel ? tb_nrzi : line[7], scl, sda, s_miso, line[3], line[2],
                         urx_sel ? tb_utx : line[0], line[0]};

    tt_um_auralis_pea dut (.ui_in({5'd0, mosi, csn, sclk}), .uo_out(uo_out), .uio_in(uio_in),
                           .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));

    integer fails = 0, checks = 0;
    task check(input cond, input [8*40-1:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("PASS %0s", name);
            else begin $display("FAIL %0s", name); fails = fails + 1; end
        end
    endtask

    // ---------------- SPI host
    task spi_byte(input [7:0] d, output [7:0] q);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = d[k]; #80; sclk = 1; q[k] = miso; #80; sclk = 0;
            end
        end
    endtask
    reg [7:0] junk;
    task wr(input [6:0] a, input [7:0] d);
        begin csn = 0; #80; spi_byte({1'b1, a}, junk); spi_byte(d, junk); #80; csn = 1; #160; end
    endtask
    task rd(input [6:0] a, output [7:0] q);
        begin csn = 0; #80; spi_byte({1'b0, a}, junk); spi_byte(8'h00, q); #80; csn = 1; #160; end
    endtask
    task ecfg(input integer e, input [3:0] r, input [7:0] d);
        begin wr(7'h10 + e * 16 + {3'd0, r}, d); end
    endtask
    task erd(input integer e, input [3:0] r, output [7:0] q);
        begin rd(7'h10 + e * 16 + {3'd0, r}, q); end
    endtask

    reg [15:0] pm [0:63];
    integer pi;
    task pm_clear;
        begin for (pi = 0; pi < 64; pi = pi + 1) pm[pi] = 16'h0000; end
    endtask
    task pm_load;
        begin
            wr(7'h00, 8'h00); wr(7'h02, 8'h00); wr(7'h03, 8'h00);
            csn = 0; #80; spi_byte(8'h84, junk);
            for (pi = 0; pi < 64; pi = pi + 1) begin spi_byte(pm[pi][7:0], junk); spi_byte(pm[pi][15:8], junk); end
            #80; csn = 1; #160;
        end
    endtask
    // engine e: divider, pin registers, wrap, shift thresholds, mode, entry point
    task esetup(input integer e, input [15:0] div, input [7:0] frac, input [7:0] p0, input [7:0] p1,
                input [7:0] p2, input [5:0] wb, input [5:0] wt, input [7:0] mode, input [5:0] entry);
        begin
            ecfg(e, 4'h0, frac); ecfg(e, 4'h1, div[7:0]); ecfg(e, 4'h2, div[15:8]);
            ecfg(e, 4'h3, p0); ecfg(e, 4'h4, p1); ecfg(e, 4'h5, p2);
            ecfg(e, 4'h6, {2'd0, wb}); ecfg(e, 4'h7, {2'd0, wt}); ecfg(e, 4'h8, 8'h00);
            ecfg(e, 4'h9, mode); ecfg(e, 4'hF, {2'd0, entry});
        end
    endtask

    // ---------------- UART models (115200 baud)
    real BIT = 8680.556;
    reg [7:0] mon;
    task uart_mon(output [7:0] b);
        integer k;
        begin
            @(negedge line[0]); #(BIT * 1.5);
            for (k = 0; k < 8; k = k + 1) begin b[k] = line[0]; #(BIT); end
            if (line[0] !== 1'b1) b = 8'hxx;      // stop bit must be high
        end
    endtask
    task uart_send(input [7:0] b, input real bitns);
        integer k;
        begin
            tb_utx = 0; #(bitns);
            for (k = 0; k < 8; k = k + 1) begin tb_utx = b[k]; #(bitns); end
            tb_utx = 1; #(bitns * 2);
        end
    endtask

    // ---------------- SPI slave model (mode 0, MSB first)
    reg [7:0] s_rx [0:3];
    reg [7:0] s_tx [0:3];
    reg [7:0] s_sh;
    integer s_bits = 0;
    always @(posedge line[2]) begin
        s_sh = {s_sh[6:0], line[3]};
        s_bits = s_bits + 1;
        if (s_bits % 8 == 0) s_rx[s_bits / 8 - 1] = s_sh;
    end
    always @(negedge line[2]) s_miso = s_tx[(s_bits / 8) % 4][7 - (s_bits % 8)];

    // ---------------- I2C slave model: ACKs byte 0, NACKs byte 1, stretches the clock
    reg [7:0] i_rx [0:3];
    reg [7:0] i_sh;
    integer i_bit = 0, i_n = 0, i_stretches = 0;
    reg i_active = 0, i_stop = 0;
    always @(negedge sda) if (scl) begin i_active = 1; i_bit = 0; end
    always @(posedge sda) if (scl && i_active) begin i_active = 0; i_stop = 1; end
    always @(posedge scl) if (i_active) begin
        if (i_bit < 8) begin i_sh = {i_sh[6:0], sda}; i_bit = i_bit + 1; end
        else begin i_rx[i_n] = i_sh; i_n = i_n + 1; i_bit = 9; end
    end
    always @(negedge scl) if (i_active) begin
        if (i_bit == 8) begin
            sl_sda_low = (i_n == 0);             // ACK the first byte only
            sl_scl_low = 1; i_stretches = i_stretches + 1;
            #3000 sl_scl_low = 0;                // hold SCL low: clock stretching
        end else if (i_bit == 9) begin sl_sda_low = 0; i_bit = 0; end
    end

    // ---------------- NRZI / bit stuffing / CRC-16 reference
    real NB = 240.0;                             // 12 clocks per bit
    function [15:0] crc_step(input [15:0] c, input b);
        crc_step = {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h8005 : 16'h0000);
    endfunction
    reg [31:0] n_bits;
    integer n_stuffed;
    task nrzi_decode(input integer nb);          // decode what the engine drives on pin 7
        integer got, ones;
        reg prev, cur, b, skip;
        begin
            got = 0; ones = 0; skip = 0; n_stuffed = 0; n_bits = 0;
            @(line[7]); #(NB / 2); prev = line[7];
            while (got < nb) begin
                #(NB); cur = line[7]; b = ~(cur ^ prev); prev = cur;
                if (skip) begin skip = 0; n_stuffed = n_stuffed + 1; end
                else begin
                    n_bits = {n_bits[30:0], b}; got = got + 1;
                    ones = b ? ones + 1 : 0;
                    if (ones == 6) begin skip = 1; ones = 0; end
                end
            end
        end
    endtask
    task nrzi_send(input [15:0] d, input integer nb);
        integer k, ones;
        begin
            ones = 0;
            tb_nrzi = ~tb_nrzi; #(NB);           // sync transition
            for (k = nb - 1; k >= 0; k = k - 1) begin
                if (!d[k]) tb_nrzi = ~tb_nrzi;
                #(NB);
                ones = d[k] ? ones + 1 : 0;
                if (ones == 6) begin tb_nrzi = ~tb_nrzi; #(NB); ones = 0; end
            end
        end
    endtask

    reg [7:0] q, q2;
    reg [15:0] cref;
    integer k;
    // constrained-random regression (fixed seed, so every run is identical)
    integer seed = 32'h5EA0_2027, it, bad, ne;
    reg [7:0] rb [0:3];
    reg [7:0] rt [0:3];
    real err;
    initial begin
        s_tx[0] = 8'hC5; s_tx[1] = 8'h3A; s_tx[2] = 8'h00; s_tx[3] = 8'h00; s_miso = 1;
        #100 rst_n = 1; #200;

        // ===== host port
        wr(7'h02, 8'hA5); rd(7'h02, q);
        check(q === 8'hA5, "host register write/read");
        check(uo_out[7:2] === 6'b100101, "flags visible on uo_out");

        // ===== UART: engine 0 transmits on pin 0, engine 1 receives on pin 1
        pm_clear;
        // uart_tx: 5 words at 0
        pm[0] = 16'h9940;
        pm[1] = 16'hd247;
        pm[2] = 16'h6001;
        pm[3] = 16'h0082;
        pm[4] = 16'hba82;
        // uart_rx: 6 words at 8
        pm[8] = 16'h200c;
        pm[9] = 16'hc247;
        pm[10] = 16'h4001;
        pm[11] = 16'h008a;
        pm[12] = 16'h8000;
        pm[13] = 16'h0008;
        pm_load;
        wr(7'h07, 8'h01);
        esetup(0, 16'd217, 8'd3, 8'h00, 8'h00, 8'h00, 6'd0, 6'd4, 8'h02, 6'd0);
        esetup(1, 16'd217, 8'd3, 8'h01, 8'h00, 8'h00, 6'd0, 6'd63, 8'h01, 6'd8);
        wr(7'h00, 8'h03);
        fork uart_mon(mon); ecfg(0, 4'hD, 8'h55); join
        check(mon === 8'h55, "UART TX 0x55 at 115200 baud");
        fork uart_mon(mon); ecfg(0, 4'hD, 8'hA3); join
        check(mon === 8'hA3, "UART TX 0xA3 at 115200 baud");
        #(BIT * 2);
        erd(1, 4'hD, q); erd(1, 4'hD, q2);
        check(q === 8'h55 && q2 === 8'hA3, "UART RX loopback 0x55 0xA3");
        urx_sel = 1; #1000;
        uart_send(8'h3C, BIT); uart_send(8'hE1, BIT * 0.97); uart_send(8'h18, BIT * 1.03);
        erd(1, 4'hD, q); check(q === 8'h3C, "UART RX external 0x3C");
        erd(1, 4'hD, q); check(q === 8'hE1, "UART RX 3 percent fast");
        erd(1, 4'hD, q); check(q === 8'h18, "UART RX 3 percent slow");
        erd(1, 4'hE, q); check(q[3] === 1'b1, "UART RX FIFO empty after reads");
        // random bytes, each at a random baud error within +/-3 percent
        bad = 0;
        for (it = 0; it < 40; it = it + 1) begin
            rb[0] = $random(seed);
            err = 1.0 + (($random(seed) % 31) / 1000.0);
            uart_send(rb[0], BIT * err);
            erd(1, 4'hD, q);
            if (q !== rb[0]) bad = bad + 1;
        end
        check(bad == 0, "UART RX 40 random bytes, random baud");

        // ===== SPI master: engine 2, SCK pin 2, MOSI pin 3, MISO pin 4
        pm_clear;
        // spi_master: 2 words at 0
        pm[0] = 16'h7001;
        pm[1] = 16'h5801;
        pm_load;
        wr(7'h08, 8'hFB); wr(7'h07, 8'h0C);
        s_bits = 0;                              // ignore power-up edges on the idle pin
        esetup(2, 16'd5, 8'd0, 8'h1C, 8'h10, 8'h00, 6'd0, 6'd1, 8'h0C, 6'd0);
        wr(7'h00, 8'h04);
        ecfg(2, 4'hD, 8'h9E); ecfg(2, 4'hD, 8'h71);
        #20000;
        check(s_rx[0] === 8'h9E && s_rx[1] === 8'h71, "SPI MOSI bytes 0x9E 0x71");
        erd(2, 4'hD, q); erd(2, 4'hD, q2);
        check(q === 8'hC5 && q2 === 8'h3A, "SPI MISO bytes 0xC5 0x3A");
        check(s_bits == 16 && line[2] === 1'b0, "SPI 16 clocks, SCK idles low");
        // random full-duplex bursts: 4 random bytes each way, back to back
        bad = 0;
        for (it = 0; it < 12; it = it + 1) begin
            for (ne = 0; ne < 4; ne = ne + 1) begin rb[ne] = $random(seed); rt[ne] = $random(seed); s_tx[ne] = rt[ne]; end
            s_bits = 0; s_miso = rt[0][7];
            for (ne = 0; ne < 4; ne = ne + 1) ecfg(2, 4'hD, rb[ne]);
            #14000;
            for (ne = 0; ne < 4; ne = ne + 1) begin
                erd(2, 4'hD, q);
                if (s_rx[ne] !== rb[ne] || q !== rt[ne]) bad = bad + 1;
            end
        end
        check(bad == 0, "SPI 48 random bytes each way");

        // ===== I2C master: engine 3, open-drain SDA pin 5, SCL pin 6
        pm_clear;
        // i2c_master: 18 words at 0
        pm[0] = 16'h8140;
        pm[1] = 16'ha047;
        pm[2] = 16'hc200;
        pm[3] = 16'h9140;
        pm[4] = 16'hc087;
        pm[5] = 16'h7001;
        pm[6] = 16'h3930;
        pm[7] = 16'ha082;
        pm[8] = 16'h1105;
        pm[9] = 16'hd001;
        pm[10] = 16'h3930;
        pm[11] = 16'h4001;
        pm[12] = 16'h9000;
        pm[13] = 16'h1083;
        pm[14] = 16'hd000;
        pm[15] = 16'hba82;
        pm[16] = 16'hc201;
        pm[17] = 16'h0000;
        pm_load;
        wr(7'h08, 8'hFF); wr(7'h06, 8'h60); wr(7'h07, 8'h60);
        esetup(3, 16'd25, 8'd0, 8'h2D, 8'h35, 8'h08, 6'd0, 6'd63, 8'h00, 6'd0);
        wr(7'h00, 8'h08);
        ecfg(3, 4'hD, 8'h01); ecfg(3, 4'hD, 8'hA6); ecfg(3, 4'hD, 8'h5D);
        #120000;
        check(i_n == 2 && i_rx[0] === 8'hA6 && i_rx[1] === 8'h5D, "I2C bytes 0xA6 0x5D");
        erd(3, 4'hD, q); erd(3, 4'hD, q2);
        check(q === 8'h00 && q2 === 8'h01, "I2C ACK then NACK captured");
        check(i_stretches == 2 && i_stop === 1'b1, "I2C clock stretch and STOP");
        check(sda === 1'b1 && scl === 1'b1, "I2C bus released");

        // ===== NRZI + bit stuffing + CRC-16: engine 0 transmits, engine 1 receives, pin 7
        pm_clear;
        // nrzi_tx: 22 words at 0
        pm[0] = 16'h8140;
        pm[1] = 16'ha047;
        pm[2] = 16'h60c8;
        pm[3] = 16'ha1d3;
        pm[4] = 16'hc1c6;
        pm[5] = 16'h21b8;
        pm[6] = 16'hc580;
        pm[7] = 16'h6141;
        pm[8] = 16'h018b;
        pm[9] = 16'h0087;
        pm[10] = 16'h000f;
        pm[11] = 16'ha082;
        pm[12] = 16'hc180;
        pm[13] = 16'ha082;
        pm[14] = 16'h0087;
        pm[15] = 16'hc1c0;
        pm[16] = 16'ha144;
        pm[17] = 16'h8040;
        pm[18] = 16'ha145;
        pm[19] = 16'h8040;
        pm[20] = 16'hc108;
        pm[21] = 16'h0000;
        // nrzi_rx: 21 words at 32
        pm[32] = 16'h8140;
        pm[33] = 16'ha047;
        pm[34] = 16'ha1d3;
        pm[35] = 16'hc1c5;
        pm[36] = 16'h21fc;
        pm[37] = 16'h4761;
        pm[38] = 16'h4141;
        pm[39] = 16'h01aa;
        pm[40] = 16'h00a6;
        pm[41] = 16'h002e;
        pm[42] = 16'ha082;
        pm[43] = 16'h4161;
        pm[44] = 16'ha082;
        pm[45] = 16'h00a6;
        pm[46] = 16'hc1c0;
        pm[47] = 16'ha144;
        pm[48] = 16'h8040;
        pm[49] = 16'ha145;
        pm[50] = 16'h8040;
        pm[51] = 16'hc109;
        pm[52] = 16'h0020;
        pm_load;
        wr(7'h06, 8'h00); wr(7'h08, 8'hFF); wr(7'h07, 8'h80);
        esetup(0, 16'd4, 8'd0, 8'h38, 8'h00, 8'h00, 6'd0, 6'd63, 8'h08, 6'd0);
        ecfg(0, 4'hA, 8'hF6); ecfg(0, 4'hB, 8'h05); ecfg(0, 4'hC, 8'h80);
        wr(7'h00, 8'h01);
        ecfg(0, 4'hD, 8'd31);
        #2000;
        ecfg(0, 4'hD, 8'hFF); ecfg(0, 4'hD, 8'hFF); ecfg(0, 4'hD, 8'h7E); ecfg(0, 4'hD, 8'h81);
        fork nrzi_decode(32); wr(7'h02, 8'h80); join
        check(n_bits === 32'hFFFF7E81, "NRZI TX data decoded by reference");
        check(n_stuffed == 3, "NRZI TX inserted 3 stuffed bits");
        #3000;
        cref = 16'hFFFF;
        for (k = 31; k >= 0; k = k - 1) cref = crc_step(cref, n_bits[k]);
        erd(0, 4'hD, q); erd(0, 4'hD, q2);
        check({q2, q} === cref, "CRC-16 of TX matches reference");
        rd(7'h02, q); check(q[0] === 1'b1, "TX done flag raised");

        nrzi_sel = 1; wr(7'h07, 8'h00);
        esetup(1, 16'd4, 8'd0, 8'h07, 8'h00, 8'h00, 6'd0, 6'd63, 8'h24, 6'd32);
        ecfg(1, 4'hA, 8'hF6); ecfg(1, 4'hB, 8'h05); ecfg(1, 4'hC, 8'h80);
        wr(7'h00, 8'h02);
        ecfg(1, 4'hD, 8'd15);
        #2000;
        nrzi_send(16'hFF7E, 16);
        #3000;
        cref = 16'hFFFF;
        for (k = 15; k >= 0; k = k - 1) cref = crc_step(cref, (16'hFF7E >> k) & 1'b1);
        erd(1, 4'hD, q); erd(1, 4'hD, q2);
        check(q === 8'hFF && q2 === 8'h7E, "NRZI RX destuffed 0xFF 0x7E");
        erd(1, 4'hD, q); erd(1, 4'hD, q2);
        check({q2, q} === cref, "CRC-16 of RX matches reference");
        rd(7'h01, q); check(q === 8'h00, "no FIFO overruns, no IRQs");

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d of %0d checks FAILED", fails, checks);
        $finish;
    end
    initial begin #20000000; $display("FAIL timeout"); $finish; end
endmodule

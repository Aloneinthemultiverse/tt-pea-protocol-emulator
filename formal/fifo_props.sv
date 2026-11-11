// Formal properties for pea_fifo (4-deep). Inputs are unconstrained.
module fifo_props (input wire clk, input wire push, input wire pop, input wire [7:0] din);
    reg rst_n = 0;
    reg ok = 0;                                 // one full clock after reset released
    always @(posedge clk) begin rst_n <= 1; ok <= rst_n; end
    wire [7:0] dout; wire full, empty;
    pea_fifo dut (.clk(clk), .rst_n(rst_n), .push(push), .din(din), .pop(pop),
                  .dout(dout), .full(full), .empty(empty));
    wire [2:0] count = dut.wp - dut.rp;
    always @* if (ok) begin
        assert (count <= 3'd4);                  // never overflows or underflows
        assert (full  == (count == 3'd4));
        assert (empty == (count == 3'd0));
        assert (!(full && empty));
        if (empty) assert (dout == 8'h00);
    end
    // data integrity: track one arbitrary byte through the queue
    (* anyconst *) reg [7:0] tag;
    (* anyseq *)   reg       pick;
    reg        tracking = 0, seen = 0;
    reg  [2:0] ahead = 0;                        // entries in front of the tracked byte
    always @(posedge clk) if (rst_n) begin
        if (!tracking && !seen && pick && push && !full && din == tag) begin
            tracking <= 1; ahead <= count - ((pop && !empty) ? 3'd1 : 3'd0);
        end else if (tracking && pop && !empty) begin
            if (ahead == 0) begin tracking <= 0; seen <= 1; end
            else ahead <= ahead - 3'd1;
        end
    end
    always @* if (ok && tracking) begin
        assert (ahead < count);
        assert (dut.mem[dut.rp[1:0] + ahead[1:0]] == tag);
        if (ahead == 0) assert (dout == tag);    // comes out unchanged and in order
    end
    always @* if (ok) cover (seen);
endmodule

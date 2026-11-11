// Formal properties for pea_fetch_arb. `need` is unconstrained; `hold` may not stay high forever.
module arb_props (input wire clk, input wire [3:0] need, input wire hold);
    reg rst_n = 0;
    reg ok = 0;                                 // one full clock after reset released
    always @(posedge clk) begin rst_n <= 1; ok <= rst_n; end
    wire [1:0] gsel; wire gany;
    pea_fetch_arb dut (.clk(clk), .rst_n(rst_n), .need(need), .hold(hold), .gsel(gsel), .gany(gany));
    always @* if (ok) begin
        assert (gany == |need);                  // work-conserving
        if (gany) assert (need[gsel]);           // only grants a requester
    end
    // starvation freedom: an engine that keeps requesting is granted within 4 effective grants
    genvar n;
    generate for (n = 0; n < 4; n = n + 1) begin : fair
        reg [2:0] waits = 0;
        always @(posedge clk)
            if (!rst_n || !need[n] || (gany && gsel == n && !hold)) waits <= 0;
            else if (gany && !hold) waits <= waits + 3'd1;
        wire [1:0] dist = n[1:0] - dut.rr;     // grants still ahead of engine n
        always @* if (ok) begin
            assert (waits <= 3'd3);
            if (waits != 0) assert (waits + {1'b0, dist} <= 3'd3);   // inductive strengthening
        end
    end endgenerate
endmodule

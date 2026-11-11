// Harness: `need` and `hold` unconstrained. Properties live in pea_fetch_arb (`ifdef FORMAL).
module arb_props (input wire clk, input wire [3:0] need, input wire hold);
    reg rst_n = 0;
    always @(posedge clk) rst_n <= 1;
    wire [1:0] gsel; wire gany;
    pea_fetch_arb dut (.clk(clk), .rst_n(rst_n), .need(need), .hold(hold), .gsel(gsel), .gany(gany));
endmodule

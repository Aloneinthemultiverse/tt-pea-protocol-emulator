// Harness: free inputs, reset held for the first clock. Properties live in pea_fifo (`ifdef FORMAL).
module fifo_props (input wire clk, input wire push, input wire pop, input wire [7:0] din);
    reg rst_n = 0;
    always @(posedge clk) rst_n <= 1;
    always @* if (!rst_n) assume (!push && !pop);
    wire [7:0] dout; wire full, empty;
    pea_fifo dut (.clk(clk), .rst_n(rst_n), .push(push), .din(din), .pop(pop),
                  .dout(dout), .full(full), .empty(empty));
endmodule

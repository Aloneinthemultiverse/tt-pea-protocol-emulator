// Tiny Tapeout wrapper for the PEA protocol emulator (IHP sg13cmos5l, 8x4 tiles).
// ui_in[0] SPI SCLK, ui_in[1] SPI CSn, ui_in[2] SPI MOSI; uo_out[0] SPI MISO, uo_out[1] IRQ,
// uo_out[7:2] flags 0-5 (trigger outputs); uio[7:0] the eight protocol pins.
`default_nettype none
module tt_um_auralis_pea (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    wire [7:0] flags;
    wire       miso, irq;
    pea_core u_core (
        .clk(clk), .rst_n(rst_n),
        .spi_sclk(ui_in[0]), .spi_csn(ui_in[1]), .spi_mosi(ui_in[2]), .spi_miso(miso), .irq_o(irq),
        .pin_i(uio_in), .pin_o(uio_out), .pin_oe(uio_oe), .flags_o(flags)
    );
    assign uo_out = {flags[5:0], irq, miso};
    wire _unused = &{ena, ui_in[7:3], flags[7:6], 1'b0};
endmodule
`default_nettype wire

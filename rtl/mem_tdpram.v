// =============================================================================
// mem_tdpram.v  —  True Dual-Port RAM (plain register inference)
// =============================================================================
// Port A (clka, 100 MHz): read+write — for the renderer's RMW pattern.
//   READ_FIRST behavior: douta reflects the value before any write this cycle.
// Port B (clkb, 25 MHz): read-only — for VGA scanout.
//
// ADDR_WIDTH must equal $clog2(DEPTH); set manually to avoid $clog2 in the
// parameter list (Vivado 2018 sometimes mishandles that).
// =============================================================================

`timescale 1ns / 1ps

module mem_tdpram #(
    parameter integer WIDTH      = 32,
    parameter integer DEPTH      = 9600,
    parameter integer ADDR_WIDTH = 14    // must equal $clog2(DEPTH)
)(
    input  wire                    clka,
    input  wire                    rst,
    input  wire                    wea,
    input  wire [ADDR_WIDTH-1:0]   addra,
    input  wire [WIDTH-1:0]        dina,
    output reg  [WIDTH-1:0]        douta,

    input  wire                    clkb,
    input  wire [ADDR_WIDTH-1:0]   addrb,
    output reg  [WIDTH-1:0]        doutb
);

    (* ram_style = "block" *) reg [WIDTH-1:0] ram [0:DEPTH-1];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1)
            ram[init_i] = {WIDTH{1'b0}};
        douta = {WIDTH{1'b0}};
        doutb  = {WIDTH{1'b0}};
    end

    // Port A: read+write, READ_FIRST
    always @(posedge clka) begin
        if (rst) begin
            douta <= {WIDTH{1'b0}};
        end else begin
            if (wea) ram[addra] <= dina;
            douta <= ram[addra];
        end
    end

    // Port B: read only
    always @(posedge clkb) begin
        doutb <= ram[addrb];
    end

endmodule

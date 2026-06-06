// =============================================================================
// mem_sdpram.v  —  Simple Dual-Port RAM (plain register inference)
// =============================================================================

`timescale 1ns / 1ps

module mem_sdpram #(
    parameter integer WIDTH          = 16,
    parameter integer DEPTH          = 1024,
    parameter integer CLOCKING_MODE  = 0,
    parameter         MEMORY_INIT_FILE = "",
    parameter integer ADDR_WIDTH     = 10  // must equal $clog2(DEPTH); set manually
)(
    input  wire                    clk,
    input  wire                    clkb,
    input  wire                    rst,

    input  wire                    wea,
    input  wire [ADDR_WIDTH-1:0]   addra,
    input  wire [WIDTH-1:0]        dina,

    input  wire [ADDR_WIDTH-1:0]   addrb,
    output reg  [WIDTH-1:0]        doutb
);

    (* ram_style = "block" *) reg [WIDTH-1:0] ram [0:DEPTH-1];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1)
            ram[init_i] = {WIDTH{1'b0}};
        if (MEMORY_INIT_FILE != "")
            $readmemh(MEMORY_INIT_FILE, ram);
        doutb = {WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        if (wea) ram[addra] <= dina;
    end

    generate
        if (CLOCKING_MODE == 1) begin : gen_indep_clk
            always @(posedge clkb) begin
                if (rst) doutb <= {WIDTH{1'b0}};
                else     doutb <= ram[addrb];
            end
        end else begin : gen_common_clk
            always @(posedge clk) begin
                if (rst) doutb <= {WIDTH{1'b0}};
                else     doutb <= ram[addrb];
            end
        end
    endgenerate

endmodule

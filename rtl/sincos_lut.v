// =============================================================================
// sincos_lut.v  —  Combinational fp16 sine/cosine lookup
// =============================================================================

`timescale 1ns / 1ps
module sincos_lut (
    input  wire [7:0]  angle,
    output wire [15:0] sin_val,
    output wire [15:0] cos_val
);

    reg [15:0] sin_rom [0:255];
    reg [15:0] cos_rom [0:255];

    initial begin
        $readmemh("sin_lut.mem", sin_rom);
        $readmemh("cos_lut.mem", cos_rom);
    end

    assign sin_val = sin_rom[angle];
    assign cos_val = cos_rom[angle];

endmodule

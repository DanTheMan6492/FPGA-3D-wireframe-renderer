// =============================================================================
// sincos_lut.v  —  Combinational fp16 sine/cosine lookup
// =============================================================================

module sincos_lut (
    input  wire [7:0]  angle,
    output wire [15:0] sin_val,
    output wire [15:0] cos_val
);

    reg [15:0] sin_rom [0:255];
    reg [15:0] cos_rom [0:255];

    initial begin
        $readmemh("data/sin_lut.hex", sin_rom);
        $readmemh("data/cos_lut.hex", cos_rom);
    end

    assign sin_val = sin_rom[angle];
    assign cos_val = cos_rom[angle];

endmodule
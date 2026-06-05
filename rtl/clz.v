// =============================================================================
// clz.v  —  Count Leading Zeros (parameterized width)
// =============================================================================
// Combinational priority encoder. Given an input `value` of width WIDTH,
// `count` is the number of leading zero bits before the first 1.
//
//   value = 0001_0000   -> count = 3
//   value = 1000_0000   -> count = 0
//   value = 0000_0001   -> count = 7
//   value = 0000_0000   -> count = WIDTH (and `all_zero` is asserted)
//
// The output width is $clog2(WIDTH+1), just enough to represent the WIDTH
// case (all-zero input). For WIDTH=12 the count fits in 4 bits.
//
// Implementation: scan from LSB upward; every time a 1 is seen, overwrite
// `count` with the corresponding leading-zero value. The last 1 encountered
// is the MSB, so its value wins — which is exactly the leading-zero count.
// =============================================================================

`timescale 1ns / 1ps
module clz #(
    parameter WIDTH = 16
)(
    input  wire [WIDTH-1:0]            value,
    output reg  [$clog2(WIDTH+1)-1:0]  count,
    output wire                        all_zero
);

    localparam CW = $clog2(WIDTH + 1);

    assign all_zero = (value == {WIDTH{1'b0}});

    integer i;
    always @(*) begin
        count = WIDTH[CW-1:0];           // default for all-zero: WIDTH
        for (i = 0; i < WIDTH; i = i + 1) begin
            if (value[i])
                count = (WIDTH - 1 - i); // last 1 (= MSB) wins -> leading zeros
        end
    end

endmodule

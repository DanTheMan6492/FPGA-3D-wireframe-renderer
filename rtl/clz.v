// =============================================================================
// clz.v  —  Count Leading Zeros (parameterized width)
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

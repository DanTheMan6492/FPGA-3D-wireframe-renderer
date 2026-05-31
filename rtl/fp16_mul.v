module fp16_mul (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [15:0] result
);

    wire        sign_a = a[15];
    wire        sign_b = b[15];
    wire [4:0]  exp_a  = a[14:10];
    wire [4:0]  exp_b  = b[14:10];
    wire [9:0]  man_a  = a[9:0];
    wire [9:0]  man_b  = b[9:0];

    // Zero detection (treat denormals as zero — FTZ)
    wire a_is_zero = (exp_a == 5'd0);
    wire b_is_zero = (exp_b == 5'd0);
    wire any_zero  = a_is_zero | b_is_zero;

    // Infinity detection (exp == 31, mantissa == 0)
    wire a_is_inf  = (exp_a == 5'd31) && (man_a == 10'd0);
    wire b_is_inf  = (exp_b == 5'd31) && (man_b == 10'd0);
    wire any_inf   = a_is_inf | b_is_inf;

    // Mantissa multiply: include implicit leading 1, multiply 11x11 = 22 bits
    wire [10:0] full_a  = {1'b1, man_a};
    wire [10:0] full_b  = {1'b1, man_b};
    wire [21:0] product = full_a * full_b;


    // The product's leading 1 sits at either bit 21 or bit 20.
    //   - bit 21 set: result is in [2.0, 4.0). Shift right by 1, exp += 1.
    //   - bit 21 clear, bit 20 set: result is in [1.0, 2.0). No shift, exp += 0.
    wire        msb_at_21 = product[21];


    wire [9:0]  mantissa_raw = msb_at_21 ? product[20:11] : product[19:10];
    wire        guard        = msb_at_21 ? product[10]    : product[9];
    wire        round_bit    = msb_at_21 ? product[9]     : product[8];
    wire        sticky       = msb_at_21 ? |product[8:0]  : |product[7:0]; // |logical or of all other bits

    // Round-to-nearest-even decision
    wire round_up = guard && (round_bit || sticky || mantissa_raw[0]);

    // Apply rounding. Use 11 bits to catch mantissa overflow (e.g. 0x3FF -> 0x400).
    wire [10:0] mantissa_rounded = {1'b0, mantissa_raw} + {10'b0, round_up};

    // Post-rounding overflow: if mantissa_rounded[10] is set, the mantissa
    // overflowed (was 0x3FF, became 0x400). Shift right by 1 and bump exp.
    wire        round_overflow = mantissa_rounded[10];
    wire [9:0]  mantissa_out   = round_overflow ? mantissa_rounded[10:1]
                                                : mantissa_rounded[9:0];

    // Exponent: a + b - bias, plus 1 if the product's leading 1 was at bit 21,
    // plus another 1 if rounding caused the mantissa to overflow.
    //
    // bias = 15. Worst case: 30 + 30 - 15 + 1 + 1 = 47. Fits in 8 bits signed
    // with margin for the negative underflow values too.
    wire signed [7:0] exp_sum = $signed({3'b0, exp_a}) + $signed({3'b0, exp_b})
                              - 8'sd15
                              + (msb_at_21     ? 8'sd1 : 8'sd0)
                              + (round_overflow ? 8'sd1 : 8'sd0);

    // Special-case classification
    wire overflow  = (exp_sum > 8'sd30);
    wire underflow = (exp_sum < 8'sd1);

    // -------------------------------------------------------------------------
    // Final assembly
    //   - either operand zero -> +0
    //   - either operand infinity -> signed infinity
    //   - overflow -> signed infinity
    //   - underflow -> flush to zero
    //   - otherwise normal result
    // -------------------------------------------------------------------------
    wire sign_out = sign_a ^ sign_b;

    assign result =
        any_zero  ? 16'b0                            :
        any_inf   ? {sign_out, 5'd31, 10'd0}         :
        overflow  ? {sign_out, 5'd31, 10'd0}         :
        underflow ? 16'b0                            :
                    {sign_out, exp_sum[4:0], mantissa_out};

endmodule
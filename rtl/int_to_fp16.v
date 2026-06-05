// =============================================================================
// int_to_fp16.v  —  Combinational signed-8-bit integer to fp16 converter
// =============================================================================
// Converts an 8-bit signed integer (range -128 to 127) to its fp16
// representation. All 8-bit signed integers are exactly representable in
// fp16 (the 10-bit mantissa easily covers 8-bit precision), so no rounding
// is needed.
//
// Algorithm:
//   - Special-case zero -> +0
//   - Take absolute value into a 9-bit intermediate (so -128 -> 128 without
//     overflow; +int8 stays unchanged, -int8 negates)
//   - Find the MSB position via clz (which leading zero count gives us)
//   - Exponent = bias (15) + (MSB position relative to bit 0)
//   - Mantissa = bits below the MSB, left-justified into the 10-bit field
// =============================================================================


`timescale 1ns / 1ps
module int_to_fp16 (
    input  wire signed [7:0]  int_in,
    output wire        [15:0] fp16_out
);

    // -------------------------------------------------------------------------
    // Absolute value in 9 bits. Negating -128 in 8 bits overflows to -128
    // again; widening to 9 bits before negating gives the correct +128.
    // -------------------------------------------------------------------------
    wire        sign = int_in[7];
    wire [8:0]  abs_val = sign ? (9'sd0 - $signed({{1{int_in[7]}}, int_in}))
                               : {1'b0, int_in};

    // -------------------------------------------------------------------------
    // Find MSB position via clz. abs_val is 9 bits, max value 128 (= 1<<7).
    //   clz output range: 0..9 (9 if all zero).
    //   MSB position from LSB = (9 - 1) - clz_count = 8 - clz_count.
    // -------------------------------------------------------------------------
    wire [3:0] lz;
    wire       is_zero;
    clz #(.WIDTH(9)) u_clz (.value(abs_val), .count(lz), .all_zero(is_zero));

    wire [3:0] msb_pos = 4'd8 - lz;  // 0..8

    // -------------------------------------------------------------------------
    // Exponent: bias + msb_pos
    // -------------------------------------------------------------------------
    wire [4:0] exp_out = 5'd15 + {1'b0, msb_pos};

    // -------------------------------------------------------------------------
    // Mantissa: drop the leading 1 (at msb_pos) and left-justify the
    // remaining bits into the 10-bit mantissa field.
    //
    // The remaining bits are at positions [msb_pos-1 : 0] of abs_val
    // (msb_pos bits total). We left-shift abs_val so the leading 1 sits at
    // bit 9 (one past the mantissa MSB), then take bits [9:0]... no, wait:
    // we want bits [msb_pos-1:0] in the top of mantissa[9:0], so we
    // left-shift by (10 - msb_pos).
    //
    // Cleaner formulation: shift abs_val left into a 19-bit register so the
    // leading 1 is always at the same position, then index out the 10
    // bits below it.
    //
    // Easiest implementation: shift_amount = 10 - msb_pos.
    //   When msb_pos = 0 (abs_val = 1), shift_amount = 10. Mantissa = 0.
    //   When msb_pos = 7 (abs_val = 128), shift_amount = 3. abs_val << 3 =
    //     0b100000000000, take bits [9:0] = 0.
    //   When msb_pos = 3 (abs_val = 8..15), shift_amount = 7.
    //     abs_val = 0b1101 -> << 7 = 0b110_100000000, mantissa = 0x600.
    // -------------------------------------------------------------------------
    wire [3:0]  shift_amount = 4'd10 - msb_pos;
    wire [18:0] shifted = {10'b0, abs_val} << shift_amount;
    wire [9:0]  mantissa = shifted[9:0];

    // -------------------------------------------------------------------------
    // Final assembly
    // -------------------------------------------------------------------------
    assign fp16_out = is_zero ? 16'b0
                              : {sign, exp_out, mantissa};

endmodule

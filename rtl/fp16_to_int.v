// =============================================================================
// fp16_to_int.v  —  Combinational fp16 to signed integer converter
// =============================================================================

`timescale 1ns / 1ps
module fp16_to_int #(
    parameter WIDTH = 12
)(
    input  wire        [15:0]      fp16_in,
    output wire signed [WIDTH-1:0] int_out
);

    // -------------------------------------------------------------------------
    // Decode
    // -------------------------------------------------------------------------
    wire        sign = fp16_in[15];
    wire [4:0]  exp_in = fp16_in[14:10];
    wire [9:0]  man_in = fp16_in[9:0];

    wire is_zero_or_denorm = (exp_in == 5'd0);
    wire is_inf            = (exp_in == 5'd31) && (man_in == 10'd0);

    // Significand with implicit leading 1, 11 bits total
    wire [10:0] sig = {1'b1, man_in};

    // Unbiased exponent. Range: -14 .. 16 for normal numbers. (We treat exp=0
    // as zero per FTZ; exp=31 is infinity, handled as a special case below.)
    wire signed [5:0] e_true = $signed({1'b0, exp_in}) - 6'sd15;

    // -------------------------------------------------------------------------
    // Shift the significand to position the integer part at the LSB.
    //   if e_true >= 10: shift left  by (e_true - 10)
    //   if e_true <  10: shift right by (10 - e_true)  (truncates fraction)
    //   if e_true <   0: result magnitude is 0
    //
    // The widest intermediate we need: significand is 11 bits, max left-shift
    // is when e_true = 16 (largest fp16 normal exponent), giving 11 + 6 = 17
    // bits for the absolute magnitude. We size the intermediate to WIDTH+1
    // for sign and saturate logic.
    // -------------------------------------------------------------------------
    localparam IW = (WIDTH > 17) ? WIDTH + 1 : 18;   // intermediate width

    reg [IW-1:0] mag;
    always @(*) begin
        if (is_zero_or_denorm) begin
            mag = {IW{1'b0}};
        end else if (e_true < 0) begin
            mag = {IW{1'b0}};   // |value| < 1
        end else if (e_true >= 6'sd10) begin
            mag = {{(IW-11){1'b0}}, sig} << (e_true - 6'sd10);
        end else begin
            mag = {{(IW-11){1'b0}}, sig} >> (6'sd10 - e_true);
        end
    end

    // -------------------------------------------------------------------------
    // Saturation thresholds.
    //   Positive max in WIDTH-bit signed: 2^(WIDTH-1) - 1
    //   Negative min in WIDTH-bit signed: -2^(WIDTH-1)
    //
    // We saturate before applying sign. Note the asymmetry: positive
    // saturates one earlier than negative does, so we treat the positive
    // case strictly and clamp the negative case at -2^(WIDTH-1).
    // -------------------------------------------------------------------------
    localparam [IW-1:0] POS_MAX = (1 <<< (WIDTH - 1)) - 1;
    localparam [IW-1:0] NEG_MAG_MAX = (1 <<< (WIDTH - 1));   // |min int|

    wire pos_overflow = !sign && (is_inf || (mag > POS_MAX));
    wire neg_overflow =  sign && (is_inf || (mag > NEG_MAG_MAX));

    // -------------------------------------------------------------------------
    // Compose output. For negative inputs, two's-complement negate the
    // truncated magnitude.
    // -------------------------------------------------------------------------
    wire signed [WIDTH-1:0] pos_max_const = (1 <<< (WIDTH - 1)) - 1;
    wire signed [WIDTH-1:0] neg_min_const = -(1 <<< (WIDTH - 1));

    assign int_out =
        pos_overflow ? pos_max_const :
        neg_overflow ? neg_min_const :
        sign         ? (-$signed(mag[WIDTH-1:0])) :
                       $signed(mag[WIDTH-1:0]);

endmodule

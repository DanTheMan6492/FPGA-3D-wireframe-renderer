
module fp16_add (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [15:0] result
);

    // Decode + FTZ
    wire        a_denorm = (a[14:10] == 5'd0) && (a[9:0] != 10'd0);
    wire        b_denorm = (b[14:10] == 5'd0) && (b[9:0] != 10'd0);
    wire [15:0] a_eff    = a_denorm ? {a[15], 15'd0} : a;
    wire [15:0] b_eff    = b_denorm ? {b[15], 15'd0} : b;

    wire        sign_a = a_eff[15];
    wire        sign_b = b_eff[15];
    wire [4:0]  exp_a  = a_eff[14:10];
    wire [4:0]  exp_b  = b_eff[14:10];
    wire [9:0]  man_a  = a_eff[9:0];
    wire [9:0]  man_b  = b_eff[9:0];

    wire a_is_zero = (exp_a == 5'd0) && (man_a == 10'd0);
    wire b_is_zero = (exp_b == 5'd0) && (man_b == 10'd0);
    wire a_is_inf  = (exp_a == 5'd31) && (man_a == 10'd0);
    wire b_is_inf  = (exp_b == 5'd31) && (man_b == 10'd0);

    // Implicit leading 1 (or 0 for exact zero).
    wire [10:0] full_a = {!a_is_zero, man_a};
    wire [10:0] full_b = {!b_is_zero, man_b};

    // Pick the larger-magnitude operand as "big"
    wire a_bigger = (exp_a > exp_b) ||
                    ((exp_a == exp_b) && (full_a >= full_b));

    wire        sign_big   = a_bigger ? sign_a : sign_b;
    wire        sign_small = a_bigger ? sign_b : sign_a;
    wire [4:0]  exp_big    = a_bigger ? exp_a  : exp_b;
    wire [4:0]  exp_small  = a_bigger ? exp_b  : exp_a;
    wire [10:0] full_big   = a_bigger ? full_a : full_b;
    wire [10:0] full_small = a_bigger ? full_b : full_a;

    // Align "small" to "big" by right-shifting its mantissa.
    wire [4:0]  exp_diff = exp_big - exp_small;

    wire [13:0] big_aligned   = {1'b0, full_big,   1'b0, 1'b0};

    // Build small_aligned + sticky from the shift.
    reg  [13:0] small_aligned;
    reg         sticky;
    integer     k;
    reg  [13:0] small_pre;
    always @(*) begin
        small_pre = {1'b0, full_small, 1'b0, 1'b0};
        if (exp_diff >= 5'd14) begin
            // Entire value shifts past the datapath. Sticky reflects whether
            // the operand was nonzero at all.
            small_aligned = 14'd0;
            sticky        = (full_small != 11'd0);
        end else begin
            small_aligned = small_pre >> exp_diff;
            // Sticky: OR of the bits that fell off. That's the low exp_diff
            // bits of small_pre.
            sticky = 1'b0;
            for (k = 0; k < 14; k = k + 1)
                if (k < exp_diff) sticky = sticky | small_pre[k];
        end
    end

    // -------------------------------------------------------------------------
    // Effective add or subtract (on magnitudes).
    //   signs match -> ADD; result sign = sign_big.
    //   signs differ -> SUBTRACT (big - small); result sign = sign_big.
    //
    // sum_raw is 14 bits: { possible-carry, 11 mantissa, G, R }.
    // For subtract, we tuck the sticky into the subtraction by treating the
    // sticky as if it sits one bit below R (it determines whether the result
    // would be slightly larger had we kept more bits) — we handle this by
    // subtracting 1 from the borrow side if sticky is set and we're
    // subtracting. The classical way: include sticky as the low bit of the
    // subtrahend, in a widened compare. Below we keep things simple by doing
    // the subtraction and adjusting sticky's interpretation after.
    // -------------------------------------------------------------------------
    wire effective_sub = (sign_a ^ sign_b);

    reg [13:0] sum_raw;
    reg        sum_sticky;
    always @(*) begin
        if (!effective_sub) begin
            sum_raw    = big_aligned + small_aligned;
            sum_sticky = sticky;
        end else begin
            // big >= small in magnitude (by construction), so this is safe.
            //
            // Correct sticky handling for effective subtract:
            // If sticky is set, the *true* small operand has additional bits
            // below R that we discarded. The true small is therefore slightly
            // LARGER than small_aligned, and the true difference (big - small)
            // is slightly SMALLER than (big_aligned - small_aligned).
            //
            // The standard fix: subtract one extra unit (1 in the R position
            // = bit 0 of the 14-bit datapath) when sticky is set, and invert
            // the sticky polarity afterwards (because the "leftover bits" now
            // represent how much MORE we should round DOWN, instead of up).
            if (sticky) begin
                sum_raw    = big_aligned - small_aligned - 14'd1;
                sum_sticky = 1'b1;   // any residual makes round-down inexact
            end else begin
                sum_raw    = big_aligned - small_aligned;
                sum_sticky = 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Normalize.
    //
    // ADD case:
    //   sum_raw[13] = 1 (carry out)  -> mantissa is in [2.0, 4.0).
    //                                   Right-shift 1; exp += 1.
    //   sum_raw[13] = 0              -> mantissa already in [1.0, 2.0).
    //                                   No shift.
    //
    // SUB case:
    //   sum_raw[13] is always 0 (no carry out from subtract). The leading 1
    //   may be anywhere from bit 12 down to bit 0 (catastrophic cancellation).
    //   We use clz to count leading zeros above the implicit-leading-1
    //   position (bit 12), and left-shift by that amount. exp -= shift.
    //
    // After normalization we want bits arranged as:
    //   {leading_1, 10 mantissa, G, R}     (13 bits)
    //   with all bits beyond R folded into sticky.
    // -------------------------------------------------------------------------
    wire carry_out = sum_raw[13];

    // CLZ over the low 13 bits of sum_raw (the post-carry range). If carry
    // is set we skip CLZ and shift right instead.
    wire [12:0] sum_lo = sum_raw[12:0];
    wire [3:0]  lz;
    wire        sum_lo_zero;
    clz #(.WIDTH(13)) u_clz (.value(sum_lo), .count(lz), .all_zero(sum_lo_zero));

    // Outputs of normalization
    reg [11:0] mantissa_grm;     // {leading_1, 10 mantissa, G} = 12 bits
                                 // (R is handled separately because the
                                 // left-shift on subtract pulls it up)
    reg        round_bit;
    reg        norm_sticky;
    reg signed [7:0] exp_norm;   // exponent after normalization, pre-rounding
    reg        result_zero;
    reg [12:0] shifted;          // SUB-path left-shifted sum

    always @(*) begin
        result_zero = 1'b0;
        shifted     = 13'd0;
        if (!effective_sub) begin
            // ADD path
            if (carry_out) begin
                // {1, 10 mantissa, G, R} = sum_raw[13:1], drop bit 0 into S
                mantissa_grm = sum_raw[13:2];     // 12 bits, top is the new leading 1
                round_bit    = sum_raw[1];
                norm_sticky  = sum_sticky | sum_raw[0];
                exp_norm     = $signed({3'b0, exp_big}) + 8'sd1;
            end else begin
                // {1, 10 mantissa, G, R} = sum_raw[12:1], drop nothing extra
                mantissa_grm = sum_raw[12:1];
                round_bit    = sum_raw[0];
                norm_sticky  = sum_sticky;
                exp_norm     = $signed({3'b0, exp_big});
            end
        end else begin
            // SUB path
            if (sum_lo_zero) begin
                // Exact cancellation -> +0.
                mantissa_grm = 12'd0;
                round_bit    = 1'b0;
                norm_sticky  = 1'b0;
                exp_norm     = 8'sd0;
                result_zero  = 1'b1;
            end else begin
                // Left-shift by lz so the leading 1 ends up at bit 12.
                shifted      = sum_lo << lz;
                mantissa_grm = shifted[12:1];
                round_bit    = shifted[0];
                norm_sticky  = sum_sticky;
                exp_norm     = $signed({3'b0, exp_big}) - $signed({4'b0, lz});
            end
        end
    end

    // -------------------------------------------------------------------------
    // Round-to-nearest-even on mantissa_grm using G (the LSB of mantissa_grm
    // is actually... no, wait — let me reread. mantissa_grm is {1, 10
    // mantissa, G} where G is bit 0. So the 10-bit kept mantissa is
    // mantissa_grm[10:1], and G = mantissa_grm[0]. R = round_bit. S = norm_sticky.
    // -------------------------------------------------------------------------
    wire        guard          = mantissa_grm[0];
    wire [9:0]  kept_mantissa  = mantissa_grm[10:1];
    wire        round_up       = guard && (round_bit || norm_sticky || kept_mantissa[0]);

    wire [10:0] mantissa_rounded = {1'b0, kept_mantissa} + {10'b0, round_up};
    wire        round_overflow   = mantissa_rounded[10];

    wire [9:0]  mantissa_final = round_overflow ? mantissa_rounded[10:1]
                                                : mantissa_rounded[9:0];
    wire signed [7:0] exp_final = exp_norm + (round_overflow ? 8'sd1 : 8'sd0);

    // -------------------------------------------------------------------------
    // Special-case mux and final assembly.
    // -------------------------------------------------------------------------
    wire both_zero  = a_is_zero && b_is_zero;

    // Inf handling: inf + finite = inf (same sign as the inf operand). inf +
    // inf same sign = inf; opposite signs would be NaN per IEEE, but we
    // declared NaN unsupported — output +0 as a fallback (this shouldn't
    // occur in a well-behaved graphics pipeline).
    wire inf_path        = a_is_inf || b_is_inf;
    wire inf_opp_sign    = a_is_inf && b_is_inf && (sign_a != sign_b);
    wire        sign_inf = a_is_inf ? sign_a : sign_b;

    // a + 0 = a, 0 + b = b — falls out of the normal path naturally because
    // exp_big/full_big already reflect the nonzero operand. So no special-
    // case is needed for "one is zero" unless we want to short-circuit.

    wire overflow_final  = (exp_final > 8'sd30);
    wire underflow_final = (exp_final < 8'sd1);

    assign result =
        inf_opp_sign ? 16'b0                                          :
        inf_path     ? {sign_inf, 5'd31, 10'd0}                       :
        both_zero    ? 16'b0                                          :
        result_zero  ? 16'b0                                          :
        overflow_final  ? {sign_big, 5'd31, 10'd0}                    :
        underflow_final ? 16'b0                                       :
                          {sign_big, exp_final[4:0], mantissa_final};

endmodule
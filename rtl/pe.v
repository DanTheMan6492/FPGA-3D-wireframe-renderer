// =============================================================================
// pe.v  -  Processing Element for the mat_mul systolic array (pipelined)
// =============================================================================
// Two-stage pipelined MAC to meet 100 MHz timing:
//
//   Cycle N:   prod_reg <= fp16_mul(a_in, b_in)   [registered multiply]
//   Cycle N+1: c_out    <= c_out + prod_reg        [registered accumulate]
//
// Splitting the multiply and accumulate into separate register stages halves
// the combinational depth compared to the single-cycle version, bringing the
// worst-case path from ~30 ns down to ~15 ns.
//
// Timing impact on the systolic array:
//   The last input pair enters the array at feed_t = M-1. The product is
//   registered one cycle later, and the accumulation one cycle after that.
//   mat_mul's feed_len is therefore M + 2*MAX_DIM + 1 (one extra cycle for
//   the multiply pipeline register draining through the array).
//
// Pass-through behaviour is unchanged: a_out and b_out are still registered
// copies of a_in and b_in, maintaining the one-cycle-per-PE skew.
//
// en / clear semantics:
//   en    - gates the ACCUMULATE stage.  When low, prod_reg still advances
//           (the multiply always runs) but the result is not added to c_out.
//   clear - zeroes BOTH prod_reg and c_out synchronously to prevent stale
//           products leaking into the next matrix multiply.
// =============================================================================

`timescale 1ns / 1ps

module pe (
    input  wire        clk,
    input  wire        en,        // accumulate enable
    input  wire        clear,     // synchronous clear of pipeline + accumulator

    input  wire [15:0] a_in,
    input  wire [15:0] b_in,

    output reg  [15:0] a_out,
    output reg  [15:0] b_out,
    output reg  [15:0] c_out
);

    // ---- Stage 1: multiply --------------------------------------------------
    wire [15:0] prod_comb;

    fp16_mul u_mul (
        .a      (a_in),
        .b      (b_in),
        .result (prod_comb)
    );

    reg [15:0] prod_reg;   // registered multiply result

    // ---- Stage 2: accumulate ------------------------------------------------
    wire [15:0] c_next;

    fp16_add u_add (
        .a      (c_out),
        .b      (prod_reg),
        .result (c_next)
    );

    // ---- Registers ----------------------------------------------------------
    always @(posedge clk) begin
        // Pipeline stage 1 - multiply result register.
        // Always advances (even when en=0) so the pipeline stays coherent.
        // Cleared to prevent stale data polluting the next accumulation.
        if (clear)
            prod_reg <= 16'b0;
        else
            prod_reg <= prod_comb;

        // Pipeline stage 2 - accumulator.
        if (clear)
            c_out <= 16'b0;
        else if (en)
            c_out <= c_next;
        // else: hold

        // Pass-throughs (unchanged - one-cycle-per-PE skew)
        a_out <= a_in;
        b_out <= b_in;
    end

endmodule
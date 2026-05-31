// =============================================================================
// pe.v  —  Processing Element for the mat_mul systolic array
// =============================================================================
// A single multiply-accumulate cell. Each cycle it multiplies its two inputs,
// adds the product into an internal accumulator, and forwards both inputs to
// its neighbours (registered, so data advances exactly one PE per clock).
//
//   - a_in  : value from the left neighbour
//   - b_in  : value from the top  neighbour
//   - a_out : registered copy of a_in, drives the right  neighbour
//   - b_out : registered copy of b_in, drives the bottom neighbour
//   - c_out : the accumulator, read out after the multiply completes
//
// The registered a_out / b_out are what create the one-cycle-per-PE skew that
// makes the systolic array work. They are NOT optional.
// =============================================================================

module pe (
    input  wire        clk,
    input  wire        en,        // accumulate enable: when high, c += a*b
    input  wire        clear,     // synchronous: zero the accumulator

    input  wire [15:0] a_in,      // from left neighbour
    input  wire [15:0] b_in,      // from top  neighbour

    output reg  [15:0] a_out,     // to right  neighbour (registered)
    output reg  [15:0] b_out,     // to bottom neighbour (registered)
    output reg  [15:0] c_out      // accumulator value, for readout
);

    // -------------------------------------------------------------------------
    // Combinational multiply-accumulate path.
    //   prod   = a_in * b_in
    //   c_next = c_out + prod
    // Both fp16_mul and fp16_add are combinational modules and must be
    // instantiated, not called like functions.
    // -------------------------------------------------------------------------
    wire [15:0] prod;
    wire [15:0] c_next;

    fp16_mul u_mul (
        .a      (a_in),
        .b      (b_in),
        .result (prod)
    );

    fp16_add u_add (
        .a      (c_out),
        .b      (prod),
        .result (c_next)
    );

    // -------------------------------------------------------------------------
    // Registers, all updated on the rising clock edge:
    //   - c_out : accumulator. Cleared, held, or accumulated.
    //   - a_out : registered pass-through of a_in  -> right neighbour
    //   - b_out : registered pass-through of b_in  -> bottom neighbour
    //
    // The pass-throughs always advance (they are the data movement of the
    // array). Only the accumulator is gated by `clear` and `en`.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        // Accumulator
        if (clear)
            c_out <= 16'b0;       // fp16 zero
        else if (en)
            c_out <= c_next;      // c += a*b
        // else: hold current value

        // Pass-throughs: always shift data onward, one PE per cycle
        a_out <= a_in;
        b_out <= b_in;
    end

endmodule
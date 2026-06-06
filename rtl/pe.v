// =============================================================================
// pe.v  -  Processing Element for the mat_mul systolic array (pipelined)
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

        // Pass-throughs
        a_out <= a_in;
        b_out <= b_in;
    end

endmodule
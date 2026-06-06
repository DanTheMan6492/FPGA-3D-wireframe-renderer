// =============================================================================
// debouncer.v  —  Push-button debouncer (clean level output)
// =============================================================================

`timescale 1ns / 1ps
module debouncer #(
    // Number of consecutive stable clocks required before the output follows
    // the input. ~10 ms at 100 MHz by default.
    parameter COUNT_MAX = 1000000
)(
    input  wire clk,
    input  wire btn_in,      // raw, asynchronous, bouncy button input
    output reg  btn_out      // debounced clean level
);

    localparam CW = $clog2(COUNT_MAX);

    // -------------------------------------------------------------------------
    // Stage 1: two-flop synchronizer (metastability guard).
    // -------------------------------------------------------------------------
    reg sync_0 = 1'b0;
    reg sync_1 = 1'b0;
    always @(posedge clk) begin
        sync_0 <= btn_in;
        sync_1 <= sync_0;
    end

    // -------------------------------------------------------------------------
    // Stage 2: integrator. Count consecutive clocks where the synchronized
    // input disagrees with the current output; flip the output once it has
    // disagreed for COUNT_MAX clocks. Any earlier agreement resets the count.
    // -------------------------------------------------------------------------
    reg [CW-1:0] count = 0;
    initial btn_out = 1'b0;

    always @(posedge clk) begin
        if (sync_1 == btn_out) begin
            count <= 0;                       // input matches output: nothing pending
        end else if (count == COUNT_MAX-1) begin
            btn_out <= sync_1;                // stable for the full window: accept it
            count   <= 0;
        end else begin
            count <= count + 1'b1;            // counting toward a stable change
        end
    end

endmodule

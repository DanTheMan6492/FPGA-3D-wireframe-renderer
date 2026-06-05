// =============================================================================
// debouncer.v  —  Push-button debouncer (clean level output)
// =============================================================================
// One of these is instantiated per direction button (up/down/left/right) at the
// top level, as described in docs/top_level.md. Mechanical buttons "bounce" —
// the contact chatters open/closed for a few milliseconds on each press and
// release. This module filters that chatter and produces a clean, stable level
// on `btn_out`. The top level then does its own rising-edge detection on
// `btn_out` to bump the speed_x / speed_y registers, so this module deliberately
// emits a LEVEL, not an edge pulse.
//
// Two stages:
//   1. A two-flop synchronizer brings the asynchronous button signal into the
//      clk domain, guarding downstream logic against metastability.
//   2. An integrator: `btn_out` only changes once the synchronized input has
//      held the opposite value for COUNT_MAX consecutive clocks. Any bounce or
//      glitch shorter than that window resets the counter and is ignored.
//
// At 100 MHz the default COUNT_MAX = 1,000,000 gives a ~10 ms stable window,
// comfortably longer than typical button bounce. The testbench overrides
// COUNT_MAX to a small value so the debounce window is only a few clocks.
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

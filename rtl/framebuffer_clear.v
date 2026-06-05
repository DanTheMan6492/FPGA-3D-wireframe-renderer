// =============================================================================
// framebuffer_clear.v  —  Walks the framebuffer, writing zero to every word
// =============================================================================
// On `start`, asserts busy and writes 32'b0 to each of the 9,600 framebuffer
// words (640 * 480 / 32). One word per cycle, so the clear completes in
// 9,600 cycles — well under the 144,000-cycle vblank window.
//
// The top level muxes this module's fb_* outputs with wireframe_gen's onto
// the back-buffer's write port. RENDER is gated on !busy, so the two never
// write concurrently.
// =============================================================================

`timescale 1ns / 1ps
module framebuffer_clear (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    output reg  [13:0] fb_addr,
    output reg  [31:0] fb_din,
    output reg         fb_wen,

    output reg         busy
);

    localparam [13:0] LAST_WORD = 14'd9599;

    initial begin
        fb_addr = 14'd0;
        fb_din  = 32'd0;
        fb_wen  = 1'b0;
        busy    = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            fb_wen  <= 1'b0;
            fb_addr <= 14'd0;
        end else if (!busy) begin
            // Idle. On start, begin walking from word 0.
            fb_din <= 32'd0;
            if (start) begin
                busy    <= 1'b1;
                fb_addr <= 14'd0;
                fb_wen  <= 1'b1;
            end else begin
                fb_wen <= 1'b0;
            end
        end else begin
            // Walking. Write the current word, then advance — unless we're
            // at the last word, in which case finish.
            if (fb_addr == LAST_WORD) begin
                busy   <= 1'b0;
                fb_wen <= 1'b0;
            end else begin
                fb_addr <= fb_addr + 14'd1;
                fb_wen  <= 1'b1;
            end
        end
    end

endmodule

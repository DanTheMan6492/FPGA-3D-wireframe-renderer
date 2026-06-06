// =============================================================================
// framebuffer_clear.v  —  Walks the framebuffer, writing zero to every word
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

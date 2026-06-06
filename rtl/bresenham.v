// =============================================================================
// bresenham.v  —  Single-line drawer using Bresenham's algorithm
// =============================================================================

`timescale 1ns / 1ps
module bresenham (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    input  wire [9:0]  x0, y0,
    input  wire [9:0]  x1, y1,

    output reg  [13:0] fb_addr,
    output reg  [31:0] fb_din,
    input  wire [31:0] fb_dout,
    output reg         fb_wen,

    output reg         done
);

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam IDLE  = 3'd0;
    localparam READ  = 3'd1;
    localparam WAIT  = 3'd2;   // absorb 1-cycle SDPRAM read latency
    localparam MOD   = 3'd3;
    localparam WRITE = 3'd4;
    localparam DONE  = 3'd5;
    reg [2:0] state;

    reg signed [10:0] x, y;
    reg        [9:0]  x_end, y_end;       // latched endpoints
    reg        [10:0] dx, dy;             // |x1-x0|, |y1-y0|
    reg signed [1:0]  sx, sy;             // +1 or -1
    reg signed [12:0] err;                // error term, signed, generous width

    reg [13:0] word_q;       // word address being read-modified-written
    reg [4:0]  bit_q;        // which bit of that word


    wire [18:0] bit_index = (y[9:0] * 11'd640) + x[9:0];
    wire [13:0] cur_word  = bit_index[18:5];
    wire [4:0]  cur_bit   = bit_index[4:0];
    wire        at_end    = (x[9:0] == x_end) && (y[9:0] == y_end);

    wire signed [13:0] e2 = err <<< 1;
    wire signed [13:0] neg_dy = -$signed({3'b0, dy});
    wire signed [13:0] pos_dx =  $signed({3'b0, dx});

    wire step_x = (e2 > neg_dy);
    wire step_y = (e2 < pos_dx);

    wire signed [10:0] next_x = step_x ? (x + sx) : x;
    wire signed [10:0] next_y = step_y ? (y + sy) : y;
    wire signed [12:0] next_err =
        err - (step_x ? $signed({3'b0, dy}) : 13'sd0)
            + (step_y ? $signed({3'b0, dx}) : 13'sd0);

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state  <= IDLE;
            done   <= 1'b0;
            fb_wen <= 1'b0;
        end else begin
            done   <= 1'b0;
            fb_wen <= 1'b0;

            case (state)

            // -----------------------------------------------------------------
            // IDLE — wait for start; latch endpoints + Bresenham setup.
            // -----------------------------------------------------------------
            IDLE: if (start) begin
                x     <= $signed({1'b0, x0});
                y     <= $signed({1'b0, y0});
                x_end <= x1;
                y_end <= y1;

                if (x1 > x0) begin dx <= x1 - x0; sx <=  2'sd1; end
                else         begin dx <= x0 - x1; sx <= -2'sd1; end
                if (y1 > y0) begin dy <= y1 - y0; sy <=  2'sd1; end
                else         begin dy <= y0 - y1; sy <= -2'sd1; end

                // err = dx - dy 
                err <= $signed({2'b0, (x1 > x0 ? x1 - x0 : x0 - x1)})
                     - $signed({2'b0, (y1 > y0 ? y1 - y0 : y0 - y1)});

                state <= READ;
            end

            // -----------------------------------------------------------------
            // READ — present the current pixel's word address.
            // -----------------------------------------------------------------
            READ: begin
                fb_addr <= cur_word;
                word_q  <= cur_word;
                bit_q   <= cur_bit;
                state   <= WAIT;
            end

            // -----------------------------------------------------------------
            // WAIT — fb_dout will reflect word_q starting next cycle. Idle.
            // -----------------------------------------------------------------
            WAIT: begin
                state <= MOD;
            end

            // -----------------------------------------------------------------
            // MOD — fb_dout reflects the word we read in READ. OR in the bit.
            // -----------------------------------------------------------------
            MOD: begin
                fb_din <= fb_dout | (32'b1 << bit_q);
                state  <= WRITE;
            end

            // -----------------------------------------------------------------
            // WRITE — commit. Then either step Bresenham and loop back to
            // READ, or finish if the pixel we just committed was the endpoint.
            // -----------------------------------------------------------------
            WRITE: begin
                fb_addr <= word_q;
                fb_wen  <= 1'b1;

                if (at_end) begin
                    state <= DONE;
                end else begin
                    // Advance to the next pixel using the Bresenham step we
                    // computed combinationally from the current state.
                    x   <= next_x;
                    y   <= next_y;
                    err <= next_err;
                    state <= READ;
                end
            end

            // -----------------------------------------------------------------
            // DONE — one-cycle done pulse.
            // -----------------------------------------------------------------
            DONE: begin
                done  <= 1'b1;
                state <= IDLE;
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule

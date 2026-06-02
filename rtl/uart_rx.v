// =============================================================================
// uart_rx.v  —  UART receiver (8N1), one byte at a time
// =============================================================================
// Receives bytes from the host PC over the serial line, as described in
// docs/top_level.md ("uart_rx — receives one byte at a time from the host PC").
// This module ONLY deserializes the wire into bytes; the packet interpreter
// (vertex_count, face_count, vertex bytes, face-index bytes -> shadow_mem, then
// new_data_flag) lives inline at the top level and consumes this byte stream.
//
// Frame format: 8N1 — one start bit (0), 8 data bits LSB-first, one stop bit
// (1). The line idles high. Each fully received byte is presented on `data`
// with `valid` pulsing high for exactly one clock.
//
// CLKS_PER_BIT = clk frequency / baud rate. For the Basys 3's 100 MHz clock at
// 115200 baud that is 100_000_000 / 115_200 ~= 868. The testbench overrides it
// to a small value so a bit lasts only a handful of clocks.
//
// Robustness:
//   * A two-flop synchronizer brings the asynchronous rx line into the clk
//     domain (metastability guard).
//   * The start bit is re-checked at its midpoint; if the line has returned
//     high by then the edge was a glitch and the receiver returns to idle.
//   * Every data bit is sampled at its midpoint, where it is most stable.
// =============================================================================

module uart_rx #(
    parameter CLKS_PER_BIT = 868
)(
    input  wire       clk,
    input  wire       rst,       // synchronous reset -> IDLE
    input  wire       rx,        // serial input, idles high
    output reg  [7:0] data,      // last received byte (held until next byte)
    output reg        valid      // one-clock strobe when `data` is fresh
);

    localparam CW = $clog2(CLKS_PER_BIT);   // wide enough for 0 .. CLKS_PER_BIT-1

    localparam IDLE    = 3'd0;
    localparam START   = 3'd1;
    localparam DATA    = 3'd2;
    localparam STOP    = 3'd3;
    localparam CLEANUP = 3'd4;

    reg [2:0]    state = IDLE;
    reg [CW-1:0] clk_count = 0;     // clocks elapsed within the current bit
    reg [2:0]    bit_index = 0;     // which data bit (0..7)

    // -------------------------------------------------------------------------
    // Two-flop synchronizer. Reset/init to 1 because the idle line is high.
    // -------------------------------------------------------------------------
    reg rx_d1 = 1'b1;
    reg rx_d2 = 1'b1;
    always @(posedge clk) begin
        rx_d1 <= rx;
        rx_d2 <= rx_d1;
    end

    // -------------------------------------------------------------------------
    // Receive FSM
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            clk_count <= 0;
            bit_index <= 0;
            valid     <= 1'b0;
        end else begin
            case (state)
                // Wait for the falling edge that begins a start bit.
                IDLE: begin
                    valid     <= 1'b0;
                    clk_count <= 0;
                    bit_index <= 0;
                    if (rx_d2 == 1'b0)
                        state <= START;
                end

                // Re-sample at the middle of the start bit to reject glitches.
                START: begin
                    if (clk_count == (CLKS_PER_BIT-1)/2) begin
                        if (rx_d2 == 1'b0) begin
                            clk_count <= 0;     // realign to bit centers
                            state     <= DATA;
                        end else begin
                            state <= IDLE;      // glitch: not a real start bit
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                // Sample each data bit at its midpoint, LSB first.
                DATA: begin
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count       <= 0;
                        data[bit_index] <= rx_d2;
                        if (bit_index < 3'd7) begin
                            bit_index <= bit_index + 1'b1;
                        end else begin
                            bit_index <= 0;
                            state     <= STOP;
                        end
                    end
                end

                // Ride out the stop bit, then strobe valid.
                STOP: begin
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        valid     <= 1'b1;
                        clk_count <= 0;
                        state     <= CLEANUP;
                    end
                end

                // One-cycle valid pulse, then back to idle.
                CLEANUP: begin
                    valid <= 1'b0;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

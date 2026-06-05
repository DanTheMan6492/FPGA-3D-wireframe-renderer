// =============================================================================
// uart_rx_tb.v  —  Testbench for the 8N1 UART receiver
// =============================================================================
// Drives the serial line at the correct per-bit timing and checks that:
//   * an idle (high) line produces no bytes,
//   * clean frames deserialize to the right value (LSB first), including the
//     0x00 and 0xFF extremes,
//   * a short glitch on the line is rejected (no spurious byte),
//   * a realistic mesh-upload packet header streams out byte-for-byte in order
//     (vertex_count, face_count, then vertex coord bytes, then face indices) —
//     mirroring the shadow_mem byte layout the top level expects.
//
// CLK_FREQ and BAUD_RATE are overridden to tiny values so each bit lasts only
// a few clocks in simulation.
//
// Run:
//   iverilog -g2012 -o build/uart_rx_tb rtl/uart_rx.v tb/uart_rx_tb.v
//   vvp build/uart_rx_tb
// =============================================================================

`timescale 1ns / 1ps

module uart_rx_tb;

    localparam CLK_FREQ     = 16;        // } together give CLKS_PER_BIT = 16
    localparam BAUD_RATE    = 1;         // }
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // used for repeat() timing

    reg        clk;
    reg        rst;
    reg        rx;
    wire [7:0] data;
    wire       valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) dut (
        .clk   (clk),
        .rst   (rst),
        .rx    (rx),
        .data  (data),
        .valid (valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors;

    // Monitor: latch every received byte and count them.
    reg  [7:0] last_data;
    integer    rx_count;
    always @(posedge clk) begin
        if (valid) begin
            last_data <= data;
            rx_count  <= rx_count + 1;
        end
    end

    // Drive one 8N1 frame: start bit, 8 data bits LSB-first, stop bit.
    task send_byte;
        input [7:0] b;
        integer i;
        begin
            rx = 1'b0;                                  // start bit
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i];                              // data bits, LSB first
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            rx = 1'b1;                                  // stop bit
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    // Send a byte and confirm exactly one byte popped out with the right value.
    task check_byte;
        input [7:0]   b;
        input [255:0] label;
        integer       prev_count;
        begin
            prev_count = rx_count;
            send_byte(b);
            repeat (CLKS_PER_BIT) @(posedge clk);       // let valid/CLEANUP land
            if (rx_count === prev_count + 1 && last_data === b)
                $display("  ok   %0s  (got %h)", label, last_data);
            else begin
                $display("  FAIL %0s  (got %h x%0d, expected %h x1)",
                         label, last_data, rx_count - prev_count, b);
                errors = errors + 1;
            end
        end
    endtask

    integer j;

    // A small mesh-upload header to stream through, in shadow_mem byte order.
    // vertex_count=2, face_count=1, then 2*3 signed coord bytes, then 1*3 face
    // index bytes.
    reg [7:0] packet [0:10];

    initial begin
        $dumpfile("waves/uart_rx_tb.vcd");
        $dumpvars(0, uart_rx_tb);

        errors    = 0;
        rx_count  = 0;
        last_data = 8'h00;
        rx        = 1'b1;          // idle high
        rst       = 1'b1;
        repeat (4) @(posedge clk);
        rst       = 1'b0;
        repeat (4) @(posedge clk);

        $display("=== uart_rx testbench start ===");

        // Idle line: no bytes should appear.
        repeat (4*CLKS_PER_BIT) @(posedge clk);
        if (rx_count === 0)
            $display("  ok   idle line produces no bytes");
        else begin
            $display("  FAIL idle line produced %0d byte(s)", rx_count);
            errors = errors + 1;
        end

        // Clean single bytes, including the extremes.
        check_byte(8'h55, "0x55 alternating");
        check_byte(8'hA3, "0xA3");
        check_byte(8'h00, "0x00 all zeros");
        check_byte(8'hFF, "0xFF all ones");
        check_byte(8'h01, "0x01 LSB only");
        check_byte(8'h80, "0x80 MSB only");

        // Short glitch (well under half a bit) must NOT be decoded as a frame.
        begin : glitch_test
            integer prev_count;
            prev_count = rx_count;
            rx = 1'b0;
            repeat (CLKS_PER_BIT/4) @(posedge clk);   // brief low blip
            rx = 1'b1;
            repeat (3*CLKS_PER_BIT) @(posedge clk);   // settle past a bit time
            if (rx_count === prev_count)
                $display("  ok   short glitch rejected");
            else begin
                $display("  FAIL short glitch produced a byte (got %h)", last_data);
                errors = errors + 1;
            end
        end

        // Realistic packet header: stream it byte-for-byte and check order.
        packet[0]  = 8'd2;        // vertex_count
        packet[1]  = 8'd1;        // face_count
        packet[2]  = 8'h0A;       // v0.x
        packet[3]  = 8'hF6;       // v0.y (-10 signed)
        packet[4]  = 8'h00;       // v0.z
        packet[5]  = 8'h10;       // v1.x
        packet[6]  = 8'h20;       // v1.y
        packet[7]  = 8'h30;       // v1.z
        packet[8]  = 8'd0;        // face0 index a
        packet[9]  = 8'd1;        // face0 index b
        packet[10] = 8'd1;        // face0 index c
        $display("  -- streaming 11-byte packet header --");
        for (j = 0; j <= 10; j = j + 1)
            check_byte(packet[j], "packet byte");

        $display("=== uart_rx testbench done ===");
        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #2000000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule

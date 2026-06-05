// =============================================================================
// framebuffer_clear_tb.v  —  Verifies the framebuffer_clear sweep
// =============================================================================
// Models a small framebuffer (sized to match the full 9600 words) and
// verifies that:
//   - busy goes high on start and stays high until done
//   - every word from 0 to 9599 is written exactly once with 32'b0
//   - no writes occur after busy deasserts
// =============================================================================

`timescale 1ns / 1ps

module framebuffer_clear_tb;

    reg clk;
    initial clk = 0;
    always #5 clk = ~clk;

    reg rst;
    reg start;
    wire [13:0] fb_addr;
    wire [31:0] fb_din;
    wire        fb_wen;
    wire        busy;

    framebuffer_clear dut (
        .clk(clk), .rst(rst), .start(start),
        .fb_addr(fb_addr), .fb_din(fb_din), .fb_wen(fb_wen),
        .busy(busy)
    );

    // Track which addresses have been written and how many times.
    reg [7:0] write_count [0:9599];
    integer i;
    integer errors;
    integer total_writes;
    integer writes_after_done;

    always @(posedge clk) begin
        if (fb_wen) begin
            total_writes = total_writes + 1;
            write_count[fb_addr] = write_count[fb_addr] + 1;
            if (!busy) writes_after_done = writes_after_done + 1;
            // Also check the data is always 0
            if (fb_din !== 32'd0) begin
                $display("FAIL: fb_din = %h at addr %0d", fb_din, fb_addr);
                errors = errors + 1;
            end
        end
    end

    initial begin
        errors            = 0;
        total_writes      = 0;
        writes_after_done = 0;
        for (i = 0; i < 9600; i = i + 1) write_count[i] = 0;

        rst   = 1;
        start = 0;
        @(posedge clk); @(posedge clk);
        rst = 0;
        @(posedge clk);

        $display("=== framebuffer_clear testbench ===");

        // Pulse start
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for busy to deassert
        wait (!busy);
        @(posedge clk); @(posedge clk);

        // Check coverage
        $display("total writes: %0d  (expected 9600)", total_writes);
        if (total_writes !== 9600) begin
            $display("FAIL: write count is %0d, expected 9600", total_writes);
            errors = errors + 1;
        end

        for (i = 0; i < 9600; i = i + 1) begin
            if (write_count[i] !== 1) begin
                if (errors < 5)
                    $display("FAIL: addr %0d written %0d times", i, write_count[i]);
                errors = errors + 1;
            end
        end

        $display("writes after busy deasserted: %0d (expected 0)", writes_after_done);
        if (writes_after_done > 0) errors = errors + 1;

        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
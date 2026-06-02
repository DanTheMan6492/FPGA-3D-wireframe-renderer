// =============================================================================
// debouncer_tb.v  —  Testbench for the push-button debouncer
// =============================================================================
// Checks that the debounced level output:
//   * stays low while idle,
//   * follows a clean press (low->high) and clean release (high->low) after the
//     debounce window,
//   * ignores a glitch shorter than the window,
//   * settles correctly after contact bounce on both the press and release.
//
// COUNT_MAX is overridden small so the debounce window is only a few clocks.
// The two-flop synchronizer adds 2 clocks of latency on top of the window, so
// a settle wait of 2 + COUNT_MAX + margin is always enough.
//
// Run:
//   iverilog -g2012 -o build/debouncer_tb rtl/debouncer.v tb/debouncer_tb.v
//   vvp build/debouncer_tb
// =============================================================================

`timescale 1ns / 1ps

module debouncer_tb;

    localparam COUNT_MAX = 8;                 // small debounce window for sim
    localparam SETTLE    = 2 + COUNT_MAX + 4; // sync (2) + window + margin

    reg  clk;
    reg  btn_in;
    wire btn_out;

    debouncer #(.COUNT_MAX(COUNT_MAX)) dut (
        .clk     (clk),
        .btn_in  (btn_in),
        .btn_out (btn_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors;

    // Advance n clocks.
    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(negedge clk);
        end
    endtask

    // Assert the current output level.
    task expect_out;
        input         val;
        input [255:0] label;
        begin
            if (btn_out === val)
                $display("  ok   %0s  (btn_out=%b)", label, btn_out);
            else begin
                $display("  FAIL %0s  (btn_out=%b expected %b)", label, btn_out, val);
                errors = errors + 1;
            end
        end
    endtask

    // Drive a quick bounce burst: toggle btn_in around `level`'s opposite a few
    // times, each phase shorter than the debounce window, ending back at the
    // burst's starting value.
    task bounce_burst;
        input start_val;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                btn_in = ~start_val; wait_cycles(2);
                btn_in =  start_val; wait_cycles(2);
            end
        end
    endtask

    initial begin
        $dumpfile("waves/debouncer_tb.vcd");
        $dumpvars(0, debouncer_tb);

        errors = 0;
        btn_in = 1'b0;
        $display("=== debouncer testbench start ===");

        // Idle low
        wait_cycles(SETTLE);
        expect_out(1'b0, "idle low");

        // Clean press
        btn_in = 1'b1;
        wait_cycles(SETTLE);
        expect_out(1'b1, "clean press registered");

        // Held press stays high
        wait_cycles(SETTLE);
        expect_out(1'b1, "held press stays high");

        // Clean release
        btn_in = 1'b0;
        wait_cycles(SETTLE);
        expect_out(1'b0, "clean release registered");

        // Short glitch (shorter than the window) is ignored
        btn_in = 1'b1;
        wait_cycles(COUNT_MAX - 2);   // high, but not long enough to latch
        btn_in = 1'b0;
        wait_cycles(SETTLE);
        expect_out(1'b0, "short glitch rejected");

        // Bounce on press, then settle high
        bounce_burst(1'b0);           // chatter while still nominally released
        btn_in = 1'b1;                // contacts finally close
        wait_cycles(SETTLE);
        expect_out(1'b1, "bouncy press settles high");

        // Bounce on release, then settle low
        bounce_burst(1'b1);           // chatter while still nominally pressed
        btn_in = 1'b0;                // contacts finally open
        wait_cycles(SETTLE);
        expect_out(1'b0, "bouncy release settles low");

        $display("=== debouncer testbench done ===");
        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #100000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule

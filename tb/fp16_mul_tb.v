// =============================================================================
// fp16_mul_tb.v  —  Testbench for the combinational fp16 multiplier
// =============================================================================
// Test cases were generated from numpy.float16 as the oracle. The DUT
// implements FTZ (flush to zero on denormals), so any reference result that
// is denormal (exponent field == 0, mantissa != 0) is normalized to zero
// before comparison.
//
// Run:
//   iverilog -o fpm_tb fp16_mul.v fp16_mul_tb.v && vvp fpm_tb
// =============================================================================

`timescale 1ns / 1ps

module fp16_mul_tb;

    reg  [15:0] a;
    reg  [15:0] b;
    wire [15:0] result;

    fp16_mul dut (.a(a), .b(b), .result(result));

    integer errors;

    // -------------------------------------------------------------------------
    // FTZ normalization of an expected reference. Any denormal (exp == 0,
    // mantissa != 0) becomes +0 for comparison purposes.
    // -------------------------------------------------------------------------
    function [15:0] ftz;
        input [15:0] x;
        begin
            if (x[14:10] == 5'd0 && x[9:0] != 10'd0) ftz = 16'd0;
            else                                     ftz = x;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Run one case and report
    // -------------------------------------------------------------------------
    task check_case;
        input [15:0]   av;
        input [15:0]   bv;
        input [15:0]   ref_expected;
        input [255:0]  label;
        reg   [15:0]   ftz_expected;
        begin
            a = av;
            b = bv;
            ftz_expected = ftz(ref_expected);
            #1;  // settle combinational
            if (result === ftz_expected) begin
                $display("  ok   %0s  (got %h, expected %h)",
                         label, result, ftz_expected);
            end else begin
                $display("  FAIL %0s  (got %h, expected %h, refRaw %h)",
                         label, result, ftz_expected, ref_expected);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Cases generated from numpy.float16. The label format is just the
    // human-readable computation as a sanity check.
    // -------------------------------------------------------------------------
    initial begin
        errors = 0;
        $display("=== fp16_mul testbench start ===");

        check_case(16'h3c00, 16'h3c00, 16'h3c00, "1.0 * 1.0 = 1.0");
        check_case(16'h4000, 16'h4200, 16'h4600, "2.0 * 3.0 = 6.0");
        check_case(16'h3e00, 16'h4100, 16'h4380, "1.5 * 2.5 = 3.75");
        check_case(16'hbc00, 16'h3c00, 16'hbc00, "-1.0 * 1.0 = -1.0");
        check_case(16'hbc00, 16'hbc00, 16'h3c00, "-1.0 * -1.0 = 1.0");
        check_case(16'h3800, 16'h3800, 16'h3400, "0.5 * 0.5 = 0.25");
        check_case(16'h3400, 16'h4400, 16'h3c00, "0.25 * 4.0 = 1.0");
        check_case(16'h5640, 16'h5640, 16'h70e2, "100 * 100 = 10000");
        check_case(16'h63d0, 16'h63d0, 16'h7c00, "1000 * 1000 = inf (overflow)");
        check_case(16'h1419, 16'h1419, 16'h0011, "tiny * tiny -> denormal (FTZ to 0)");
        check_case(16'h0000, 16'h4500, 16'h0000, "0 * 5 = 0");
        check_case(16'h4500, 16'h0000, 16'h0000, "5 * 0 = 0");
        check_case(16'hc200, 16'h4700, 16'hcd40, "-3 * 7 = -21");
        check_case(16'hc100, 16'hc400, 16'h4900, "-2.5 * -4 = 10");
        check_case(16'h3c00, 16'h3800, 16'h3800, "1 * 0.5 = 0.5");
        check_case(16'h4248, 16'h416c, 16'h4842, "3.14 * 2.71 ~= 8.51");
        check_case(16'hb000, 16'h4800, 16'hbc00, "-0.125 * 8 = -1.0");
        check_case(16'h7bef, 16'h3c00, 16'h7bef, "64992 * 1 = 64992");
        check_case(16'h2c00, 16'h4c00, 16'h3c00, "0.0625 * 16 = 1.0");
        check_case(16'h3fff, 16'h3fff, 16'h43fe, "~2 * ~2 ~= 4");

        $display("=== fp16_mul testbench done ===");
        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin #1000; $display("ERROR: timeout"); $finish; end

endmodule
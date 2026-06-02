// =============================================================================
// display_top_tb.v  —  Testbench for the four-digit seven-segment driver
// =============================================================================
// Verifies the time-multiplexed display logic over full refresh sweeps:
//   * the anode lines are always one-hot-low (exactly one digit enabled),
//   * all four digits get scanned within a sweep,
//   * the decimal point stays off,
//   * each digit shows the correct hex nibble of vertex_count / face_count,
//     mapped AN3:AN2 = vertex_count, AN1:AN0 = face_count.
//
// REFRESH_BITS is overridden small so a full sweep is only a handful of clocks.
//
// Run:
//   iverilog -g2012 -o build/display_top_tb rtl/display_top.v tb/display_top_tb.v
//   vvp build/display_top_tb
// =============================================================================

`timescale 1ns / 1ps

module display_top_tb;

    localparam REFRESH_BITS = 4;             // small -> fast sweep in sim
    localparam SWEEP        = (1 << REFRESH_BITS);

    reg        clk;
    reg  [7:0] vertex_count;
    reg  [7:0] face_count;
    wire [6:0] seg;
    wire       dp;
    wire [3:0] an;

    display_top #(.REFRESH_BITS(REFRESH_BITS)) dut (
        .clk          (clk),
        .vertex_count (vertex_count),
        .face_count   (face_count),
        .seg          (seg),
        .dp           (dp),
        .an           (an)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors;

    // -------------------------------------------------------------------------
    // Independent reference seven-segment decoder (mirrors the RTL table).
    // -------------------------------------------------------------------------
    function [6:0] ref7seg;
        input [3:0] nib;
        begin
            case (nib)
                4'h0: ref7seg = 7'h40;
                4'h1: ref7seg = 7'h79;
                4'h2: ref7seg = 7'h24;
                4'h3: ref7seg = 7'h30;
                4'h4: ref7seg = 7'h19;
                4'h5: ref7seg = 7'h12;
                4'h6: ref7seg = 7'h02;
                4'h7: ref7seg = 7'h78;
                4'h8: ref7seg = 7'h00;
                4'h9: ref7seg = 7'h10;
                4'hA: ref7seg = 7'h08;
                4'hB: ref7seg = 7'h03;
                4'hC: ref7seg = 7'h46;
                4'hD: ref7seg = 7'h21;
                4'hE: ref7seg = 7'h06;
                4'hF: ref7seg = 7'h0E;
                default: ref7seg = 7'h7F;
            endcase
        end
    endfunction

    // Active-low one-hot anode -> digit index (0..3); 8 signals "not one-hot".
    function [3:0] an_to_digit;
        input [3:0] av;
        begin
            case (av)
                4'b1110: an_to_digit = 4'd0;
                4'b1101: an_to_digit = 4'd1;
                4'b1011: an_to_digit = 4'd2;
                4'b0111: an_to_digit = 4'd3;
                default: an_to_digit = 4'd8;   // invalid / not one-hot-low
            endcase
        end
    endfunction

    // Expected nibble for a digit, given the current counts.
    function [3:0] expected_nibble;
        input [3:0] digit;
        input [7:0] vc;
        input [7:0] fc;
        begin
            case (digit)
                4'd0: expected_nibble = fc[3:0];
                4'd1: expected_nibble = fc[7:4];
                4'd2: expected_nibble = vc[3:0];
                4'd3: expected_nibble = vc[7:4];
                default: expected_nibble = 4'h0;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Drive a (vertex_count, face_count) pair, watch two full sweeps, and check
    // every sampled cycle.
    // -------------------------------------------------------------------------
    task check_counts;
        input [7:0]   vc;
        input [7:0]   fc;
        input [255:0] label;
        integer       i;
        integer       d;
        reg   [3:0]   seen_mask;          // bit d set once digit d is observed
        reg           case_ok;
        reg   [6:0]   exp_seg;
        begin
            vertex_count = vc;
            face_count   = fc;
            seen_mask    = 4'b0000;
            case_ok      = 1'b1;

            @(negedge clk);               // let combinational outputs settle

            for (i = 0; i < 2*SWEEP; i = i + 1) begin
                @(negedge clk);
                d = an_to_digit(an);
                if (d > 3) begin
                    $display("  FAIL %0s: anode not one-hot-low (an=%b)", label, an);
                    case_ok = 1'b0;
                end else begin
                    seen_mask[d[1:0]] = 1'b1;
                    if (dp !== 1'b1) begin
                        $display("  FAIL %0s: dp asserted on digit %0d", label, d);
                        case_ok = 1'b0;
                    end
                    exp_seg = ref7seg(expected_nibble(d[3:0], vc, fc));
                    if (seg !== exp_seg) begin
                        $display("  FAIL %0s: digit %0d seg=%h expected %h (nib %h)",
                                 label, d, seg, exp_seg,
                                 expected_nibble(d[3:0], vc, fc));
                        case_ok = 1'b0;
                    end
                end
            end

            if (seen_mask !== 4'b1111) begin
                $display("  FAIL %0s: not all digits scanned (mask=%b)", label, seen_mask);
                case_ok = 1'b0;
            end

            if (case_ok)
                $display("  ok   %0s  (vc=%0d fc=%0d -> %h%h %h%h)",
                         label, vc, fc, vc[7:4], vc[3:0], fc[7:4], fc[3:0]);
            else
                errors = errors + 1;
        end
    endtask

    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("waves/display_top_tb.vcd");
        $dumpvars(0, display_top_tb);

        errors = 0;
        $display("=== display_top testbench start ===");

        check_counts(8'd0,   8'd0,   "zero / zero (00 00)");
        check_counts(8'd255, 8'd255, "max / max (FF FF)");
        check_counts(8'd8,   8'd12,  "cube: 8 verts / 12 faces");
        check_counts(8'h12,  8'h34,  "0x12 / 0x34");
        check_counts(8'hAB,  8'hCD,  "0xAB / 0xCD");
        check_counts(8'hAA,  8'h55,  "0xAA / 0x55");
        check_counts(8'd1,   8'd0,   "1 / 0");
        check_counts(8'h0F,  8'hF0,  "0x0F / 0xF0");

        $display("=== display_top testbench done ===");
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

`timescale 1ns/1ps
module sincos_tb;
    reg [7:0] angle;
    wire [15:0] sin_val, cos_val;
    sincos_lut dut(.angle(angle), .sin_val(sin_val), .cos_val(cos_val));
    integer errors;

    task check_sc;
        input [7:0] a;
        input [15:0] exp_sin;
        input [15:0] exp_cos;
        input [255:0] label;
        begin
            angle = a; #1;
            if (sin_val !== exp_sin || cos_val !== exp_cos) begin
                $display("FAIL [%0s] angle=%0d: sin got=%h exp=%h, cos got=%h exp=%h", label, a, sin_val, exp_sin, cos_val, exp_cos);
                errors = errors + 1;
            end else
                $display("ok   [%0s] angle=%0d sin=%h cos=%h", label, a, sin_val, cos_val);
        end
    endtask

    initial begin
        errors = 0;
        $display("=== sincos_lut testbench ===");
    check_sc(8'd0, 16'h0000, 16'h3c00, "0 deg");
    check_sc(8'd64, 16'h3c00, 16'h0000, "90 deg");
    check_sc(8'd128, 16'h0000, 16'hbc00, "180 deg");
    check_sc(8'd192, 16'hbc00, 16'h8000, "270 deg");
    check_sc(8'd32, 16'h39a8, 16'h39a8, "45 deg");
    check_sc(8'd96, 16'h39a8, 16'hb9a8, "135 deg");
    check_sc(8'd16, 16'h361f, 16'h3b64, "22.5 deg");
    check_sc(8'd200, 16'hbbd9, 16'h323e, "281.25 deg");
        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end
    initial begin #1000; $display("TIMEOUT"); $finish; end
endmodule
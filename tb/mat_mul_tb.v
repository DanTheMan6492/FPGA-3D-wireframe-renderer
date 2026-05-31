`timescale 1ns / 1ps

module mat_mul_fp16_tb;

    localparam MAX_DIM = 4;

    reg         clk;
    reg         rst;
    reg  [7:0]  N, M, P;
    reg         write_a;
    reg  [15:0] data_a;
    reg         loaded_a;
    reg         write_b;
    reg  [15:0] data_b;
    reg         loaded_b;
    wire [15:0] data_out;
    wire        out_valid;
    wire        busy;

    mat_mul #(.MAX_DIM(MAX_DIM)) dut (
        .clk(clk), .rst(rst), .N(N), .M(M), .P(P),
        .write_a(write_a), .data_a(data_a), .loaded_a(loaded_a),
        .write_b(write_b), .data_b(data_b), .loaded_b(loaded_b),
        .data_out(data_out), .out_valid(out_valid), .busy(busy)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Per-case stimulus: caller fills A_in/B_in/C_exp and sets N_v/M_v/P_v,
    // then calls run_case(label).
    // -------------------------------------------------------------------------
    reg [15:0] A_in  [0:MAX_DIM*MAX_DIM-1];
    reg [15:0] B_in  [0:MAX_DIM*MAX_DIM-1];
    reg [15:0] C_exp [0:MAX_DIM*MAX_DIM-1];
    reg [15:0] C_got [0:MAX_DIM*MAX_DIM-1];
    integer    N_v, M_v, P_v;
    integer    got_count;
    integer    total_errors;

    function [15:0] abs_diff;
        input [15:0] x;
        input [15:0] y;
        begin
            if (x > y) abs_diff = x - y;
            else       abs_diff = y - x;
        end
    endfunction

    // Capture every out_valid element
    always @(posedge clk) begin
        if (out_valid) begin
            C_got[got_count] = data_out;
            got_count = got_count + 1;
        end
    end

    integer t;

    task run_case;
        input [255:0] label;
        integer i;
        integer a_elems, b_elems, c_elems;
        integer case_errors;
        reg [15:0] diff;
        begin
            case_errors = 0;
            a_elems = N_v * M_v;
            b_elems = M_v * P_v;
            c_elems = N_v * P_v;

            // Reset
            rst = 1;
            N = N_v[7:0]; M = M_v[7:0]; P = P_v[7:0];
            write_a = 0; data_a = 0; loaded_a = 0;
            write_b = 0; data_b = 0; loaded_b = 0;
            got_count = 0;
            @(negedge clk); @(negedge clk);
            rst = 0;
            @(negedge clk);

            // Stream A and B concurrently
            for (i = 0; i < ((a_elems > b_elems) ? a_elems : b_elems); i = i + 1) begin
                if (i < a_elems) begin write_a = 1; data_a = A_in[i]; end
                else            begin write_a = 0; data_a = 0;       end
                if (i < b_elems) begin write_b = 1; data_b = B_in[i]; end
                else            begin write_b = 0; data_b = 0;       end
                @(negedge clk);
            end
            write_a = 0; write_b = 0;
            loaded_a = 1; loaded_b = 1;
            @(negedge clk);
            loaded_a = 0; loaded_b = 0;

            // Wait for completion
            for (i = 0; i < M_v + 3*MAX_DIM + c_elems + 8; i = i + 1)
                @(negedge clk);

            // Check
            $display("-- case [%0s] (%0dx%0d * %0dx%0d) --",
                     label, N_v, M_v, M_v, P_v);
            if (got_count !== c_elems) begin
                $display("   FAIL: element count got %0d expected %0d",
                         got_count, c_elems);
                case_errors = case_errors + 1;
            end
            for (i = 0; i < c_elems; i = i + 1) begin
                diff = abs_diff(C_got[i], C_exp[i]);
                if (C_got[i] === C_exp[i]) begin
                    $display("   ok    C[%0d] = %h", i, C_got[i]);
                end else if (diff <= 16'd1) begin
                    $display("   ok~   C[%0d] = %h (expected %h, off by 1 LSB)",
                             i, C_got[i], C_exp[i]);
                end else begin
                    $display("   FAIL  C[%0d] got %h expected %h diff %0d",
                             i, C_got[i], C_exp[i], diff);
                    case_errors = case_errors + 1;
                end
            end
            if (case_errors == 0) $display("   case PASSED");
            else                  $display("   case FAILED (%0d)", case_errors);
            total_errors = total_errors + case_errors;
        end
    endtask

    initial begin
        total_errors = 0;
        $display("=== mat_mul fp16 testbench start ===");

        // 2x2 small ints: 2x2 * 2x2
        N_v=2; M_v=2; P_v=2;
        A_in[0] = 16'h3c00;   // 1.0
        A_in[1] = 16'h4000;   // 2.0
        A_in[2] = 16'h4200;   // 3.0
        A_in[3] = 16'h4400;   // 4.0
        B_in[0] = 16'h4500;   // 5.0
        B_in[1] = 16'h4600;   // 6.0
        B_in[2] = 16'h4700;   // 7.0
        B_in[3] = 16'h4800;   // 8.0
        C_exp[0] = 16'h4cc0;   // 19.0
        C_exp[1] = 16'h4d80;   // 22.0
        C_exp[2] = 16'h5160;   // 43.0
        C_exp[3] = 16'h5240;   // 50.0
        run_case("2x2 small ints");

        // 4x4 by identity: 4x4 * 4x4
        N_v=4; M_v=4; P_v=4;
        A_in[0] = 16'h3c00;   // 1.0
        A_in[1] = 16'h4000;   // 2.0
        A_in[2] = 16'h4200;   // 3.0
        A_in[3] = 16'h4400;   // 4.0
        A_in[4] = 16'h4500;   // 5.0
        A_in[5] = 16'h4600;   // 6.0
        A_in[6] = 16'h4700;   // 7.0
        A_in[7] = 16'h4800;   // 8.0
        A_in[8] = 16'h4880;   // 9.0
        A_in[9] = 16'h4900;   // 10.0
        A_in[10] = 16'h4980;   // 11.0
        A_in[11] = 16'h4a00;   // 12.0
        A_in[12] = 16'h4a80;   // 13.0
        A_in[13] = 16'h4b00;   // 14.0
        A_in[14] = 16'h4b80;   // 15.0
        A_in[15] = 16'h4c00;   // 16.0
        B_in[0] = 16'h3c00;   // 1.0
        B_in[1] = 16'h0000;   // 0.0
        B_in[2] = 16'h0000;   // 0.0
        B_in[3] = 16'h0000;   // 0.0
        B_in[4] = 16'h0000;   // 0.0
        B_in[5] = 16'h3c00;   // 1.0
        B_in[6] = 16'h0000;   // 0.0
        B_in[7] = 16'h0000;   // 0.0
        B_in[8] = 16'h0000;   // 0.0
        B_in[9] = 16'h0000;   // 0.0
        B_in[10] = 16'h3c00;   // 1.0
        B_in[11] = 16'h0000;   // 0.0
        B_in[12] = 16'h0000;   // 0.0
        B_in[13] = 16'h0000;   // 0.0
        B_in[14] = 16'h0000;   // 0.0
        B_in[15] = 16'h3c00;   // 1.0
        C_exp[0] = 16'h3c00;   // 1.0
        C_exp[1] = 16'h4000;   // 2.0
        C_exp[2] = 16'h4200;   // 3.0
        C_exp[3] = 16'h4400;   // 4.0
        C_exp[4] = 16'h4500;   // 5.0
        C_exp[5] = 16'h4600;   // 6.0
        C_exp[6] = 16'h4700;   // 7.0
        C_exp[7] = 16'h4800;   // 8.0
        C_exp[8] = 16'h4880;   // 9.0
        C_exp[9] = 16'h4900;   // 10.0
        C_exp[10] = 16'h4980;   // 11.0
        C_exp[11] = 16'h4a00;   // 12.0
        C_exp[12] = 16'h4a80;   // 13.0
        C_exp[13] = 16'h4b00;   // 14.0
        C_exp[14] = 16'h4b80;   // 15.0
        C_exp[15] = 16'h4c00;   // 16.0
        run_case("4x4 by identity");

        // 4x4 fractions: 4x4 * 4x4
        N_v=4; M_v=4; P_v=4;
        A_in[0] = 16'h3800;   // 0.5
        A_in[1] = 16'h3e00;   // 1.5
        A_in[2] = 16'h4100;   // 2.5
        A_in[3] = 16'h4300;   // 3.5
        A_in[4] = 16'h3c00;   // 1.0
        A_in[5] = 16'h4000;   // 2.0
        A_in[6] = 16'h4200;   // 3.0
        A_in[7] = 16'h4400;   // 4.0
        A_in[8] = 16'h3400;   // 0.25
        A_in[9] = 16'h3800;   // 0.5
        A_in[10] = 16'h3c00;   // 1.0
        A_in[11] = 16'h4000;   // 2.0
        A_in[12] = 16'h4000;   // 2.0
        A_in[13] = 16'h4400;   // 4.0
        A_in[14] = 16'h4600;   // 6.0
        A_in[15] = 16'h4800;   // 8.0
        B_in[0] = 16'h3c00;   // 1.0
        B_in[1] = 16'h0000;   // 0.0
        B_in[2] = 16'h0000;   // 0.0
        B_in[3] = 16'h0000;   // 0.0
        B_in[4] = 16'h0000;   // 0.0
        B_in[5] = 16'h4000;   // 2.0
        B_in[6] = 16'h0000;   // 0.0
        B_in[7] = 16'h0000;   // 0.0
        B_in[8] = 16'h0000;   // 0.0
        B_in[9] = 16'h0000;   // 0.0
        B_in[10] = 16'h3800;   // 0.5
        B_in[11] = 16'h0000;   // 0.0
        B_in[12] = 16'h0000;   // 0.0
        B_in[13] = 16'h0000;   // 0.0
        B_in[14] = 16'h0000;   // 0.0
        B_in[15] = 16'h3c00;   // 1.0
        C_exp[0] = 16'h3800;   // 0.5
        C_exp[1] = 16'h4200;   // 3.0
        C_exp[2] = 16'h3d00;   // 1.25
        C_exp[3] = 16'h4300;   // 3.5
        C_exp[4] = 16'h3c00;   // 1.0
        C_exp[5] = 16'h4400;   // 4.0
        C_exp[6] = 16'h3e00;   // 1.5
        C_exp[7] = 16'h4400;   // 4.0
        C_exp[8] = 16'h3400;   // 0.25
        C_exp[9] = 16'h3c00;   // 1.0
        C_exp[10] = 16'h3800;   // 0.5
        C_exp[11] = 16'h4000;   // 2.0
        C_exp[12] = 16'h4000;   // 2.0
        C_exp[13] = 16'h4800;   // 8.0
        C_exp[14] = 16'h4200;   // 3.0
        C_exp[15] = 16'h4800;   // 8.0
        run_case("4x4 fractions");

        // 2x3 * 3x2: 2x3 * 3x2
        N_v=2; M_v=3; P_v=2;
        A_in[0] = 16'h3c00;   // 1.0
        A_in[1] = 16'h4000;   // 2.0
        A_in[2] = 16'h4200;   // 3.0
        A_in[3] = 16'h4400;   // 4.0
        A_in[4] = 16'h4500;   // 5.0
        A_in[5] = 16'h4600;   // 6.0
        B_in[0] = 16'h4700;   // 7.0
        B_in[1] = 16'h4800;   // 8.0
        B_in[2] = 16'h4880;   // 9.0
        B_in[3] = 16'h4900;   // 10.0
        B_in[4] = 16'h4980;   // 11.0
        B_in[5] = 16'h4a00;   // 12.0
        C_exp[0] = 16'h5340;   // 58.0
        C_exp[1] = 16'h5400;   // 64.0
        C_exp[2] = 16'h5858;   // 139.0
        C_exp[3] = 16'h58d0;   // 154.0
        run_case("2x3 * 3x2");

        // 4x4 mixed signs: 4x4 * 4x4
        N_v=4; M_v=4; P_v=4;
        A_in[0] = 16'h3c00;   // 1.0
        A_in[1] = 16'hbc00;   // -1.0
        A_in[2] = 16'h4000;   // 2.0
        A_in[3] = 16'hc000;   // -2.0
        A_in[4] = 16'h4200;   // 3.0
        A_in[5] = 16'h4200;   // 3.0
        A_in[6] = 16'hc200;   // -3.0
        A_in[7] = 16'hc200;   // -3.0
        A_in[8] = 16'h3800;   // 0.5
        A_in[9] = 16'hb800;   // -0.5
        A_in[10] = 16'h3c00;   // 1.0
        A_in[11] = 16'hbc00;   // -1.0
        A_in[12] = 16'h3c00;   // 1.0
        A_in[13] = 16'h3c00;   // 1.0
        A_in[14] = 16'h3c00;   // 1.0
        A_in[15] = 16'h3c00;   // 1.0
        B_in[0] = 16'h3c00;   // 1.0
        B_in[1] = 16'h0000;   // 0.0
        B_in[2] = 16'h3c00;   // 1.0
        B_in[3] = 16'h0000;   // 0.0
        B_in[4] = 16'h0000;   // 0.0
        B_in[5] = 16'h3c00;   // 1.0
        B_in[6] = 16'h0000;   // 0.0
        B_in[7] = 16'h3c00;   // 1.0
        B_in[8] = 16'h3c00;   // 1.0
        B_in[9] = 16'h3c00;   // 1.0
        B_in[10] = 16'h0000;   // 0.0
        B_in[11] = 16'h0000;   // 0.0
        B_in[12] = 16'h0000;   // 0.0
        B_in[13] = 16'h0000;   // 0.0
        B_in[14] = 16'h3c00;   // 1.0
        B_in[15] = 16'h3c00;   // 1.0
        C_exp[0] = 16'h4200;   // 3.0
        C_exp[1] = 16'h3c00;   // 1.0
        C_exp[2] = 16'hbc00;   // -1.0
        C_exp[3] = 16'hc200;   // -3.0
        C_exp[4] = 16'h0000;   // 0.0
        C_exp[5] = 16'h0000;   // 0.0
        C_exp[6] = 16'h0000;   // 0.0
        C_exp[7] = 16'h0000;   // 0.0
        C_exp[8] = 16'h3e00;   // 1.5
        C_exp[9] = 16'h3800;   // 0.5
        C_exp[10] = 16'hb800;   // -0.5
        C_exp[11] = 16'hbe00;   // -1.5
        C_exp[12] = 16'h4000;   // 2.0
        C_exp[13] = 16'h4000;   // 2.0
        C_exp[14] = 16'h4000;   // 2.0
        C_exp[15] = 16'h4000;   // 2.0
        run_case("4x4 mixed signs");

        $display("=== mat_mul fp16 testbench done ===");
        if (total_errors == 0) $display("RESULT: ALL CASES PASSED");
        else                   $display("RESULT: %0d TOTAL FAILURE(S)", total_errors);

        $finish;
    end

    initial begin
        #200000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
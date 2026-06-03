// =============================================================================
// MVP_matrix_maker_tb.v  —  End-to-end test for MVP_matrix_maker
// =============================================================================
// Wires MVP_matrix_maker directly to a mat_mul instance (no top-level mux).
// Pulses start, captures the 16 RAM writes, compares against a numpy-computed
// reference for several (speed_x, speed_y) inputs.
//
// Each `start` advances angle by (speed_x, speed_y). The first start brings
// angles from (0,0) to (speed_x, speed_y), and the MVP is built for those.
//
// Tolerance: allow up to 2 LSB difference per element. The MVP computation
// is two chained matrix multiplies — accumulated rounding from fp16 muls
// and adds can drift by a few LSBs from the numpy reference.
//
// Run:
//   iverilog -o mvp_tb MVP_matrix_maker.v mat_mul.v fp16_mul.v fp16_add.v \
//       MVP_matrix_maker_tb.v && vvp mvp_tb
// =============================================================================

`timescale 1ns / 1ps

module MVP_matrix_maker_tb;

    reg clk;
    reg rst;
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // MVP_matrix_maker instance
    // -------------------------------------------------------------------------
    reg signed [7:0]  speed_x, speed_y;
    reg               start;
    wire              done;

    wire        mat_rst;
    wire [7:0]  mat_N, mat_M, mat_P;
    wire        mat_write_a, mat_write_b;
    wire [15:0] mat_data_a, mat_data_b;
    wire        mat_loaded_a, mat_loaded_b;
    wire [15:0] mat_data_out;
    wire        mat_out_valid;
    wire        mat_busy;

    wire        ram_wen;
    wire [3:0]  ram_addr;
    wire [15:0] ram_din;

    MVP_matrix_maker u_mvp (
        .clk(clk), .rst(rst), .start(start),
        .speed_x(speed_x), .speed_y(speed_y),
        .mat_rst(mat_rst),
        .mat_N(mat_N), .mat_M(mat_M), .mat_P(mat_P),
        .mat_write_a(mat_write_a), .mat_data_a(mat_data_a), .mat_loaded_a(mat_loaded_a),
        .mat_write_b(mat_write_b), .mat_data_b(mat_data_b), .mat_loaded_b(mat_loaded_b),
        .mat_data_out(mat_data_out), .mat_out_valid(mat_out_valid), .mat_busy(mat_busy),
        .ram_wen(ram_wen), .ram_addr(ram_addr), .ram_din(ram_din),
        .done(done)
    );

    // -------------------------------------------------------------------------
    // mat_mul instance — wired directly to MVP_matrix_maker's mat_mul ports
    // -------------------------------------------------------------------------
    mat_mul #(.MAX_DIM(4)) u_matmul (
        .clk(clk),
        .rst(rst | mat_rst),
        .N(mat_N), .M(mat_M), .P(mat_P),
        .write_a(mat_write_a),   .data_a(mat_data_a),   .loaded_a(mat_loaded_a),
        .write_b(mat_write_b),   .data_b(mat_data_b),   .loaded_b(mat_loaded_b),
        .data_out(mat_data_out), .out_valid(mat_out_valid), .busy(mat_busy)
    );

    // -------------------------------------------------------------------------
    // Capture RAM writes into a 16-element buffer
    // -------------------------------------------------------------------------
    reg [15:0] mvp_got [0:15];
    integer    captured;

    always @(posedge clk) begin
        if (ram_wen) begin
            mvp_got[ram_addr] = ram_din;
            captured = captured + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Expected values per test case
    // -------------------------------------------------------------------------
    reg [15:0] sx8_sy16_exp [0:15];
    reg [15:0] sx0_sy0_exp  [0:15];
    reg [15:0] sx64_sy0_exp [0:15];

    function [15:0] absdiff;
        input [15:0] x;
        input [15:0] y;
        begin
            if (x > y) absdiff = x - y;
            else       absdiff = y - x;
        end
    endfunction

    integer total_errors;
    integer i;
    integer case_errors;
    reg [15:0] diff;

    task run_case;
        input [255:0] label;
        input signed [7:0] sx;
        input signed [7:0] sy;
        // expected values are read from one of the *_exp arrays via a select
        input integer sel; // 0=sx8_sy16, 1=sx0_sy0, 2=sx64_sy0
        reg [15:0] expected;
        begin
            case_errors = 0;
            captured = 0;
            // Reset between cases so angle returns to 0
            rst = 1;
            @(negedge clk); @(negedge clk);
            rst = 0;
            @(negedge clk);

            speed_x = sx; speed_y = sy;
            start = 1;
            @(negedge clk);
            start = 0;

            // Wait for done
            @(posedge done);
            @(negedge clk);

            $display("-- case [%0s] sx=%0d sy=%0d --", label, sx, sy);
            if (captured !== 16) begin
                $display("   FAIL: captured %0d writes, expected 16", captured);
                case_errors = case_errors + 1;
            end

            for (i = 0; i < 16; i = i + 1) begin
                case (sel)
                    0: expected = sx8_sy16_exp[i];
                    1: expected = sx0_sy0_exp[i];
                    2: expected = sx64_sy0_exp[i];
                    default: expected = 16'h0;
                endcase
                diff = absdiff(mvp_got[i], expected);
                if (mvp_got[i] === expected) begin
                    // exact
                end else if (diff <= 16'd2) begin
                    // within 2 LSB — accumulation tolerance
                    $display("   ~ok  MVP[%0d] got %h expected %h (off by %0d)",
                             i, mvp_got[i], expected, diff);
                end else begin
                    $display("   FAIL MVP[%0d] got %h expected %h diff %0d",
                             i, mvp_got[i], expected, diff);
                    case_errors = case_errors + 1;
                end
            end
            if (case_errors == 0) $display("   case PASSED");
            else                  $display("   case FAILED (%0d)", case_errors);
            total_errors = total_errors + case_errors;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test program
    // -------------------------------------------------------------------------
    initial begin
        total_errors = 0;
        rst = 1;
        start = 0;
        speed_x = 0; speed_y = 0;

        // Populate expected arrays
        sx8_sy16_exp[0] = 16'h398b;
        sx8_sy16_exp[1] = 16'h2b2a;
        sx8_sy16_exp[2] = 16'h3481;
        sx8_sy16_exp[3] = 16'h0000;
        sx8_sy16_exp[4] = 16'h0000;
        sx8_sy16_exp[5] = 16'h3bd9;
        sx8_sy16_exp[6] = 16'hb23e;
        sx8_sy16_exp[7] = 16'h0000;
        sx8_sy16_exp[8] = 16'h363f;
        sx8_sy16_exp[9] = 16'hb1e2;
        sx8_sy16_exp[10] = 16'hbb66;
        sx8_sy16_exp[11] = 16'h5e10;
        sx8_sy16_exp[12] = 16'h361f;
        sx8_sy16_exp[13] = 16'hb1c4;
        sx8_sy16_exp[14] = 16'hbb40;
        sx8_sy16_exp[15] = 16'h5e40;

        // sx=0, sy=0 -> angles stay 0 -> M = identity, MVP = PV
        sx0_sy0_exp[0] = 16'h3a00; sx0_sy0_exp[1] = 16'h0000;
        sx0_sy0_exp[2] = 16'h0000; sx0_sy0_exp[3] = 16'h0000;
        sx0_sy0_exp[4] = 16'h0000; sx0_sy0_exp[5] = 16'h3c00;
        sx0_sy0_exp[6] = 16'h0000; sx0_sy0_exp[7] = 16'h0000;
        sx0_sy0_exp[8] = 16'h0000; sx0_sy0_exp[9] = 16'h0000;
        sx0_sy0_exp[10] = 16'hbc15; sx0_sy0_exp[11] = 16'h5e10;
        sx0_sy0_exp[12] = 16'h0000; sx0_sy0_exp[13] = 16'h0000;
        sx0_sy0_exp[14] = 16'hbc00; sx0_sy0_exp[15] = 16'h5e40;

        // sx=64, sy=0 -> angle_x = 90 deg. Rx rotates yz plane.
        // Filled with numpy values:
        sx64_sy0_exp[0]  = 16'h3a00;
        sx64_sy0_exp[1]  = 16'h0000;
        sx64_sy0_exp[2]  = 16'h0000;
        sx64_sy0_exp[3]  = 16'h0000;
        sx64_sy0_exp[4]  = 16'h0000;
        sx64_sy0_exp[5]  = 16'h0000;
        sx64_sy0_exp[6]  = 16'hbc00;
        sx64_sy0_exp[7]  = 16'h0000;
        sx64_sy0_exp[8]  = 16'h0000;
        sx64_sy0_exp[9]  = 16'hbc15;
        sx64_sy0_exp[10] = 16'h0000;
        sx64_sy0_exp[11] = 16'h5e10;
        sx64_sy0_exp[12] = 16'h0000;
        sx64_sy0_exp[13] = 16'hbc00;
        sx64_sy0_exp[14] = 16'h0000;
        sx64_sy0_exp[15] = 16'h5e40;

        #1;
        $display("=== MVP_matrix_maker testbench ===");

        run_case("sx=0 sy=0",     8'sd0,  8'sd0,  1);
        run_case("sx=8 sy=16",    8'sd8,  8'sd16, 0);
        run_case("sx=64 sy=0",    8'sd64, 8'sd0,  2);

        $display("=== done ===");
        if (total_errors == 0) $display("RESULT: ALL PASSED");
        else                   $display("RESULT: %0d FAILURE(S)", total_errors);
        $finish;
    end

    initial begin
        #500000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule

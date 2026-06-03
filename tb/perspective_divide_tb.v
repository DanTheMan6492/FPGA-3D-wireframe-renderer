// =============================================================================
// perspective_divide_tb.v  —  Testbench for perspective_divide
// =============================================================================
// Models transform_mem as a dual-port memory with 1-cycle read latency, loads
// known clip-space vertices, runs perspective_divide, and checks the streamed
// pixel coordinates against a numpy.float16 reference.
//
// Tolerance: 2 LSBs per element. The full chain (recip → mul → add → mul) has
// up to four fp16 rounding steps and the testbench reference uses Python's
// float64 internally before final fp16 cast, so a few LSB drift is expected.
//
// Run:
//   iverilog -o pd_tb perspective_divide.v fp16_mul.v fp16_add.v fp16_recip.v \
//       perspective_divide_tb.v && vvp pd_tb
// =============================================================================

`timescale 1ns / 1ps

module perspective_divide_tb;

    reg clk;
    initial clk = 0;
    always #5 clk = ~clk;

    reg rst;
    reg start;
    reg [7:0] vertex_count;
    wire done;

    wire [9:0]  read_addr;
    reg  [15:0] read_data;
    wire [9:0]  write_addr;
    wire [15:0] write_data;
    wire        write_en;

    perspective_divide u_pdiv (
        .clk(clk), .rst(rst), .start(start),
        .vertex_count(vertex_count),
        .read_addr(read_addr), .read_data(read_data),
        .write_addr(write_addr), .write_data(write_data), .write_en(write_en),
        .done(done)
    );

    // -------------------------------------------------------------------------
    // Simulated transform_mem with 1-cycle read latency
    // -------------------------------------------------------------------------
    reg [15:0] tm [0:1023];

    localparam integer N_VERTS = 6;

    always @(posedge clk) begin
        read_data <= tm[read_addr];
        if (write_en) tm[write_addr] <= write_data;
    end

    // -------------------------------------------------------------------------
    // Preload buffers and expected values
    // -------------------------------------------------------------------------
    reg [15:0] tm_init  [0:1023];
    reg [15:0] exp_pix  [0:31];

    integer i;
    integer errors;
    reg [15:0] got;
    reg [15:0] expected;
    reg [15:0] diff;

    function [15:0] absdiff;
        input [15:0] x; input [15:0] y;
        begin
            if (x > y) absdiff = x - y; else absdiff = y - x;
        end
    endfunction

    initial begin
        errors = 0;

        // Initialize tm_init array fully to zero, then overwrite vertex slots.
        for (i = 0; i < 1024; i = i + 1) tm_init[i] = 16'h0;
        for (i = 0; i < 32;   i = i + 1) exp_pix[i] = 16'h0;

// transform_mem preload
        tm_init[0] = 16'h0000;
        tm_init[1] = 16'h0000;
        tm_init[2] = 16'h0000;
        tm_init[3] = 16'h3c00;
        tm_init[4] = 16'h3c00;
        tm_init[5] = 16'h3c00;
        tm_init[6] = 16'h0000;
        tm_init[7] = 16'h3c00;
        tm_init[8] = 16'hbc00;
        tm_init[9] = 16'hbc00;
        tm_init[10] = 16'h0000;
        tm_init[11] = 16'h3c00;
        tm_init[12] = 16'h3800;
        tm_init[13] = 16'hb800;
        tm_init[14] = 16'h0000;
        tm_init[15] = 16'h3c00;
        tm_init[16] = 16'h4000;
        tm_init[17] = 16'h4200;
        tm_init[18] = 16'h0000;
        tm_init[19] = 16'h4400;
        tm_init[20] = 16'hc200;
        tm_init[21] = 16'h4000;
        tm_init[22] = 16'h0000;
        tm_init[23] = 16'h4500;

// Expected pixel coords
        exp_pix[0] = 16'h5d00;   // v0.px = 320.0000
        exp_pix[1] = 16'h5b80;   // v0.py = 240.0000
        exp_pix[2] = 16'h6100;   // v1.px = 640.0000
        exp_pix[3] = 16'h0000;   // v1.py = 0.0000
        exp_pix[4] = 16'h0000;   // v2.px = 0.0000
        exp_pix[5] = 16'h5f80;   // v2.py = 480.0000
        exp_pix[6] = 16'h5f80;   // v3.px = 480.0000
        exp_pix[7] = 16'h5da0;   // v3.py = 360.0000
        exp_pix[8] = 16'h5f80;   // v4.px = 480.0000
        exp_pix[9] = 16'h5380;   // v4.py = 60.0000
        exp_pix[10] = 16'h5801;   // v5.px = 128.1250
        exp_pix[11] = 16'h5880;   // v5.py = 144.0000


        // Copy preload into the simulated memory
        for (i = 0; i < 1024; i = i + 1) tm[i] = tm_init[i];

        // Reset
        rst = 1; start = 0; vertex_count = N_VERTS[7:0];
        read_data = 0;
        @(negedge clk); @(negedge clk);
        rst = 0;
        @(negedge clk);

        // Start
        start = 1;
        @(negedge clk);
        start = 0;

        // Wait for done
        @(posedge done);
        @(negedge clk);

        // Check
        $display("=== perspective_divide test ===");
        for (i = 0; i < 2*N_VERTS; i = i + 1) begin
            got = tm[i];
            expected = exp_pix[i];
            diff = absdiff(got, expected);
            if (got === expected) begin
                $display("  ok   pix[%0d] = %h  (%s)", i,
                    got, (i[0] == 0) ? "px" : "py");
            end else if (diff <= 16'd2) begin
                $display("  ~ok  pix[%0d] = %h  expected %h  (off by %0d)",
                    i, got, expected, diff);
            end else begin
                $display("  FAIL pix[%0d] = %h  expected %h  diff %0d",
                    i, got, expected, diff);
                errors = errors + 1;
            end
        end

        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
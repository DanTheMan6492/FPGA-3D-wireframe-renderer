// =============================================================================
// bresenham_tb.v  —  Testbench for the un-batched Bresenham line drawer
// =============================================================================
// Models a small framebuffer as an array of 32-bit words and a 1-cycle-latency
// read path. Drives the DUT with several test lines and checks the set of
// pixels actually plotted against a reference set computed by a software
// Bresenham loop here in the testbench.
//
// Lines tested:
//   1. Horizontal short (0,0) -> (5,0)
//   2. Vertical   short (3,0) -> (3,5)
//   3. 45-degree diagonal (0,0) -> (7,7)
//   4. Shallow slope (0,0) -> (10,3)
//   5. Steep slope   (0,0) -> (3,10)
//   6. Reverse-direction line (10,5) -> (2,1)
//
// All stimulus is driven on negedge to avoid racing the posedge-sampling DUT.
//
// Run:
//   iverilog -o br_tb bresenham.v bresenham_tb.v && vvp br_tb
// =============================================================================

`timescale 1ns / 1ps

module bresenham_tb;

    // Framebuffer dimensions for the test. We use 64x32 (small) — enough to
    // cover the test lines while keeping the model tiny.
    localparam FB_W = 64;
    localparam FB_H = 32;
    localparam FB_BITS  = FB_W * FB_H;
    localparam FB_WORDS = FB_BITS / 32;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg         clk;
    reg         rst;
    reg         start;
    reg  [9:0]  x0, y0, x1, y1;
    wire [13:0] fb_addr;
    wire [31:0] fb_din;
    reg  [31:0] fb_dout;
    wire        fb_wen;
    wire        done;

    bresenham dut (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .x0      (x0),
        .y0      (y0),
        .x1      (x1),
        .y1      (y1),
        .fb_addr (fb_addr),
        .fb_din  (fb_din),
        .fb_dout (fb_dout),
        .fb_wen  (fb_wen),
        .done    (done)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Simulated framebuffer: word-addressed array, 1-cycle read latency.
    //
    // The DUT uses 640 as its row stride internally (hardcoded multiply by
    // 640). For test purposes we simulate that — we don't need to actually
    // span a full 640x480, just to make sure (x,y) maps to the same address
    // the DUT computes. So our test FB has the same addressing, we just only
    // touch a small corner of it.
    // -------------------------------------------------------------------------
    localparam DUT_STRIDE = 640;
    localparam DUT_FB_BITS  = DUT_STRIDE * 480;
    localparam DUT_FB_WORDS = DUT_FB_BITS / 32;     // 9600

    reg [31:0] fb_mem [0:DUT_FB_WORDS-1];

    integer i;

    // Synchronous read with 1-cycle latency: fb_dout follows fb_addr by one
    // cycle, matching SDPRAM read behaviour.
    always @(posedge clk) begin
        fb_dout <= fb_mem[fb_addr];
        if (fb_wen) fb_mem[fb_addr] <= fb_din;
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    function automatic [18:0] pixel_idx(input [9:0] x, input [9:0] y);
        pixel_idx = y * DUT_STRIDE + x;
    endfunction

    function automatic get_pixel(input [9:0] x, input [9:0] y);
        reg [18:0] idx;
        begin
            idx = pixel_idx(x, y);
            get_pixel = fb_mem[idx[18:5]][idx[4:0]];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Reference Bresenham: builds a 2D "expected" bitmap by running the
    // algorithm in plain procedural code.
    // -------------------------------------------------------------------------
    reg expected_set [0:639][0:479];

    task ref_bresenham;
        input integer a0, b0, a1, b1;
        integer adx, ady, asx, asy, ae, ae2;
        integer ax, ay;
        begin
            adx = (a1 > a0) ? (a1 - a0) : (a0 - a1);
            ady = (b1 > b0) ? (b1 - b0) : (b0 - b1);
            asx = (a1 > a0) ? 1 : -1;
            asy = (b1 > b0) ? 1 : -1;
            ae  = adx - ady;
            ax  = a0;
            ay  = b0;
            // Loop, plot, until endpoint plotted
            forever begin
                expected_set[ax][ay] = 1'b1;
                if (ax == a1 && ay == b1) disable ref_bresenham;
                ae2 = 2 * ae;
                if (ae2 > -ady) begin
                    ae = ae - ady;
                    ax = ax + asx;
                end
                if (ae2 <  adx) begin
                    ae = ae + adx;
                    ay = ay + asy;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Reset / clear helpers
    // -------------------------------------------------------------------------
    task clear_fb;
        integer k;
        begin
            for (k = 0; k < DUT_FB_WORDS; k = k + 1) fb_mem[k] = 32'b0;
        end
    endtask

    task clear_expected;
        integer ix, iy;
        begin
            for (ix = 0; ix < 640; ix = ix + 1)
                for (iy = 0; iy < 480; iy = iy + 1)
                    expected_set[ix][iy] = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Run one line and check
    // -------------------------------------------------------------------------
    integer case_errors;
    integer total_errors;

    task run_line;
        input [127:0] label;
        input integer a0, b0, a1, b1;
        integer ix, iy;
        integer pixels_plotted, pixels_expected;
        begin
            case_errors = 0;
            $display("-- case [%0s] (%0d,%0d) -> (%0d,%0d) --",
                     label, a0, b0, a1, b1);

            clear_fb;
            clear_expected;
            ref_bresenham(a0, b0, a1, b1);

            // Drive the DUT
            @(negedge clk);
            x0 = a0; y0 = b0; x1 = a1; y1 = b1;
            start = 1;
            @(negedge clk);
            start = 0;

            // Wait for done
            @(posedge done);
            @(negedge clk);

            // Compare. We only need to check the bounding box of the line.
            pixels_plotted  = 0;
            pixels_expected = 0;
            for (ix = 0; ix < 64; ix = ix + 1) begin
                for (iy = 0; iy < 32; iy = iy + 1) begin
                    if (expected_set[ix][iy]) pixels_expected = pixels_expected + 1;
                    if (get_pixel(ix, iy))    pixels_plotted  = pixels_plotted  + 1;
                    if (expected_set[ix][iy] !== get_pixel(ix, iy)) begin
                        $display("   FAIL pixel (%0d,%0d): expected %0b got %0b",
                                 ix, iy, expected_set[ix][iy], get_pixel(ix,iy));
                        case_errors = case_errors + 1;
                    end
                end
            end
            $display("   plotted=%0d expected=%0d", pixels_plotted, pixels_expected);
            if (case_errors == 0) $display("   case PASSED");
            else                  $display("   case FAILED (%0d error(s))", case_errors);
            total_errors = total_errors + case_errors;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test program
    // -------------------------------------------------------------------------
    initial begin
        total_errors = 0;
        clk    = 0;
        rst    = 1;
        start  = 0;
        x0=0; y0=0; x1=0; y1=0;
        fb_dout = 0;
        clear_fb;

        @(negedge clk); @(negedge clk);
        rst = 0;
        @(negedge clk);

        $display("=== bresenham testbench start ===");

        run_line("horiz",      0, 0,  5, 0);
        run_line("vert",       3, 0,  3, 5);
        run_line("diag45",     0, 0,  7, 7);
        run_line("shallow",    0, 0, 10, 3);
        run_line("steep",      0, 0,  3, 10);
        run_line("reverse",   10, 5,  2, 1);

        $display("=== bresenham testbench done ===");
        if (total_errors == 0) $display("RESULT: ALL CASES PASSED");
        else                   $display("RESULT: %0d TOTAL FAILURE(S)", total_errors);

        $finish;
    end

    // Safety timeout
    initial begin
        #200000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
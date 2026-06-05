// =============================================================================
// clock_gen.v  -  Generate clk_sys (100 MHz) and clk_pix (25 MHz) from clk_in
// =============================================================================
// Production path uses a Xilinx MMCME2_BASE primitive (instantiated by Vivado's
// clocking infrastructure) to produce the two clocks with a known phase
// relationship - every 4th edge of clk_sys is coincident with an edge of
// clk_pix. The locked output stays low until both clocks have stabilized.
//
// Simulation path (no MMCM available in iverilog) substitutes a simple /4
// divider that produces the same nominal clock ratio. Phase alignment is
// trivially exact in this case since both come from the same source clock.
// `locked` is asserted immediately after a brief reset.
//
// The SIM_ONLY define is set automatically by the iverilog command line
// (the Makefile passes -DSIM_ONLY); Vivado leaves it undefined.
// =============================================================================

`timescale 1ns / 1ps
module clock_gen (
    input  wire clk_in,       // 100 MHz from board oscillator
    output wire clk_sys,      // 100 MHz system clock
    output wire clk_pix,      // 25 MHz VGA pixel clock
    output wire locked        // high once both clocks are stable
);

`ifdef SIM_ONLY
    // -------------------------------------------------------------------------
    // Simulation: simple dividers. clk_sys = clk_in/2 (50 MHz), clk_pix = /4 (25 MHz).
    // -------------------------------------------------------------------------
    reg clk_div2 = 1'b0;
    always @(posedge clk_in) clk_div2 <= ~clk_div2;
    assign clk_sys = clk_div2;

    reg [1:0] div_cnt = 2'd0;
    reg       pix_q   = 1'b0;
    always @(posedge clk_in) begin
        if (div_cnt == 2'd1) begin div_cnt <= 2'd0; pix_q <= ~pix_q; end
        else                 div_cnt <= div_cnt + 2'd1;
    end
    assign clk_pix = pix_q;

    assign locked = 1'b1;

`else
    // -------------------------------------------------------------------------
    // Synthesis: MMCME2_BASE
    //
    // Input  clk_in:  100 MHz, period 10 ns
    // VCO   = 100 MHz * CLKFBOUT_MULT_F / DIVCLK_DIVIDE
    //       = 100 * 10 / 1 = 1000 MHz
    // clk_sys = VCO / CLKOUT0_DIVIDE = 1000 / 20 = 50 MHz
    // clk_pix = VCO / CLKOUT1_DIVIDE = 1000 / 40 = 25 MHz
    //
    // Dropping clk_sys to 50 MHz (20 ns period) gives the fp16_add
    // accumulation path in the PE sufficient margin to close timing.
    // -------------------------------------------------------------------------
    wire       clkfb;
    wire       clk_sys_int;
    wire       clk_pix_int;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .CLKFBOUT_MULT_F  (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (20.0),
        .CLKOUT1_DIVIDE   (40),
        .CLKOUT0_PHASE    (0.0),
        .CLKOUT1_PHASE    (0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DUTY_CYCLE(0.5)
    ) u_mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_sys_int),
        .CLKOUT0B (),
        .CLKOUT1  (clk_pix_int),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .CLKFBOUTB(),
        .LOCKED   (locked),
        .RST      (1'b0),
        .PWRDWN   (1'b0)
    );

    // Route through global clock buffers
    BUFG bufg_sys (.I(clk_sys_int), .O(clk_sys));
    BUFG bufg_pix (.I(clk_pix_int), .O(clk_pix));

`endif

endmodule
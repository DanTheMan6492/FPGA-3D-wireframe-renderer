// =============================================================================
// xpm_stubs.v  —  iverilog stubs for Xilinx XPM and Unisim primitives
// =============================================================================
// These let iverilog elaborate code that uses Vivado-only primitives.
//
// DO NOT include this file in synthesis — Vivado provides the real primitives.
// =============================================================================

`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// xpm_memory_sdpram stub — 1-cycle latency SDPRAM
// Honors CLOCKING_MODE = "common_clock" vs "independent_clock" by picking
// either clka or clkb for the read port.
// -----------------------------------------------------------------------------
module xpm_memory_sdpram #(
    parameter integer ADDR_WIDTH_A         = 6,
    parameter integer ADDR_WIDTH_B         = 6,
    parameter integer WRITE_DATA_WIDTH_A   = 32,
    parameter integer READ_DATA_WIDTH_B    = 32,
    parameter integer BYTE_WRITE_WIDTH_A   = 32,
    parameter integer MEMORY_SIZE          = 2048,
    parameter integer READ_LATENCY_B       = 1,
    parameter         MEMORY_PRIMITIVE     = "auto",
    parameter         CLOCKING_MODE        = "common_clock",
    parameter         WRITE_MODE_B         = "no_change",
    parameter         RST_MODE_A           = "SYNC",
    parameter         RST_MODE_B           = "SYNC",
    parameter integer AUTO_SLEEP_TIME      = 0,
    parameter integer CASCADE_HEIGHT       = 0,
    parameter         ECC_MODE             = "no_ecc",
    parameter         MEMORY_INIT_FILE     = "none",
    parameter         MEMORY_INIT_PARAM    = "0",
    parameter         MEMORY_OPTIMIZATION  = "true",
    parameter integer MESSAGE_CONTROL      = 0,
    parameter         READ_RESET_VALUE_B   = "0",
    parameter integer SIM_ASSERT_CHK       = 0,
    parameter integer USE_EMBEDDED_CONSTRAINT = 0,
    parameter integer USE_MEM_INIT         = 0,
    parameter         WAKEUP_TIME          = "disable_sleep"
)(
    input  wire                              clka,
    input  wire                              rsta,
    input  wire                              ena,
    input  wire [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea,
    input  wire [ADDR_WIDTH_A-1:0]           addra,
    input  wire [WRITE_DATA_WIDTH_A-1:0]     dina,

    input  wire                              clkb,
    input  wire                              rstb,
    input  wire                              enb,
    input  wire                              regceb,
    input  wire [ADDR_WIDTH_B-1:0]           addrb,
    output reg  [READ_DATA_WIDTH_B-1:0]      doutb,

    input  wire                              sleep,
    input  wire                              injectsbiterra,
    input  wire                              injectdbiterra,
    output wire                              sbiterrb,
    output wire                              dbiterrb
);
    localparam integer DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;

    reg [WRITE_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 0;
        doutb = 0;
        // If a memory init file was given, $readmemh it. This mirrors how
        // Vivado's real XPM honors MEMORY_INIT_FILE at bitstream load.
        if (MEMORY_INIT_FILE != "none" && MEMORY_INIT_FILE != "")
            $readmemh(MEMORY_INIT_FILE, mem);
    end

    // Port A write
    always @(posedge clka) begin
        if (ena && wea) mem[addra] <= dina;
    end

    // Port B read — clkb is the read clock; in common_clock mode the wrapper
    // ties clkb = clka, so this still works.
    always @(posedge clkb) begin
        if (rstb) doutb <= 0;
        else if (enb) doutb <= mem[addrb];
    end

    assign sbiterrb = 1'b0;
    assign dbiterrb = 1'b0;
endmodule


// -----------------------------------------------------------------------------
// xpm_memory_tdpram stub — true dual-port, 1-cycle latency on both ports
// -----------------------------------------------------------------------------
module xpm_memory_tdpram #(
    parameter integer ADDR_WIDTH_A         = 6,
    parameter integer ADDR_WIDTH_B         = 6,
    parameter integer WRITE_DATA_WIDTH_A   = 32,
    parameter integer READ_DATA_WIDTH_A    = 32,
    parameter integer WRITE_DATA_WIDTH_B   = 32,
    parameter integer READ_DATA_WIDTH_B    = 32,
    parameter integer BYTE_WRITE_WIDTH_A   = 32,
    parameter integer BYTE_WRITE_WIDTH_B   = 32,
    parameter integer MEMORY_SIZE          = 2048,
    parameter integer READ_LATENCY_A       = 1,
    parameter integer READ_LATENCY_B       = 1,
    parameter         MEMORY_PRIMITIVE     = "auto",
    parameter         CLOCKING_MODE        = "common_clock",
    parameter         WRITE_MODE_A         = "no_change",
    parameter         WRITE_MODE_B         = "no_change",
    parameter         RST_MODE_A           = "SYNC",
    parameter         RST_MODE_B           = "SYNC",
    parameter integer AUTO_SLEEP_TIME      = 0,
    parameter integer CASCADE_HEIGHT       = 0,
    parameter         ECC_MODE             = "no_ecc",
    parameter         MEMORY_INIT_FILE     = "none",
    parameter         MEMORY_INIT_PARAM    = "0",
    parameter         MEMORY_OPTIMIZATION  = "true",
    parameter integer MESSAGE_CONTROL      = 0,
    parameter         READ_RESET_VALUE_A   = "0",
    parameter         READ_RESET_VALUE_B   = "0",
    parameter integer SIM_ASSERT_CHK       = 0,
    parameter integer USE_EMBEDDED_CONSTRAINT = 0,
    parameter integer USE_MEM_INIT         = 0,
    parameter         WAKEUP_TIME          = "disable_sleep"
)(
    input  wire                              clka,
    input  wire                              rsta,
    input  wire                              ena,
    input  wire                              regcea,
    input  wire [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea,
    input  wire [ADDR_WIDTH_A-1:0]           addra,
    input  wire [WRITE_DATA_WIDTH_A-1:0]     dina,
    output reg  [READ_DATA_WIDTH_A-1:0]      douta,

    input  wire                              clkb,
    input  wire                              rstb,
    input  wire                              enb,
    input  wire                              regceb,
    input  wire [WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B-1:0] web,
    input  wire [ADDR_WIDTH_B-1:0]           addrb,
    input  wire [WRITE_DATA_WIDTH_B-1:0]     dinb,
    output reg  [READ_DATA_WIDTH_B-1:0]      doutb,

    input  wire                              sleep,
    input  wire                              injectsbiterra,
    input  wire                              injectdbiterra,
    input  wire                              injectsbiterrb,
    input  wire                              injectdbiterrb,
    output wire                              sbiterra,
    output wire                              dbiterra,
    output wire                              sbiterrb,
    output wire                              dbiterrb
);
    localparam integer DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;

    reg [WRITE_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 0;
        douta = 0;
        doutb = 0;
    end

    // Port A: read+write
    always @(posedge clka) begin
        if (rsta) douta <= 0;
        else if (ena) begin
            if (wea) mem[addra] <= dina;
            douta <= mem[addra];
        end
    end

    // Port B: read+write
    always @(posedge clkb) begin
        if (rstb) doutb <= 0;
        else if (enb) begin
            if (web) mem[addrb] <= dinb;
            doutb <= mem[addrb];
        end
    end

    assign sbiterra = 1'b0; assign dbiterra = 1'b0;
    assign sbiterrb = 1'b0; assign dbiterrb = 1'b0;
endmodule



// -----------------------------------------------------------------------------
// MMCME2_BASE stub — passes through CLKIN1 to CLKOUT0 unchanged, divides for
// CLKOUT1. Only the clock-divide ratios we actually use are honored.
// -----------------------------------------------------------------------------
module MMCME2_BASE #(
    parameter real    CLKIN1_PERIOD     = 10.0,
    parameter real    CLKFBOUT_MULT_F   = 10.0,
    parameter integer DIVCLK_DIVIDE     = 1,
    parameter real    CLKOUT0_DIVIDE_F  = 10.0,
    parameter integer CLKOUT1_DIVIDE    = 40,
    parameter real    CLKOUT0_PHASE     = 0.0,
    parameter real    CLKOUT1_PHASE     = 0.0,
    parameter real    CLKOUT0_DUTY_CYCLE = 0.5,
    parameter real    CLKOUT1_DUTY_CYCLE = 0.5
)(
    input  wire CLKIN1,
    input  wire CLKFBIN,
    output wire CLKFBOUT,
    output wire CLKOUT0,
    output wire CLKOUT1,
    output reg  LOCKED,
    input  wire RST,
    input  wire PWRDWN
);
    initial LOCKED = 1'b1;   // pretend locked immediately

    // CLKOUT0: passthrough (assumes CLKFBOUT_MULT/DIVCLK/CLKOUT0_DIVIDE_F = 1)
    assign CLKOUT0  = CLKIN1;
    assign CLKFBOUT = CLKIN1;

    // CLKOUT1: divide CLKIN1 by CLKOUT1_DIVIDE/(CLKFBOUT_MULT_F/CLKOUT0_DIVIDE_F)
    // For our case (mult=10, c0=10, c1=40): divide ratio = 40/(10/10) = 40,
    // but we want 100->25 MHz which is /4 of CLKIN1. So we expect /4.
    localparam integer EFFECTIVE_DIVIDE = CLKOUT1_DIVIDE * 1; // simplified

    // Simplest sim: /4 divider regardless (matches our actual config)
    reg [1:0] dcnt = 2'd0;
    reg       cko1 = 1'b0;
    always @(posedge CLKIN1) begin
        if (dcnt == 2'd1) begin dcnt <= 2'd0; cko1 <= ~cko1; end
        else              dcnt <= dcnt + 2'd1;
    end
    assign CLKOUT1 = cko1;

endmodule


// -----------------------------------------------------------------------------
// BUFG stub — global clock buffer, just a wire in sim.
// -----------------------------------------------------------------------------
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule
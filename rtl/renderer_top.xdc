# =============================================================================
# renderer_top.xdc - Basys 3 (Artix-7 XC7A35TCPG236-1) constraints
# =============================================================================

# -----------------------------------------------------------------------------
# Clock - 100 MHz board oscillator. The MMCM divides this to produce
# clk_sys (50 MHz) and clk_pix (25 MHz) internally.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN W5      [get_ports clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports clk_in]
create_clock -add -name sys_clk_pin -period 10.000 -waveform {0 5} [get_ports clk_in]

# -----------------------------------------------------------------------------
# Pushbuttons
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN U18     [get_ports rst_btn]
set_property IOSTANDARD LVCMOS33 [get_ports rst_btn]

set_property PACKAGE_PIN T18     [get_ports btn_up]
set_property IOSTANDARD LVCMOS33 [get_ports btn_up]

set_property PACKAGE_PIN U17     [get_ports btn_down]
set_property IOSTANDARD LVCMOS33 [get_ports btn_down]

set_property PACKAGE_PIN W19     [get_ports btn_left]
set_property IOSTANDARD LVCMOS33 [get_ports btn_left]

set_property PACKAGE_PIN T17     [get_ports btn_right]
set_property IOSTANDARD LVCMOS33 [get_ports btn_right]

# -----------------------------------------------------------------------------
# USB-UART RX
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN B18     [get_ports uart_rx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_pin]

# -----------------------------------------------------------------------------
# 7-segment display
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN W7      [get_ports {seg[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[0]}]
set_property PACKAGE_PIN W6      [get_ports {seg[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[1]}]
set_property PACKAGE_PIN U8      [get_ports {seg[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[2]}]
set_property PACKAGE_PIN V8      [get_ports {seg[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[3]}]
set_property PACKAGE_PIN U5      [get_ports {seg[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[4]}]
set_property PACKAGE_PIN V5      [get_ports {seg[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[5]}]
set_property PACKAGE_PIN U7      [get_ports {seg[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[6]}]

set_property PACKAGE_PIN V7      [get_ports dp]
set_property IOSTANDARD LVCMOS33 [get_ports dp]

set_property PACKAGE_PIN U2      [get_ports {an[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[0]}]
set_property PACKAGE_PIN U4      [get_ports {an[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[1]}]
set_property PACKAGE_PIN V4      [get_ports {an[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[2]}]
set_property PACKAGE_PIN W4      [get_ports {an[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[3]}]

# -----------------------------------------------------------------------------
# VGA - all channels driven (white wireframe on black background)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN G19     [get_ports {vga_r[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[0]}]
set_property PACKAGE_PIN H19     [get_ports {vga_r[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[1]}]
set_property PACKAGE_PIN J19     [get_ports {vga_r[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[2]}]
set_property PACKAGE_PIN N19     [get_ports {vga_r[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[3]}]

set_property PACKAGE_PIN J17     [get_ports {vga_g[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_g[0]}]
set_property PACKAGE_PIN H17     [get_ports {vga_g[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_g[1]}]
set_property PACKAGE_PIN G17     [get_ports {vga_g[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_g[2]}]
set_property PACKAGE_PIN D17     [get_ports {vga_g[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_g[3]}]

set_property PACKAGE_PIN N18     [get_ports {vga_b[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_b[0]}]
set_property PACKAGE_PIN L18     [get_ports {vga_b[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_b[1]}]
set_property PACKAGE_PIN K18     [get_ports {vga_b[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_b[2]}]
set_property PACKAGE_PIN J18     [get_ports {vga_b[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_b[3]}]

set_property PACKAGE_PIN P19     [get_ports vga_hsync]
set_property IOSTANDARD LVCMOS33 [get_ports vga_hsync]
set_property PACKAGE_PIN R19     [get_ports vga_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports vga_vsync]

# -----------------------------------------------------------------------------
# CDC false path: vblank crosses from clk_pix (25 MHz) to clk_sys (50 MHz).
# Both are derived from the same MMCM so they are phase-aligned. vblank is
# held high for ~1.4 ms so the single-FF sync in renderer_top is sufficient.
# -----------------------------------------------------------------------------
set_false_path -from [get_clocks -of_objects [get_nets -hierarchical clk_pix*]] \
               -to   [get_clocks -of_objects [get_nets -hierarchical clk*]]

# (No Pblock needed - use Performance_ExplorePostRoutePhysOpt strategy instead)

`timescale 1ns / 1ps
module vga_controller (
    input  wire        clk_25mhz,
    output wire [13:0] fb_addr,
    input  wire [31:0] fb_dout,
    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vblank
);
    reg [9:0] h_count = 0;
    reg [9:0] v_count = 0;
    always @(posedge clk_25mhz) begin
        if (h_count == 799) begin
            h_count <= 0;
            v_count <= (v_count == 524) ? 0 : v_count + 1;
        end else begin
            h_count <= h_count + 1;
        end
    end
    wire [9:0] h_next = (h_count == 799) ? 10'd0 : h_count + 10'd1;
    wire [9:0] v_next = (h_count == 799) ?
                        ((v_count == 524) ? 10'd0 : v_count + 10'd1) : v_count;
    assign fb_addr = (h_next < 640 && v_next < 480)
                     ? ((v_next << 4) + (v_next << 2) + {5'b0, h_next[9:5]})
                     : 14'd0;
    // fb_addr is presented one cycle early (h_next) to absorb the BRAM's
    // 1-cycle read latency. Register the corresponding bit index so it arrives
    // aligned with fb_dout.
    reg [4:0] bit_idx_q;
    always @(posedge clk_25mhz) bit_idx_q <= h_next[4:0];

    wire active    = (h_count < 640) && (v_count < 480);
    wire pixel_bit = fb_dout[bit_idx_q];
    assign vga_hsync = ~((h_count >= 656) && (h_count < 752));
    assign vga_vsync = ~((v_count >= 490) && (v_count < 492));
    assign vga_r = (active && pixel_bit) ? 4'hF : 4'h0;
    assign vga_g = (active && pixel_bit) ? 4'hF : 4'h0;
    assign vga_b = (active && pixel_bit) ? 4'hF : 4'h0;

    // Vblank registered for a clean source pin on the CDC path into the
    // 100 MHz domain (referenced by set_false_path in the XDC).
    reg vblank_q = 1'b0;
    always @(posedge clk_25mhz) vblank_q <= (v_count >= 480);
    assign vblank = vblank_q;
endmodule
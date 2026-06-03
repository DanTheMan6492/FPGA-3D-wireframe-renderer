module vga_controller (
    input  wire        clk_25mhz,

    // Framebuffer read port (32-bit word, SDPRAM port B).
    // Address must be presented one cycle before the pixel is displayed to
    // account for the SDPRAM's one-cycle read latency.
    output wire [13:0] fb_addr,   // word address: (y * 20) + (x >> 5)
    input  wire [31:0] fb_dout,   // 32 packed pixels; bit[i] = pixel at x%32 == i

    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vblank     // high during vertical blanking (v_count >= 480)
);

    // -------------------------------------------------------------------------
    // Pixel counters: h_count in [0..799], v_count in [0..524]
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Next-pixel position (one cycle ahead) for SDPRAM prefetch
    // -------------------------------------------------------------------------
    wire [9:0] h_next = (h_count == 799) ? 10'd0 : h_count + 10'd1;
    wire [9:0] v_next = (h_count == 799) ?
                        ((v_count == 524) ? 10'd0 : v_count + 10'd1) : v_count;

    // -------------------------------------------------------------------------
    // Framebuffer word address: (y * 20 + x/32), driven combinationally so the
    // SDPRAM's input register captures it on the same rising edge as the counter
    // update, delivering fb_dout one cycle later when the pixel is displayed.
    // -------------------------------------------------------------------------
    assign fb_addr = (h_next < 640 && v_next < 480)
                     ? (v_next * 20 + {5'b0, h_next[9:5]})
                     : 14'd0;

    // -------------------------------------------------------------------------
    // Pixel bit extraction from the 32-bit word
    // -------------------------------------------------------------------------
    wire active    = (h_count < 640) && (v_count < 480);
    wire pixel_bit = fb_dout[h_count[4:0]];

    // -------------------------------------------------------------------------
    // VGA sync signals (active-low)
    // -------------------------------------------------------------------------
    assign vga_hsync = ~((h_count >= 656) && (h_count < 752));
    assign vga_vsync = ~((v_count >= 490) && (v_count < 492));

    // -------------------------------------------------------------------------
    // RGB: green wireframe on black background
    // -------------------------------------------------------------------------
    assign vga_r = 4'h0;
    assign vga_g = (active && pixel_bit) ? 4'hF : 4'h0;
    assign vga_b = 4'h0;

    // -------------------------------------------------------------------------
    // Vblank: high for the entire vertical blanking interval (lines 480-524).
    // The top level uses the rising edge of this signal to start each frame.
    // -------------------------------------------------------------------------
    assign vblank = (v_count >= 480);

endmodule

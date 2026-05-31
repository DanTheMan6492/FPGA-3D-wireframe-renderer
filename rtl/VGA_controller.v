module VGA_test (
    input  wire         clk_25mhz,
    input  wire         fb_din,

    output wire [3:0]   vga_r,
    output wire [3:0]   vga_g,
    output wire [3:0]   vga_b,
    output wire         vga_hsync,
    output wire         vga_vsync,
    output wire [18:0]  fb_addrb
);

    // Pixel Counters
    reg [9:0] h_count = 0; // 0 - 799
    reg [9:0] v_count = 0; // 0 - 524
    always @(posedge clk_25mhz) begin
        if (h_count == 799) begin
            h_count <= 0;
            v_count <= (v_count == 524) ? 0 : v_count + 1;
        end else begin
            h_count <= h_count + 1;
        end
    end

    // Sync Signal Gen
    assign vga_hsync = ~((h_count >= 656) && (h_count < 752)); 
    assign vga_vsync = ~((v_count >= 490) && (v_count < 492)); 

    wire active = (h_count < 640) && (v_count < 480);
    assign vga_r = 4'h0;
    assign vga_g = (active && ~fb_din) ? 4'hF : 4'h0;
    assign vga_b = 4'h0;

    wire [9:0] h_next =  (h_count == 799) ? 0 : h_count + 1;
    wire [9:0] v_next =  (h_count == 799) ?
                        ((v_count == 524) ? 0 : v_count + 1) : v_count;

    assign fb_addrb = (v_next < 480 && h_next < 640) ?
                      (v_next * 640 + h_next) : 19'd0;
endmodule
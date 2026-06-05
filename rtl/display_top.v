// =============================================================================
// display_top.v  —  Basys 3 four-digit seven-segment display driver
// =============================================================================
// Drives the Basys 3 (Artix-7) on-board 4-digit common-anode seven-segment
// display, showing the current vertex and face counts of the uploaded mesh.
// This is the module referenced as "display_top — 7-segment display showing
// vertex/face counts" in docs/top_level.md, fed by the top level's
// vertex/face count display path.
//
// Both counts are 8-bit (0..255), so each is shown as two HEXADECIMAL digits.
// Hex is the only layout that fits both full-range counts on the board's four
// digits at once (decimal 255 would need three digits per value = six total):
//
//        +-----+-----+   +-----+-----+
//        | AN3 | AN2 |   | AN1 | AN0 |
//        +-----+-----+   +-----+-----+
//          vertex_count     face_count
//           (hex 00..FF)     (hex 00..FF)
//
// The four digits share one set of cathode (segment) lines, so they are
// time-multiplexed: a free-running counter selects one digit at a time, drives
// that digit's anode low, and presents that digit's segment pattern. At the
// default REFRESH_BITS the whole display is swept far faster than the eye can
// follow, so all four digits appear lit simultaneously with no flicker.
//
// Pin polarity (common anode): both `seg` and `an` are ACTIVE LOW.
//   seg[0]=CA(a), seg[1]=CB(b), ... seg[6]=CG(g)  — matches the Basys 3 master
//   XDC ordering, so a 0 bit lights that segment.
//   `dp` is the decimal point (active low); held off (1) here.
//   an[d] low enables digit d; exactly one bit is low at any time (one-hot-low).
// =============================================================================

`timescale 1ns / 1ps
module display_top #(
    // Width of the free-running refresh counter. The top two bits select the
    // active digit, so a full 4-digit sweep takes 2**REFRESH_BITS clocks.
    // At 100 MHz, REFRESH_BITS=18 -> each digit refreshed ~95 times/s (no
    // visible flicker). The testbench overrides this to sweep quickly in sim.
    parameter REFRESH_BITS = 18
)(
    input  wire       clk,
    input  wire [7:0] vertex_count,
    input  wire [7:0] face_count,

    output reg  [6:0] seg,   // cathodes CA..CG, active low (0 = segment lit)
    output reg        dp,    // decimal point, active low (1 = off)
    output reg  [3:0] an     // anode enables, active low, one-hot-low
);

    // -------------------------------------------------------------------------
    // Hex digit -> seven-segment pattern.
    //   Active low, bit order seg[0]=a .. seg[6]=g (Basys 3 master XDC order).
    //   These are the canonical common-anode hex glyph codes.
    // -------------------------------------------------------------------------
    function [6:0] hex7seg;
        input [3:0] nib;
        begin
            case (nib)
                4'h0: hex7seg = 7'h40;
                4'h1: hex7seg = 7'h79;
                4'h2: hex7seg = 7'h24;
                4'h3: hex7seg = 7'h30;
                4'h4: hex7seg = 7'h19;
                4'h5: hex7seg = 7'h12;
                4'h6: hex7seg = 7'h02;
                4'h7: hex7seg = 7'h78;
                4'h8: hex7seg = 7'h00;
                4'h9: hex7seg = 7'h10;
                4'hA: hex7seg = 7'h08;
                4'hB: hex7seg = 7'h03;
                4'hC: hex7seg = 7'h46;
                4'hD: hex7seg = 7'h21;
                4'hE: hex7seg = 7'h06;
                4'hF: hex7seg = 7'h0E;
                default: hex7seg = 7'h7F;   // all segments off (unreachable)
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Free-running refresh counter; its top two bits choose the active digit.
    // -------------------------------------------------------------------------
    reg [REFRESH_BITS-1:0] refresh_cnt = 0;
    always @(posedge clk)
        refresh_cnt <= refresh_cnt + 1'b1;

    wire [1:0] digit_sel = refresh_cnt[REFRESH_BITS-1 -: 2];

    // -------------------------------------------------------------------------
    // Per-digit nibble select:
    //   digit 0 (AN0, rightmost) : face_count[3:0]   low  hex of face count
    //   digit 1 (AN1)            : face_count[7:4]    high hex of face count
    //   digit 2 (AN2)            : vertex_count[3:0]  low  hex of vertex count
    //   digit 3 (AN3, leftmost)  : vertex_count[7:4]  high hex of vertex count
    // -------------------------------------------------------------------------
    reg [3:0] nibble;
    always @(*) begin
        case (digit_sel)
            2'd0: nibble = face_count[3:0];
            2'd1: nibble = face_count[7:4];
            2'd2: nibble = vertex_count[3:0];
            2'd3: nibble = vertex_count[7:4];
        endcase
    end

    // -------------------------------------------------------------------------
    // Drive the active anode low (one-hot-low) with its segment pattern.
    // -------------------------------------------------------------------------
    always @(*) begin
        seg = hex7seg(nibble);
        dp  = 1'b1;                  // decimal point off
        case (digit_sel)
            2'd0: an = 4'b1110;      // enable AN0
            2'd1: an = 4'b1101;      // enable AN1
            2'd2: an = 4'b1011;      // enable AN2
            2'd3: an = 4'b0111;      // enable AN3
        endcase
    end

endmodule

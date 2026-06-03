// =============================================================================
// wireframe_gen_tb.v  —  End-to-end test for wireframe_gen
// =============================================================================
// Simulates obj_mem, transform_mem (preloaded with known pixel coords), and
// the framebuffer. Runs wireframe_gen on a small mesh, captures the lit
// pixels, compares against a reference set computed by software Bresenham.
//
// Memory models match the real hardware: 1-cycle SDPRAM read latency.
//
// Test mesh: a single triangle. Edges:
//   (100,50)-(200,150), (200,150)-(50,200), (50,200)-(100,50)
//
// Run:
//   iverilog -o wf_tb wireframe_gen.v bresenham.v fp16_to_int.v clz.v \
//       wireframe_gen_tb.v && vvp wf_tb
// =============================================================================

`timescale 1ns / 1ps

module wireframe_gen_tb;

    localparam integer VC = 3;
    localparam integer FC = 1;
    localparam integer EXPECTED_PIXELS = 400;


    reg clk;
    initial clk = 0;
    always #5 clk = ~clk;

    reg rst;
    reg start;
    reg [7:0] face_count;
    reg [7:0] vertex_count;
    wire done;

    // DUT memory ports
    wire [10:0] obj_addr;
    reg  [15:0] obj_data;
    wire [9:0]  tf_addr;
    reg  [15:0] tf_data;

    // Framebuffer ports (driven by bresenham via wireframe_gen pass-through)
    wire [13:0] fb_addr;
    wire [31:0] fb_din;
    reg  [31:0] fb_dout;
    wire        fb_wen;

    wireframe_gen u_wf (
        .clk(clk), .rst(rst), .start(start),
        .face_count(face_count), .vertex_count(vertex_count),
        .obj_addr(obj_addr), .obj_data(obj_data),
        .tf_addr(tf_addr),   .tf_data(tf_data),
        .fb_addr(fb_addr), .fb_din(fb_din),
        .fb_dout(fb_dout), .fb_wen(fb_wen),
        .done(done)
    );

    // -------------------------------------------------------------------------
    // Memories: 1-cycle read latency
    // -------------------------------------------------------------------------
    reg [15:0] tm [0:1023];
    reg [15:0] om [0:2047];
    reg [31:0] fb [0:9599];

    always @(posedge clk) begin
        tf_data  <= tm[tf_addr];
        obj_data <= om[obj_addr];
        fb_dout  <= fb[fb_addr];
        if (fb_wen) fb[fb_addr] <= fb_din;
    end

    // -------------------------------------------------------------------------
    // Preload buffers and expected-pixel bitmap
    // -------------------------------------------------------------------------
    reg [15:0] tm_init [0:1023];
    reg [15:0] om_init [0:2047];
    reg        expected_set [0:639][0:479];

    integer i, j;

    // -------------------------------------------------------------------------
    // Helpers to read framebuffer pixels at (x,y)
    // -------------------------------------------------------------------------
    function get_pixel;
        input integer x;
        input integer y;
        reg [18:0] bit_idx;
        begin
            bit_idx   = y * 640 + x;
            get_pixel = fb[bit_idx[18:5]][bit_idx[4:0]];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Test program
    // -------------------------------------------------------------------------
    integer errors;
    integer expected_count, got_count;

    initial begin
        errors = 0;

        // zero everything
        for (i = 0; i < 1024; i = i + 1) tm_init[i] = 16'h0;
        for (i = 0; i < 2048; i = i + 1) om_init[i] = 16'h0;
        for (i = 0; i < 640; i = i + 1)
            for (j = 0; j < 480; j = j + 1)
                expected_set[i][j] = 1'b0;
        for (i = 0; i < 9600; i = i + 1) fb[i] = 32'h0;


// transform_mem preload: 2 fp16 words per vertex (px, py)
        tm_init[0] = 16'h5640;   // v0.px = 100
        tm_init[1] = 16'h5240;   // v0.py = 50
        tm_init[2] = 16'h5a40;   // v1.px = 200
        tm_init[3] = 16'h58b0;   // v1.py = 150
        tm_init[4] = 16'h5240;   // v2.px = 50
        tm_init[5] = 16'h5a40;   // v2.py = 200

// obj_mem preload: vertex section unused for this test (vertices are
// already projected). Face data starts at vertex_count * 3.
        // face_base = 3 * 3 = 9
        om_init[9] = 16'h0000;
        om_init[10] = 16'h0001;
        om_init[11] = 16'h0002;

// Expected lit pixel count: 400

// Expected pixels, packed into the expected_set bitmap.
// We'll mark these in an initial block.
        expected_set[50][199] = 1'b1;
        expected_set[50][200] = 1'b1;
        expected_set[51][196] = 1'b1;
        expected_set[51][197] = 1'b1;
        expected_set[51][198] = 1'b1;
        expected_set[51][200] = 1'b1;
        expected_set[52][193] = 1'b1;
        expected_set[52][194] = 1'b1;
        expected_set[52][195] = 1'b1;
        expected_set[52][199] = 1'b1;
        expected_set[53][190] = 1'b1;
        expected_set[53][191] = 1'b1;
        expected_set[53][192] = 1'b1;
        expected_set[53][199] = 1'b1;
        expected_set[54][187] = 1'b1;
        expected_set[54][188] = 1'b1;
        expected_set[54][189] = 1'b1;
        expected_set[54][199] = 1'b1;
        expected_set[55][184] = 1'b1;
        expected_set[55][185] = 1'b1;
        expected_set[55][186] = 1'b1;
        expected_set[55][198] = 1'b1;
        expected_set[56][181] = 1'b1;
        expected_set[56][182] = 1'b1;
        expected_set[56][183] = 1'b1;
        expected_set[56][198] = 1'b1;
        expected_set[57][178] = 1'b1;
        expected_set[57][179] = 1'b1;
        expected_set[57][180] = 1'b1;
        expected_set[57][198] = 1'b1;
        expected_set[58][175] = 1'b1;
        expected_set[58][176] = 1'b1;
        expected_set[58][177] = 1'b1;
        expected_set[58][197] = 1'b1;
        expected_set[59][172] = 1'b1;
        expected_set[59][173] = 1'b1;
        expected_set[59][174] = 1'b1;
        expected_set[59][197] = 1'b1;
        expected_set[60][169] = 1'b1;
        expected_set[60][170] = 1'b1;
        expected_set[60][171] = 1'b1;
        expected_set[60][197] = 1'b1;
        expected_set[61][166] = 1'b1;
        expected_set[61][167] = 1'b1;
        expected_set[61][168] = 1'b1;
        expected_set[61][196] = 1'b1;
        expected_set[62][163] = 1'b1;
        expected_set[62][164] = 1'b1;
        expected_set[62][165] = 1'b1;
        expected_set[62][196] = 1'b1;
        expected_set[63][160] = 1'b1;
        expected_set[63][161] = 1'b1;
        expected_set[63][162] = 1'b1;
        expected_set[63][196] = 1'b1;
        expected_set[64][157] = 1'b1;
        expected_set[64][158] = 1'b1;
        expected_set[64][159] = 1'b1;
        expected_set[64][195] = 1'b1;
        expected_set[65][154] = 1'b1;
        expected_set[65][155] = 1'b1;
        expected_set[65][156] = 1'b1;
        expected_set[65][195] = 1'b1;
        expected_set[66][151] = 1'b1;
        expected_set[66][152] = 1'b1;
        expected_set[66][153] = 1'b1;
        expected_set[66][195] = 1'b1;
        expected_set[67][148] = 1'b1;
        expected_set[67][149] = 1'b1;
        expected_set[67][150] = 1'b1;
        expected_set[67][194] = 1'b1;
        expected_set[68][145] = 1'b1;
        expected_set[68][146] = 1'b1;
        expected_set[68][147] = 1'b1;
        expected_set[68][194] = 1'b1;
        expected_set[69][142] = 1'b1;
        expected_set[69][143] = 1'b1;
        expected_set[69][144] = 1'b1;
        expected_set[69][194] = 1'b1;
        expected_set[70][139] = 1'b1;
        expected_set[70][140] = 1'b1;
        expected_set[70][141] = 1'b1;
        expected_set[70][193] = 1'b1;
        expected_set[71][136] = 1'b1;
        expected_set[71][137] = 1'b1;
        expected_set[71][138] = 1'b1;
        expected_set[71][193] = 1'b1;
        expected_set[72][133] = 1'b1;
        expected_set[72][134] = 1'b1;
        expected_set[72][135] = 1'b1;
        expected_set[72][193] = 1'b1;
        expected_set[73][130] = 1'b1;
        expected_set[73][131] = 1'b1;
        expected_set[73][132] = 1'b1;
        expected_set[73][192] = 1'b1;
        expected_set[74][127] = 1'b1;
        expected_set[74][128] = 1'b1;
        expected_set[74][129] = 1'b1;
        expected_set[74][192] = 1'b1;
        expected_set[75][124] = 1'b1;
        expected_set[75][125] = 1'b1;
        expected_set[75][126] = 1'b1;
        expected_set[75][192] = 1'b1;
        expected_set[76][121] = 1'b1;
        expected_set[76][122] = 1'b1;
        expected_set[76][123] = 1'b1;
        expected_set[76][191] = 1'b1;
        expected_set[77][118] = 1'b1;
        expected_set[77][119] = 1'b1;
        expected_set[77][120] = 1'b1;
        expected_set[77][191] = 1'b1;
        expected_set[78][115] = 1'b1;
        expected_set[78][116] = 1'b1;
        expected_set[78][117] = 1'b1;
        expected_set[78][191] = 1'b1;
        expected_set[79][112] = 1'b1;
        expected_set[79][113] = 1'b1;
        expected_set[79][114] = 1'b1;
        expected_set[79][190] = 1'b1;
        expected_set[80][109] = 1'b1;
        expected_set[80][110] = 1'b1;
        expected_set[80][111] = 1'b1;
        expected_set[80][190] = 1'b1;
        expected_set[81][106] = 1'b1;
        expected_set[81][107] = 1'b1;
        expected_set[81][108] = 1'b1;
        expected_set[81][190] = 1'b1;
        expected_set[82][103] = 1'b1;
        expected_set[82][104] = 1'b1;
        expected_set[82][105] = 1'b1;
        expected_set[82][189] = 1'b1;
        expected_set[83][100] = 1'b1;
        expected_set[83][101] = 1'b1;
        expected_set[83][102] = 1'b1;
        expected_set[83][189] = 1'b1;
        expected_set[84][97] = 1'b1;
        expected_set[84][98] = 1'b1;
        expected_set[84][99] = 1'b1;
        expected_set[84][189] = 1'b1;
        expected_set[85][94] = 1'b1;
        expected_set[85][95] = 1'b1;
        expected_set[85][96] = 1'b1;
        expected_set[85][188] = 1'b1;
        expected_set[86][91] = 1'b1;
        expected_set[86][92] = 1'b1;
        expected_set[86][93] = 1'b1;
        expected_set[86][188] = 1'b1;
        expected_set[87][88] = 1'b1;
        expected_set[87][89] = 1'b1;
        expected_set[87][90] = 1'b1;
        expected_set[87][188] = 1'b1;
        expected_set[88][85] = 1'b1;
        expected_set[88][86] = 1'b1;
        expected_set[88][87] = 1'b1;
        expected_set[88][187] = 1'b1;
        expected_set[89][82] = 1'b1;
        expected_set[89][83] = 1'b1;
        expected_set[89][84] = 1'b1;
        expected_set[89][187] = 1'b1;
        expected_set[90][79] = 1'b1;
        expected_set[90][80] = 1'b1;
        expected_set[90][81] = 1'b1;
        expected_set[90][187] = 1'b1;
        expected_set[91][76] = 1'b1;
        expected_set[91][77] = 1'b1;
        expected_set[91][78] = 1'b1;
        expected_set[91][186] = 1'b1;
        expected_set[92][73] = 1'b1;
        expected_set[92][74] = 1'b1;
        expected_set[92][75] = 1'b1;
        expected_set[92][186] = 1'b1;
        expected_set[93][70] = 1'b1;
        expected_set[93][71] = 1'b1;
        expected_set[93][72] = 1'b1;
        expected_set[93][186] = 1'b1;
        expected_set[94][67] = 1'b1;
        expected_set[94][68] = 1'b1;
        expected_set[94][69] = 1'b1;
        expected_set[94][185] = 1'b1;
        expected_set[95][64] = 1'b1;
        expected_set[95][65] = 1'b1;
        expected_set[95][66] = 1'b1;
        expected_set[95][185] = 1'b1;
        expected_set[96][61] = 1'b1;
        expected_set[96][62] = 1'b1;
        expected_set[96][63] = 1'b1;
        expected_set[96][185] = 1'b1;
        expected_set[97][58] = 1'b1;
        expected_set[97][59] = 1'b1;
        expected_set[97][60] = 1'b1;
        expected_set[97][184] = 1'b1;
        expected_set[98][55] = 1'b1;
        expected_set[98][56] = 1'b1;
        expected_set[98][57] = 1'b1;
        expected_set[98][184] = 1'b1;
        expected_set[99][52] = 1'b1;
        expected_set[99][53] = 1'b1;
        expected_set[99][54] = 1'b1;
        expected_set[99][184] = 1'b1;
        expected_set[100][50] = 1'b1;
        expected_set[100][51] = 1'b1;
        expected_set[100][183] = 1'b1;
        expected_set[101][51] = 1'b1;
        expected_set[101][183] = 1'b1;
        expected_set[102][52] = 1'b1;
        expected_set[102][183] = 1'b1;
        expected_set[103][53] = 1'b1;
        expected_set[103][182] = 1'b1;
        expected_set[104][54] = 1'b1;
        expected_set[104][182] = 1'b1;
        expected_set[105][55] = 1'b1;
        expected_set[105][182] = 1'b1;
        expected_set[106][56] = 1'b1;
        expected_set[106][181] = 1'b1;
        expected_set[107][57] = 1'b1;
        expected_set[107][181] = 1'b1;
        expected_set[108][58] = 1'b1;
        expected_set[108][181] = 1'b1;
        expected_set[109][59] = 1'b1;
        expected_set[109][180] = 1'b1;
        expected_set[110][60] = 1'b1;
        expected_set[110][180] = 1'b1;
        expected_set[111][61] = 1'b1;
        expected_set[111][180] = 1'b1;
        expected_set[112][62] = 1'b1;
        expected_set[112][179] = 1'b1;
        expected_set[113][63] = 1'b1;
        expected_set[113][179] = 1'b1;
        expected_set[114][64] = 1'b1;
        expected_set[114][179] = 1'b1;
        expected_set[115][65] = 1'b1;
        expected_set[115][178] = 1'b1;
        expected_set[116][66] = 1'b1;
        expected_set[116][178] = 1'b1;
        expected_set[117][67] = 1'b1;
        expected_set[117][178] = 1'b1;
        expected_set[118][68] = 1'b1;
        expected_set[118][177] = 1'b1;
        expected_set[119][69] = 1'b1;
        expected_set[119][177] = 1'b1;
        expected_set[120][70] = 1'b1;
        expected_set[120][177] = 1'b1;
        expected_set[121][71] = 1'b1;
        expected_set[121][176] = 1'b1;
        expected_set[122][72] = 1'b1;
        expected_set[122][176] = 1'b1;
        expected_set[123][73] = 1'b1;
        expected_set[123][176] = 1'b1;
        expected_set[124][74] = 1'b1;
        expected_set[124][175] = 1'b1;
        expected_set[125][75] = 1'b1;
        expected_set[125][175] = 1'b1;
        expected_set[126][76] = 1'b1;
        expected_set[126][175] = 1'b1;
        expected_set[127][77] = 1'b1;
        expected_set[127][174] = 1'b1;
        expected_set[128][78] = 1'b1;
        expected_set[128][174] = 1'b1;
        expected_set[129][79] = 1'b1;
        expected_set[129][174] = 1'b1;
        expected_set[130][80] = 1'b1;
        expected_set[130][173] = 1'b1;
        expected_set[131][81] = 1'b1;
        expected_set[131][173] = 1'b1;
        expected_set[132][82] = 1'b1;
        expected_set[132][173] = 1'b1;
        expected_set[133][83] = 1'b1;
        expected_set[133][172] = 1'b1;
        expected_set[134][84] = 1'b1;
        expected_set[134][172] = 1'b1;
        expected_set[135][85] = 1'b1;
        expected_set[135][172] = 1'b1;
        expected_set[136][86] = 1'b1;
        expected_set[136][171] = 1'b1;
        expected_set[137][87] = 1'b1;
        expected_set[137][171] = 1'b1;
        expected_set[138][88] = 1'b1;
        expected_set[138][171] = 1'b1;
        expected_set[139][89] = 1'b1;
        expected_set[139][170] = 1'b1;
        expected_set[140][90] = 1'b1;
        expected_set[140][170] = 1'b1;
        expected_set[141][91] = 1'b1;
        expected_set[141][170] = 1'b1;
        expected_set[142][92] = 1'b1;
        expected_set[142][169] = 1'b1;
        expected_set[143][93] = 1'b1;
        expected_set[143][169] = 1'b1;
        expected_set[144][94] = 1'b1;
        expected_set[144][169] = 1'b1;
        expected_set[145][95] = 1'b1;
        expected_set[145][168] = 1'b1;
        expected_set[146][96] = 1'b1;
        expected_set[146][168] = 1'b1;
        expected_set[147][97] = 1'b1;
        expected_set[147][168] = 1'b1;
        expected_set[148][98] = 1'b1;
        expected_set[148][167] = 1'b1;
        expected_set[149][99] = 1'b1;
        expected_set[149][167] = 1'b1;
        expected_set[150][100] = 1'b1;
        expected_set[150][167] = 1'b1;
        expected_set[151][101] = 1'b1;
        expected_set[151][166] = 1'b1;
        expected_set[152][102] = 1'b1;
        expected_set[152][166] = 1'b1;
        expected_set[153][103] = 1'b1;
        expected_set[153][166] = 1'b1;
        expected_set[154][104] = 1'b1;
        expected_set[154][165] = 1'b1;
        expected_set[155][105] = 1'b1;
        expected_set[155][165] = 1'b1;
        expected_set[156][106] = 1'b1;
        expected_set[156][165] = 1'b1;
        expected_set[157][107] = 1'b1;
        expected_set[157][164] = 1'b1;
        expected_set[158][108] = 1'b1;
        expected_set[158][164] = 1'b1;
        expected_set[159][109] = 1'b1;
        expected_set[159][164] = 1'b1;
        expected_set[160][110] = 1'b1;
        expected_set[160][163] = 1'b1;
        expected_set[161][111] = 1'b1;
        expected_set[161][163] = 1'b1;
        expected_set[162][112] = 1'b1;
        expected_set[162][163] = 1'b1;
        expected_set[163][113] = 1'b1;
        expected_set[163][162] = 1'b1;
        expected_set[164][114] = 1'b1;
        expected_set[164][162] = 1'b1;
        expected_set[165][115] = 1'b1;
        expected_set[165][162] = 1'b1;
        expected_set[166][116] = 1'b1;
        expected_set[166][161] = 1'b1;
        expected_set[167][117] = 1'b1;
        expected_set[167][161] = 1'b1;
        expected_set[168][118] = 1'b1;
        expected_set[168][161] = 1'b1;
        expected_set[169][119] = 1'b1;
        expected_set[169][160] = 1'b1;
        expected_set[170][120] = 1'b1;
        expected_set[170][160] = 1'b1;
        expected_set[171][121] = 1'b1;
        expected_set[171][160] = 1'b1;
        expected_set[172][122] = 1'b1;
        expected_set[172][159] = 1'b1;
        expected_set[173][123] = 1'b1;
        expected_set[173][159] = 1'b1;
        expected_set[174][124] = 1'b1;
        expected_set[174][159] = 1'b1;
        expected_set[175][125] = 1'b1;
        expected_set[175][158] = 1'b1;
        expected_set[176][126] = 1'b1;
        expected_set[176][158] = 1'b1;
        expected_set[177][127] = 1'b1;
        expected_set[177][158] = 1'b1;
        expected_set[178][128] = 1'b1;
        expected_set[178][157] = 1'b1;
        expected_set[179][129] = 1'b1;
        expected_set[179][157] = 1'b1;
        expected_set[180][130] = 1'b1;
        expected_set[180][157] = 1'b1;
        expected_set[181][131] = 1'b1;
        expected_set[181][156] = 1'b1;
        expected_set[182][132] = 1'b1;
        expected_set[182][156] = 1'b1;
        expected_set[183][133] = 1'b1;
        expected_set[183][156] = 1'b1;
        expected_set[184][134] = 1'b1;
        expected_set[184][155] = 1'b1;
        expected_set[185][135] = 1'b1;
        expected_set[185][155] = 1'b1;
        expected_set[186][136] = 1'b1;
        expected_set[186][155] = 1'b1;
        expected_set[187][137] = 1'b1;
        expected_set[187][154] = 1'b1;
        expected_set[188][138] = 1'b1;
        expected_set[188][154] = 1'b1;
        expected_set[189][139] = 1'b1;
        expected_set[189][154] = 1'b1;
        expected_set[190][140] = 1'b1;
        expected_set[190][153] = 1'b1;
        expected_set[191][141] = 1'b1;
        expected_set[191][153] = 1'b1;
        expected_set[192][142] = 1'b1;
        expected_set[192][153] = 1'b1;
        expected_set[193][143] = 1'b1;
        expected_set[193][152] = 1'b1;
        expected_set[194][144] = 1'b1;
        expected_set[194][152] = 1'b1;
        expected_set[195][145] = 1'b1;
        expected_set[195][152] = 1'b1;
        expected_set[196][146] = 1'b1;
        expected_set[196][151] = 1'b1;
        expected_set[197][147] = 1'b1;
        expected_set[197][151] = 1'b1;
        expected_set[198][148] = 1'b1;
        expected_set[198][151] = 1'b1;
        expected_set[199][149] = 1'b1;
        expected_set[199][150] = 1'b1;
        expected_set[200][150] = 1'b1;

        // Copy initial values into the simulated memories
        for (i = 0; i < 1024; i = i + 1) tm[i] = tm_init[i];
        for (i = 0; i < 2048; i = i + 1) om[i] = om_init[i];

        // Reset
        rst = 1; start = 0;
        face_count   = FC[7:0];
        vertex_count = VC[7:0];
        tf_data = 0; obj_data = 0; fb_dout = 0;
        @(negedge clk); @(negedge clk);
        rst = 0;
        @(negedge clk);

        // Start
        start = 1;
        @(negedge clk);
        start = 0;

        // Wait for done
        $display("=== wireframe_gen test ===");
        @(posedge done);
        @(negedge clk);
        $display("done asserted");

        // Compare framebuffer against expected_set
        expected_count = 0;
        got_count      = 0;
        for (i = 0; i < 640; i = i + 1) begin
            for (j = 0; j < 480; j = j + 1) begin
                if (expected_set[i][j]) expected_count = expected_count + 1;
                if (get_pixel(i, j))    got_count      = got_count + 1;

                if (expected_set[i][j] !== get_pixel(i, j)) begin
                    if (errors < 20) begin
                        $display("  FAIL pix (%0d,%0d): expected %0b got %0b",
                                 i, j, expected_set[i][j], get_pixel(i,j));
                    end
                    errors = errors + 1;
                end
            end
        end

        $display("expected %0d pixels, got %0d", expected_count, got_count);
        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d MISMATCH(ES)", errors);
        $finish;
    end

    initial begin
        #50000000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
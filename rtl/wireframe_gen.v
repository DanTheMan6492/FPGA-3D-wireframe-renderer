// =============================================================================
// wireframe_gen.v  —  Per-face wireframe rasterizer
// =============================================================================
// For each of `face_count` faces:
//   1. Read three vertex indices a, b, c from obj_mem at addresses
//      face_base + 3i, +1, +2  where face_base = vertex_count * 3.
//   2. For each of a, b, c: read px, py from transform_mem (2v, 2v+1).
//   3. Convert fp16 pixel coords to clamped integer pixel coords.
//   4. Invoke the bresenham submodule three times (edges AB, BC, CA),
//      waiting for its `done` between edges.
//   5. Advance to the next face. After the last face, assert done.
//
// Memory access pattern uses the same "address two states before latch"
// pattern as perspective_divide, accommodating the 1-cycle SDPRAM read
// latency in a way that resolves cleanly when both port driver and
// consumer are registered.
// =============================================================================


module wireframe_gen (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [7:0]  face_count,
    input  wire [7:0]  vertex_count,

    // obj_mem read port
    output reg  [10:0] obj_addr,
    input  wire [15:0] obj_data,

    // transform_mem read port
    output reg  [9:0]  tf_addr,
    input  wire [15:0] tf_data,

    // framebuffer write port (passed through to bresenham)
    output wire [13:0] fb_addr,
    output wire [31:0] fb_din,
    input  wire [31:0] fb_dout,
    output wire        fb_wen,

    output reg         done
);

    // -------------------------------------------------------------------------
    // bresenham submodule + its control signals
    // -------------------------------------------------------------------------
    reg         br_start;
    reg  [9:0]  br_x0, br_y0, br_x1, br_y1;
    wire        br_done;

    bresenham u_bres (
        .clk     (clk),
        .rst     (rst),
        .start   (br_start),
        .x0      (br_x0), .y0(br_y0),
        .x1      (br_x1), .y1(br_y1),
        .fb_addr (fb_addr),
        .fb_din  (fb_din),
        .fb_dout (fb_dout),
        .fb_wen  (fb_wen),
        .done    (br_done)
    );

    // -------------------------------------------------------------------------
    // Per-face latched data
    //   face_base  = vertex_count * 3 (computed on start)
    //   face_idx   = current face counter
    //   idx_a/b/c  = vertex indices for this face
    //   pax/pay/.. = fp16 pixel coordinates of the three vertices
    // -------------------------------------------------------------------------
    reg  [10:0] face_base;
    reg  [7:0]  face_idx;
    reg  [7:0]  idx_a, idx_b, idx_c;
    reg  [15:0] pax, pay, pbx, pby, pcx, pcy;

    // -------------------------------------------------------------------------
    // fp16 -> int conversion + clamp for the three vertices.
    // Use WIDTH=12 to give saturation headroom; clamp into screen bounds
    // [0,639]x[0,479] afterwards.
    // -------------------------------------------------------------------------
    wire signed [11:0] ax_i, ay_i, bx_i, by_i, cx_i, cy_i;
    fp16_to_int #(.WIDTH(12)) u_ax (.fp16_in(pax), .int_out(ax_i));
    fp16_to_int #(.WIDTH(12)) u_ay (.fp16_in(pay), .int_out(ay_i));
    fp16_to_int #(.WIDTH(12)) u_bx (.fp16_in(pbx), .int_out(bx_i));
    fp16_to_int #(.WIDTH(12)) u_by (.fp16_in(pby), .int_out(by_i));
    fp16_to_int #(.WIDTH(12)) u_cx (.fp16_in(pcx), .int_out(cx_i));
    fp16_to_int #(.WIDTH(12)) u_cy (.fp16_in(pcy), .int_out(cy_i));

    // Clamp to screen bounds. Negative -> 0; > 639 -> 639; > 479 -> 479.
    function [9:0] clamp_x;
        input signed [11:0] v;
        begin
            if (v < 0)            clamp_x = 10'd0;
            else if (v > 12'sd639) clamp_x = 10'd639;
            else                   clamp_x = v[9:0];
        end
    endfunction

    function [9:0] clamp_y;
        input signed [11:0] v;
        begin
            if (v < 0)            clamp_y = 10'd0;
            else if (v > 12'sd479) clamp_y = 10'd479;
            else                   clamp_y = v[9:0];
        end
    endfunction

    wire [9:0] ax = clamp_x(ax_i);
    wire [9:0] ay = clamp_y(ay_i);
    wire [9:0] bx = clamp_x(bx_i);
    wire [9:0] by = clamp_y(by_i);
    wire [9:0] cx = clamp_x(cx_i);
    wire [9:0] cy = clamp_y(cy_i);

    // -------------------------------------------------------------------------
    // FSM
    //
    //   IDLE        — wait for start, latch face_base.
    //
    //   For each face, we run a per-face read sequence with the
    //   "address two states before latch" pattern:
    //
    //   FETCH_A   — present obj_addr = face_base + 3*face_idx (idx_a)
    //   FETCH_B   — present face_base + 3*face_idx + 1        (idx_b)
    //   FETCH_C   — present face_base + 3*face_idx + 2 (idx_c); latch idx_a
    //   WAIT_B    — latch idx_b
    //   WAIT_C    — latch idx_c
    //   Then vertex coordinate reads — six reads total (pax, pay, pbx, pby,
    //   pcx, pcy). With 1-cycle latency, the pattern is the same: each
    //   latch trails its address by two states. So:
    //   READV0    — present 2*idx_a
    //   READV1    — present 2*idx_a + 1
    //   READV2    — present 2*idx_b;     latch pax
    //   READV3    — present 2*idx_b + 1; latch pay
    //   READV4    — present 2*idx_c;     latch pbx
    //   READV5    — present 2*idx_c + 1; latch pby
    //   WAITVA    — latch pcx
    //   WAITVB    — latch pcy
    //
    //   DRAW_AB   — pulse br_start with endpoints A,B; wait br_done
    //   DRAW_BC   — pulse br_start with endpoints B,C; wait br_done
    //   DRAW_CA   — pulse br_start with endpoints C,A; wait br_done
    //   NEXT      — increment face_idx, loop or finish
    //   DONE_S    — pulse done, return to IDLE
    // -------------------------------------------------------------------------
    localparam
        IDLE     = 5'd0,
        FETCH_A  = 5'd1,
        FETCH_B  = 5'd2,
        FETCH_C  = 5'd3,
        WAIT_B   = 5'd4,
        WAIT_C   = 5'd5,
        READV0   = 5'd6,
        READV1   = 5'd7,
        READV2   = 5'd8,
        READV3   = 5'd9,
        READV4   = 5'd10,
        READV5   = 5'd11,
        WAITVA   = 5'd12,
        WAITVB   = 5'd13,
        DRAW_AB_START = 5'd14,
        DRAW_AB_WAIT  = 5'd15,
        DRAW_BC_START = 5'd16,
        DRAW_BC_WAIT  = 5'd17,
        DRAW_CA_START = 5'd18,
        DRAW_CA_WAIT  = 5'd19,
        NEXT     = 5'd20,
        DONE_S   = 5'd21;
    reg [4:0] state;

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            face_idx <= 0;
            done     <= 1'b0;
            br_start <= 1'b0;
        end else begin
            done     <= 1'b0;
            br_start <= 1'b0;

            case (state)

            IDLE: if (start) begin
                face_idx  <= 0;
                face_base <= vertex_count * 11'd3;
                state     <= FETCH_A;
            end

            // ---------- Face-index reads (3 words) ----------
            FETCH_A: begin
                obj_addr <= face_base + face_idx * 11'd3 + 11'd0;
                state    <= FETCH_B;
            end

            FETCH_B: begin
                obj_addr <= face_base + face_idx * 11'd3 + 11'd1;
                state    <= FETCH_C;
            end

            FETCH_C: begin
                obj_addr <= face_base + face_idx * 11'd3 + 11'd2;
                idx_a    <= obj_data[7:0];     // first read result usable now
                state    <= WAIT_B;
            end

            WAIT_B: begin
                idx_b <= obj_data[7:0];
                state <= WAIT_C;
            end

            WAIT_C: begin
                idx_c <= obj_data[7:0];
                state <= READV0;
            end

            // ---------- Vertex-coordinate reads (6 words) ----------
            // We use idx_a/b/c (now latched) to address transform_mem.
            READV0: begin
                tf_addr <= {1'b0, idx_a, 1'b0};   // 2*idx_a
                state   <= READV1;
            end

            READV1: begin
                tf_addr <= {1'b0, idx_a, 1'b1};   // 2*idx_a + 1
                state   <= READV2;
            end

            READV2: begin
                tf_addr <= {1'b0, idx_b, 1'b0};
                pax     <= tf_data;
                state   <= READV3;
            end

            READV3: begin
                tf_addr <= {1'b0, idx_b, 1'b1};
                pay     <= tf_data;
                state   <= READV4;
            end

            READV4: begin
                tf_addr <= {1'b0, idx_c, 1'b0};
                pbx     <= tf_data;
                state   <= READV5;
            end

            READV5: begin
                tf_addr <= {1'b0, idx_c, 1'b1};
                pby     <= tf_data;
                state   <= WAITVA;
            end

            WAITVA: begin
                pcx   <= tf_data;
                state <= WAITVB;
            end

            WAITVB: begin
                pcy   <= tf_data;
                state <= DRAW_AB_START;
            end

            // ---------- Edge AB ----------
            DRAW_AB_START: begin
                br_x0 <= ax; br_y0 <= ay;
                br_x1 <= bx; br_y1 <= by;
                br_start <= 1'b1;
                state    <= DRAW_AB_WAIT;
            end
            DRAW_AB_WAIT: if (br_done) state <= DRAW_BC_START;

            // ---------- Edge BC ----------
            DRAW_BC_START: begin
                br_x0 <= bx; br_y0 <= by;
                br_x1 <= cx; br_y1 <= cy;
                br_start <= 1'b1;
                state    <= DRAW_BC_WAIT;
            end
            DRAW_BC_WAIT: if (br_done) state <= DRAW_CA_START;

            // ---------- Edge CA ----------
            DRAW_CA_START: begin
                br_x0 <= cx; br_y0 <= cy;
                br_x1 <= ax; br_y1 <= ay;
                br_start <= 1'b1;
                state    <= DRAW_CA_WAIT;
            end
            DRAW_CA_WAIT: if (br_done) state <= NEXT;

            // ---------- Next face ----------
            NEXT: begin
                if (face_idx == face_count - 1) begin
                    state <= DONE_S;
                end else begin
                    face_idx <= face_idx + 1;
                    state    <= FETCH_A;
                end
            end

            DONE_S: begin
                done  <= 1'b1;
                state <= IDLE;
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule
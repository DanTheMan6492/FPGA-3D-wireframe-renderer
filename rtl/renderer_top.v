// =============================================================================
// renderer_top.v  -  Top-level module for the FPGA 3D wireframe renderer
// =============================================================================
`timescale 1ns / 1ps

module renderer_top #(
    // Maximum absolute rotation speed (per axis). Speed is signed: at +/-MAX
    // the angle advances by ~MAX/256 of a full turn per frame.
    parameter SPEED_MAX = 8,

    // Default mesh preload. When INIT_VERTEX_COUNT is non-zero, the FPGA
    // boots showing a mesh defined by:
    //   - vertex_count / face_count: INIT_VERTEX_COUNT / INIT_FACE_COUNT
    //   - obj_mem contents:           OBJ_MEM_INIT_FILE
    //
    // Generate OBJ_MEM_INIT_FILE with:
    //   python3 upload_obj.py model.obj --obj-mem-hex data/default.hex
    // and set the parameters here to match the V/F it reports.
    //
    // Leave V/F at zero (or the file at "none") to boot empty.
    parameter [7:0] INIT_VERTEX_COUNT  = 8'd8,
    parameter [7:0] INIT_FACE_COUNT    = 8'd12,
    parameter       OBJ_MEM_INIT_FILE  = "cube_obj_mem.mem"
)(
    // -------- Clocks and reset --------
    input  wire        clk_in,         // 100 MHz from board oscillator
    input  wire        rst_btn,        // synchronous reset, active-high

    // -------- UART --------
    input  wire        uart_rx_pin,

    // -------- Buttons --------
    input  wire        btn_up,
    input  wire        btn_down,
    input  wire        btn_left,
    input  wire        btn_right,

    // -------- VGA --------
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,

    // -------- 7-segment display --------
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an
);

    // =========================================================================
    // CLOCKING
    //
    // The MMCM produces clk_sys (100 MHz) and clk_pix (25 MHz). Both are
    // derived from the same source so every 4th edge of clk_sys aligns with
    // an edge of clk_pix - there's no asynchronous CDC, just a known phase
    // relationship.
    //
    // `locked` from the MMCM is held low for a few cycles until both clocks
    // stabilize; we use it to qualify reset assertion so the rest of the
    // design starts with stable clocks.
    // =========================================================================
    wire clk;       // 100 MHz system clock - used by everything except VGA
    wire clk_pix;   // 25 MHz pixel clock - used by vga_controller and fb port B
    wire mmcm_locked;

    clock_gen u_clock_gen (
        .clk_in  (clk_in),
        .clk_sys (clk),
        .clk_pix (clk_pix),
        .locked  (mmcm_locked)
    );

    // Synchronous reset, active high. Sampled into `rst` so it's clean.
    // Also held high while the MMCM hasn't locked.
    reg [1:0] rst_sync;
    always @(posedge clk) rst_sync <= {rst_sync[0], rst_btn | ~mmcm_locked};
    wire rst = rst_sync[1];

    // =========================================================================
    // UART INTAKE PATH (always on)
    //   uart_rx ? uart_packet_decoder ? shadow_mem
    // =========================================================================
    wire [7:0]  uart_byte;
    wire        uart_byte_valid;

    uart_rx #(
        .CLK_FREQ  (50_000_000),   // system clock is 50 MHz (MMCM CLKOUT0)
        .BAUD_RATE (9_600)
    ) u_uart_rx (
        .clk   (clk),
        .rst   (rst),
        .rx    (uart_rx_pin),
        .data  (uart_byte),
        .valid (uart_byte_valid)
    );

    // Latched header values + status from the packet decoder
    wire [7:0]  vertex_count;
    wire [7:0]  face_count;
    wire        upload_writing;
    wire        new_data_flag;

    // Top-level acknowledgement pulse to the packet decoder - pulses on
    // entry to S_SWAP to clear new_data_flag so we won't re-enter SWAP next
    // frame if no new packet has arrived.
    wire new_data_ack = enter_swap;

    // shadow_mem write port driven by the packet decoder
    wire [10:0] shadow_wr_addr;
    wire [7:0]  shadow_wr_data;
    wire        shadow_wr_en;

    uart_packet_decoder #(
        .INIT_VERTEX_COUNT (INIT_VERTEX_COUNT),
        .INIT_FACE_COUNT   (INIT_FACE_COUNT)
    ) u_packet_decoder (
        .clk           (clk),
        .rst           (rst),
        .byte_data     (uart_byte),
        .byte_valid    (uart_byte_valid),

        .mem_addr      (shadow_wr_addr),
        .mem_data      (shadow_wr_data),
        .mem_wen       (shadow_wr_en),

        .vertex_count  (vertex_count),
        .face_count    (face_count),
        .writing       (upload_writing),
        .new_data_flag (new_data_flag),
        .flag_clear    (new_data_ack)
    );

    // =========================================================================
    // BUTTON DEBOUNCERS + EDGE DETECT ? SPEED REGISTERS (always on)
    //
    // Each button is debounced to a stable level, then edge-detected to a
    // one-cycle pulse. Each pulse increments or decrements the corresponding
    // axis's speed, saturating at ?SPEED_MAX.
    //
    //   up    ? speed_y += 1   (capped at +SPEED_MAX)
    //   down  ? speed_y -= 1   (capped at -SPEED_MAX)
    //   left  ? speed_x -= 1
    //   right ? speed_x += 1
    // =========================================================================
    wire btn_up_db, btn_down_db, btn_left_db, btn_right_db;

    debouncer u_db_up    (.clk(clk), .btn_in(btn_up),    .btn_out(btn_up_db));
    debouncer u_db_down  (.clk(clk), .btn_in(btn_down),  .btn_out(btn_down_db));
    debouncer u_db_left  (.clk(clk), .btn_in(btn_left),  .btn_out(btn_left_db));
    debouncer u_db_right (.clk(clk), .btn_in(btn_right), .btn_out(btn_right_db));

    // One-cycle rising-edge pulses
    reg btn_up_prev, btn_down_prev, btn_left_prev, btn_right_prev;
    always @(posedge clk) begin
        btn_up_prev    <= btn_up_db;
        btn_down_prev  <= btn_down_db;
        btn_left_prev  <= btn_left_db;
        btn_right_prev <= btn_right_db;
    end
    wire up_edge    =  btn_up_db    & ~btn_up_prev;
    wire down_edge  =  btn_down_db  & ~btn_down_prev;
    wire left_edge  =  btn_left_db  & ~btn_left_prev;
    wire right_edge =  btn_right_db & ~btn_right_prev;

    // Speed registers. Signed 8-bit so wrap-around against the 8-bit angle
    // is automatic; saturation is enforced against SPEED_MAX as an int.
    reg signed [7:0] speed_x;
    reg signed [7:0] speed_y;

    always @(posedge clk) begin
        if (rst) begin
            speed_x <= 8'sd0;
            speed_y <= 8'sd0;
        end else begin
            // Y axis: up increments, down decrements
            if (up_edge && speed_y < $signed(SPEED_MAX))
                speed_y <= speed_y + 8'sd1;
            else if (down_edge && speed_y > -$signed(SPEED_MAX))
                speed_y <= speed_y - 8'sd1;

            // X axis: right increments, left decrements
            if (right_edge && speed_x < $signed(SPEED_MAX))
                speed_x <= speed_x + 8'sd1;
            else if (left_edge && speed_x > -$signed(SPEED_MAX))
                speed_x <= speed_x - 8'sd1;
        end
    end

    // =========================================================================
    // MEMORIES
    //
    // Five SDPRAM instances, all wrapped in mem_sdpram (xpm_memory_sdpram with
    // common clock, 1-cycle read latency, sync reset).
    //
    //   shadow_mem:      8-bit  x 2048   - UART staging buffer
    //   obj_mem:         16-bit x 2048   - fp16 verts + zero-extended face idx
    //   transform_mem:   16-bit x 1024   - MVP at 0..15, per-vertex data above
    //   framebuffer A:   32-bit x 9600   - one of two double-buffered frames
    //   framebuffer B:   32-bit x 9600   - the other
    //
    // Each memory's port-A (write) and port-B (read) inputs are driven by
    // muxes downstream of the FSM. Until the muxes are in place, the unused
    // ports are tied off here - they'll get connected up as the FSM is built.
    // =========================================================================

    // shadow_mem read port - addressed by the inline SWAP FSM. Tied to 0
    // when SWAP isn't running, which is harmless (the read port is unused
    // outside SWAP).
    reg [10:0] shadow_rd_addr;
    always @(*) shadow_rd_addr = sw_shadow_addr;
    wire [7:0]  shadow_rd_data;

    mem_sdpram #(.WIDTH(8), .DEPTH(2048), .ADDR_WIDTH(11)) u_shadow_mem (
        .clk   (clk),
        .clkb  (clk),
        .rst   (rst),
        .wea   (shadow_wr_en),
        .addra (shadow_wr_addr),
        .dina  (shadow_wr_data),
        .addrb (shadow_rd_addr),
        .doutb (shadow_rd_data)
    );

    // obj_mem - write port driven by SWAP, read port muxed between
    // TRANSFORM_VERT (vertex coords) and RENDER (face indices).
    wire         obj_wr_en;
    wire [10:0]  obj_wr_addr;
    wire [15:0]  obj_wr_data;
    wire [10:0]  obj_rd_addr;
    wire [15:0]  obj_rd_data;

    mem_sdpram #(
        .WIDTH(16),
        .DEPTH(2048),
        .ADDR_WIDTH(11),
        .MEMORY_INIT_FILE(OBJ_MEM_INIT_FILE)
    ) u_obj_mem (
        .clk   (clk),
        .clkb  (clk),
        .rst   (rst),
        .wea   (obj_wr_en),
        .addra (obj_wr_addr),
        .dina  (obj_wr_data),
        .addrb (obj_rd_addr),
        .doutb (obj_rd_data)
    );

    // transform_mem - write port muxed (MVP_matrix_maker / vertex-batch /
    // perspective_divide); read port muxed (vertex-batch / perspective_divide
    // / wireframe_gen).
    wire         tm_wr_en;
    wire [9:0]   tm_wr_addr;
    wire [15:0]  tm_wr_data;
    wire [9:0]   tm_rd_addr;
    wire [15:0]  tm_rd_data;

    mem_sdpram #(.WIDTH(16), .DEPTH(1024)) u_transform_mem (
        .clk   (clk),
        .clkb  (clk),
        .rst   (rst),
        .wea   (tm_wr_en),
        .addra (tm_wr_addr),
        .dina  (tm_wr_data),
        .addrb (tm_rd_addr),
        .doutb (tm_rd_data)
    );

    // Two framebuffers. Port A: 32-bit write (framebuffer_clear / wireframe_gen
    // - muxed by FSM via fb_writer). Port B: 32-bit read (VGA adapter on the
    // FRONT buffer; wireframe_gen RMW read on the BACK buffer).
    //
    // The front/back routing is done by a single mux on `front_buf`.
    wire         fb_a_wr_en;
    wire [13:0]  fb_a_wr_addr;
    wire [31:0]  fb_a_wr_data;
    wire [13:0]  fb_a_rd_addr;
    wire [31:0]  fb_a_rd_data;

    // fb_a: framebuffer A. Port A serves both the renderer-side write
    // (framebuffer_clear / wireframe_gen) and the wireframe_gen RMW read.
    // Port B is read-only by vga_controller at 25 MHz.
    wire [31:0] fb_a_rd_data_pa;   // 100 MHz read for wireframe_gen RMW

    mem_tdpram #(.WIDTH(32), .DEPTH(9600)) u_fb_a (
        .clka  (clk),         // 100 MHz for renderer port
        .clkb  (clk_pix),     // 25 MHz for VGA reads
        .rst   (rst),
        .wea   (fb_a_wr_en),
        .addra (fb_a_wr_addr),
        .dina  (fb_a_wr_data),
        .douta (fb_a_rd_data_pa),
        .addrb (fb_a_rd_addr),
        .doutb (fb_a_rd_data)
    );

    wire         fb_b_wr_en;
    wire [13:0]  fb_b_wr_addr;
    wire [31:0]  fb_b_wr_data;
    wire [13:0]  fb_b_rd_addr;
    wire [31:0]  fb_b_rd_data;

    wire [31:0] fb_b_rd_data_pa;   // 100 MHz read for wireframe_gen RMW

    mem_tdpram #(.WIDTH(32), .DEPTH(9600)) u_fb_b (
        .clka  (clk),         // 100 MHz for renderer port
        .clkb  (clk_pix),     // 25 MHz for VGA reads
        .rst   (rst),
        .wea   (fb_b_wr_en),
        .addra (fb_b_wr_addr),
        .dina  (fb_b_wr_data),
        .douta (fb_b_rd_data_pa),
        .addrb (fb_b_rd_addr),
        .doutb (fb_b_rd_data)
    );

    // front_buf register: which framebuffer is "front" (VGA reads) vs "back"
    // (writers target). Flips on the rising edge of vblank.
    reg front_buf;
    always @(posedge clk) begin
        if (rst)              front_buf <= 1'b0;
        else if (vblank_rise) front_buf <= ~front_buf;
    end

    // =========================================================================
    // SEVEN-SEGMENT DISPLAY (always on)
    // =========================================================================
    (* KEEP_HIERARCHY = "YES" *)
    display_top #(.REFRESH_BITS(18)) u_display (
        .clk           (clk),
        .vertex_count  (vertex_count),
        .face_count    (face_count),
        .seg           (seg),
        .dp            (dp),
        .an            (an)
    );

    // =========================================================================
    // VGA CONTROLLER (always on)
    //
    // Reads from the FRONT framebuffer's port B at 25 MHz. The fb_addr it
    // produces is registered in the 25 MHz domain; both framebuffer port B
    // address lines see it (the unused one is ignored).
    //
    // vblank is asserted for the full vertical blanking interval. The
    // rising-edge detector in the FSM block triggers off it; since the
    // pulse is held for ~1.4 ms (>144k system-clock cycles), the FSM sees
    // a clean rising edge.
    //
    // vga_fb_addr and vga_fb_dout are connected through the swap mux below.
    // Forward-declared here so they can be used in the instance binding.
    // =========================================================================
    wire [13:0] vga_fb_addr;
    wire [31:0] vga_fb_dout;
    wire vblank_raw;

    vga_controller u_vga (
        .clk_25mhz (clk_pix),
        .fb_addr   (vga_fb_addr),
        .fb_dout   (vga_fb_dout),
        .vga_r     (vga_r),
        .vga_g     (vga_g),
        .vga_b     (vga_b),
        .vga_hsync (vga_hsync),
        .vga_vsync (vga_vsync),
        .vblank    (vblank_raw)
    );

    // vblank is in the 25 MHz pixel-clock domain. Bring it into the 100 MHz
    // system-clock domain with a single FF for register balance. Since vblank
    // is held high for ~1.4 ms (well over a million 100 MHz cycles) and the
    // two clocks are phase-aligned, a single FF is sufficient - the FSM sees
    // a clean rising edge.
    reg vblank_q;
    always @(posedge clk) vblank_q <= vblank_raw;
    wire vblank = vblank_q;

    // =========================================================================
    // FRAME PIPELINE FSM
    //
    // Sequences the per-frame compute pipeline:
    //   IDLE -> SWAP -> TRANSFORM_MVP -> TRANSFORM_VERT
    //                                       \-> PROJECT -> CLEAR_WAIT -> RENDER -> IDLE
    //
    // IDLE on each vblank edge either drops into SWAP (if a new UART upload
    // is ready) or skips straight to TRANSFORM_MVP. If a UART upload is
    // still streaming when vblank fires, IDLE loops one more frame.
    //
    // This block ONLY tracks state and transitions. It does not yet drive
    // any submodules, memory muxes, or start pulses - those come in
    // subsequent passes. The `done` / `busy` signals it observes are
    // currently tied to 0 stubs below, so transitions out of every state
    // except IDLE will never fire in simulation until the real submodules
    // are connected.
    // =========================================================================

    // ---- Submodule done / busy signals --------------------------------------
    // These are the real signals from the submodule instances declared further
    // below. swap_done and vert_batch_done are still stubs since their inline
    // FSMs aren't implemented yet.
    wire swap_done       = sw_done_pulse;   // from inline SWAP FSM
    wire vert_batch_done = vb_done_r;       // from inline vertex-batch FSM
    wire mvp_done        = mvp_done_w;
    wire pd_done         = pd_done_w;
    wire clear_busy      = fbc_busy;
    wire wfg_done        = wfg_done_w;

    // ---- vblank rising-edge detector ----------------------------------------
    // vblank is currently tied to 0 (vga_controller stub). Once vga_controller
    // is real, this edge detector will provide a one-cycle pulse per frame.
    reg vblank_prev;
    always @(posedge clk) vblank_prev <= vblank;
    wire vblank_rise = vblank & ~vblank_prev;

    // ---- FSM state encoding -------------------------------------------------
    localparam [2:0] S_IDLE           = 3'd0;
    localparam [2:0] S_SWAP           = 3'd1;
    localparam [2:0] S_TRANSFORM_MVP  = 3'd2;
    localparam [2:0] S_TRANSFORM_VERT = 3'd3;
    localparam [2:0] S_PROJECT        = 3'd4;
    localparam [2:0] S_CLEAR_WAIT     = 3'd5;
    localparam [2:0] S_RENDER         = 3'd6;
    reg [2:0] state;

    // ---- Transitions --------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)

            // -----------------------------------------------------------------
            // IDLE - at each vblank, decide whether to ingest a new upload or
            // jump straight into the rendering pipeline. A UART packet still
            // in progress keeps us in IDLE for one more frame.
            // -----------------------------------------------------------------
            S_IDLE: if (vblank_rise) begin
                if (new_data_flag && !upload_writing) state <= S_SWAP;
                else if (!new_data_flag)              state <= S_TRANSFORM_MVP;
                // else: new_data_flag set but upload still in progress -> stay
            end

            // -----------------------------------------------------------------
            // SWAP - inline FSM (TODO) drains shadow_mem into obj_mem.
            // -----------------------------------------------------------------
            S_SWAP: if (swap_done) state <= S_TRANSFORM_MVP;

            // -----------------------------------------------------------------
            // TRANSFORM_MVP - MVP_matrix_maker (TODO) builds the MVP matrix.
            // -----------------------------------------------------------------
            S_TRANSFORM_MVP: if (mvp_done) state <= S_TRANSFORM_VERT;

            // -----------------------------------------------------------------
            // TRANSFORM_VERT - vertex-batch FSM (TODO) tiles vertices through
            // mat_mul.
            // -----------------------------------------------------------------
            S_TRANSFORM_VERT: if (vert_batch_done) state <= S_PROJECT;

            // -----------------------------------------------------------------
            // PROJECT - perspective_divide (TODO) computes pixel coords.
            // -----------------------------------------------------------------
            S_PROJECT: if (pd_done) state <= S_CLEAR_WAIT;

            // -----------------------------------------------------------------
            // CLEAR_WAIT - wait for framebuffer_clear (TODO) to finish.
            // clear_busy is a LEVEL - we transition when it deasserts.
            // -----------------------------------------------------------------
            S_CLEAR_WAIT: if (!clear_busy) state <= S_RENDER;

            // -----------------------------------------------------------------
            // RENDER - wireframe_gen (TODO) rasterizes edges into back FB.
            // -----------------------------------------------------------------
            S_RENDER: if (wfg_done) state <= S_IDLE;

            default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // INLINE SWAP FSM
    //
    // On entry to S_SWAP, walks shadow_mem and writes into obj_mem:
    //   addresses 0 .. vc*3-1            : vertex bytes, widened by int_to_fp16
    //   addresses vc*3 .. vc*3+fc*3-1    : face index bytes, zero-extended
    //
    // shadow_mem has 1-cycle read latency. The fetch pointer (presented to
    // shadow_mem's read port) leads the store pointer (used to address
    // obj_mem and to decide vertex-vs-face widening) by one cycle.
    //
    // Sequence of cycles after `enter_swap`:
    //
    //   cycle 0: present shadow_rd_addr = 0
    //   cycle 1: shadow_rd_data = shadow[0]; write obj[0]; present addr = 1
    //   cycle 2: shadow_rd_data = shadow[1]; write obj[1]; present addr = 2
    //   ...
    //   cycle total: shadow_rd_data = shadow[total-1]; write obj[total-1];
    //                pulse swap_done; return to idle
    //
    // The substate FSM is just three states: IDLE -> PRIME -> RUN -> IDLE.
    // PRIME exists to handle the one-cycle read latency: it presents the
    // first address but doesn't yet write, since shadow_rd_data isn't valid
    // for that address yet.
    // =========================================================================

    // Substate encoding
    localparam [1:0] SW_IDLE  = 2'd0;
    localparam [1:0] SW_PRIME = 2'd1;
    localparam [1:0] SW_RUN   = 2'd2;
    reg [1:0] sw_state;

    // Counters
    reg [10:0] sw_wr_idx;        // next address to write into obj_mem
    reg [10:0] sw_total;         // total bytes to transfer (= vc*3 + fc*3)
    reg [10:0] sw_face_base;     // index at which vertex bytes end (= vc*3)

    // Local drivers (combinational from substate)
    reg         sw_obj_wen;
    reg  [10:0] sw_obj_addr;
    reg  [15:0] sw_obj_din;
    reg  [10:0] sw_shadow_addr;
    reg         sw_done_pulse;

    // Whether the byte being WRITTEN this cycle (at sw_wr_idx) is a vertex
    // (true) or a face index (false). Compared on the store pointer, not the
    // fetch pointer, so it lines up with the cycle the byte arrives.
    wire sw_is_vertex_byte = (sw_wr_idx < sw_face_base);

    // -------------------------------------------------------------------------
    // Sequential: substate, counters
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            sw_state     <= SW_IDLE;
            sw_wr_idx    <= 11'd0;
            sw_total     <= 11'd0;
            sw_face_base <= 11'd0;
        end else begin
            case (sw_state)

            SW_IDLE: if (enter_swap) begin
                // Latch sizes (vertex_count, face_count are already stable
                // since packet decoder finished writing before vblank).
                sw_face_base <= (vertex_count << 1) + {3'd0, vertex_count};
                sw_total     <= ((vertex_count << 1) + {3'd0, vertex_count})
                              + ((face_count   << 1) + {3'd0, face_count});
                sw_wr_idx    <= 11'd0;
                // Handle the degenerate empty-mesh case
                if (vertex_count == 8'd0 && face_count == 8'd0)
                    sw_state <= SW_IDLE;   // nothing to do; FSM will spin in SWAP
                                           // until swap_done pulses (TODO below)
                else
                    sw_state <= SW_PRIME;
            end

            // PRIME - first address presented to shadow_mem. Next cycle we
            // start writing.
            SW_PRIME: sw_state <= SW_RUN;

            // RUN - write obj[sw_wr_idx] from shadow_rd_data each cycle.
            SW_RUN: begin
                if (sw_wr_idx == sw_total - 11'd1) begin
                    sw_state <= SW_IDLE;
                end else begin
                    sw_wr_idx <= sw_wr_idx + 11'd1;
                end
            end

            default: sw_state <= SW_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Combinational driver outputs
    // -------------------------------------------------------------------------
    always @(*) begin
        sw_obj_wen     = 1'b0;
        sw_obj_addr    = 11'd0;
        sw_obj_din     = 16'd0;
        sw_shadow_addr = 11'd0;
        sw_done_pulse  = 1'b0;

        case (sw_state)

        SW_PRIME: begin
            // Present address 0 to shadow_mem. Don't write yet.
            sw_shadow_addr = 11'd0;
        end

        SW_RUN: begin
            // Write obj[sw_wr_idx] from shadow_rd_data this cycle.
            sw_obj_wen  = 1'b1;
            sw_obj_addr = sw_wr_idx;
            sw_obj_din  = sw_is_vertex_byte
                          ? i2f_fp16_out                // widened fp16
                          : {8'd0, shadow_rd_data};     // zero-extended face idx

            // Present the next read address (one ahead of sw_wr_idx).
            // If this is the last write, no new address is needed; tied to 0.
            if (sw_wr_idx == sw_total - 11'd1) begin
                sw_done_pulse = 1'b1;
            end else begin
                sw_shadow_addr = sw_wr_idx + 11'd1;
            end
        end

        default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // Drive the placeholder wires for the obj_mem write mux and the
    // shadow_mem read port. Also drive new_data_ack and the swap_done signal
    // that feeds the top-level FSM.
    // -------------------------------------------------------------------------
    wire         swap_obj_wen   = sw_obj_wen;
    wire [10:0]  swap_obj_addr  = sw_obj_addr;
    wire [15:0]  swap_obj_din   = sw_obj_din;

    // =========================================================================
    // INLINE VERTEX-BATCH FSM
    //
    // On entry to S_TRANSFORM_VERT, transforms every vertex of the current
    // mesh through the MVP matrix, writing the 4-component clip-space
    // result back into transform_mem starting at VERT_BASE.
    //
    // Vertices are processed in strips of up to 4. For each strip:
    //   - Reset mat_mul. Set N=4, M=4, P=strip_size.
    //   - Stream MVP (4x4) from transform_mem addrs 0..15 row-major as A.
    //   - Stream the strip as B in row-major order. mat_mul wants:
    //       row 0: x of vertex 0, x of vertex 1, ..., x of vertex P-1
    //       row 1: y's
    //       row 2: z's
    //       row 3: 1.0 (synthesized; obj_mem only holds x,y,z per vertex)
    //   - Pulse loaded_a/loaded_b.
    //   - Collect 4*P out_valid results. Element (r, c) - row r, column c -
    //     corresponds to component r of vertex (strip_first + c), so it goes
    //     to transform_mem address VERT_BASE + 4*(strip_first + c) + r.
    //
    // The streaming counters account for the one-cycle read latency of both
    // transform_mem and obj_mem: addresses are presented one cycle before
    // their data appears on the read-data wires. The first address of each
    // streaming phase is presented in a "PREP" state so that STREAM enters
    // with data immediately valid.
    //
    // Layout:
    //   VB_IDLE          - wait for enter_transform_vert
    //   VB_PREP_A        - pulse mat_rst; set dims; present tm_rd_addr = 0
    //   VB_STREAM_A      - stream 16 MVP elements as A
    //   VB_PREP_B        - pulse loaded_a; present obj_mem first x address
    //   VB_STREAM_B_XYZ  - stream rows 0..2 (3*P obj_mem reads)
    //   VB_STREAM_B_W    - stream row 3 (P constants of 1.0, no obj reads)
    //   VB_COLLECT       - pulse loaded_b; capture 4*P outputs into tm
    //   VB_STRIP_DONE    - wait for mat_busy low; advance strip or finish
    //   VB_FINISH        - pulse vert_batch_done; return to IDLE
    // =========================================================================

    localparam [3:0] VB_IDLE         = 4'd0;
    localparam [3:0] VB_PREP_A       = 4'd1;
    localparam [3:0] VB_STREAM_A     = 4'd2;
    localparam [3:0] VB_PREP_B       = 4'd3;
    localparam [3:0] VB_STREAM_B_XYZ = 4'd4;
    localparam [3:0] VB_STREAM_B_W   = 4'd5;
    localparam [3:0] VB_COLLECT      = 4'd6;
    localparam [3:0] VB_STRIP_DONE   = 4'd7;
    localparam [3:0] VB_FINISH       = 4'd8;
    reg [3:0] vb_state;

    // Strip bookkeeping
    reg [7:0]  vb_strip_first;     // index of first vertex in this strip
    reg [3:0]  vb_strip_size;      // 1..4 vertices in this strip
    reg [7:0]  vb_total_verts;     // latched vertex_count on entry

    // Remaining vertices after this strip (used to compute next strip's size)
    wire [7:0] vb_remaining_next = vb_total_verts - vb_strip_first - {4'd0, vb_strip_size};

    // Streaming counters (used contextually per state)
    reg [4:0]  vb_a_ctr;           // 0..15 for A elements
    reg [3:0]  vb_b_row;           // 0..3
    reg [3:0]  vb_b_col;           // 0..vb_strip_size-1
    reg [5:0]  vb_collect_ctr;     // 0..(4*P - 1)

    // Combinational outputs
    reg        vb_mat_rst_r;
    reg [7:0]  vb_mat_N_r, vb_mat_M_r, vb_mat_P_r;
    reg        vb_mat_write_a_r, vb_mat_write_b_r;
    reg [15:0] vb_mat_data_a_r, vb_mat_data_b_r;
    reg        vb_mat_loaded_a_r, vb_mat_loaded_b_r;

    reg [9:0]  vb_tm_rd_addr_r;
    reg [10:0] vb_obj_rd_addr_r;

    reg        vb_tm_wr_en_r;
    reg [9:0]  vb_tm_wr_addr_r;
    reg [15:0] vb_tm_wr_data_r;

    reg        vb_done_r;

    // fp16 1.0 constant for the w component
    localparam [15:0] FP16_ONE = 16'h3c00;

    // -------------------------------------------------------------------------
    // Sequential: substate and counters
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            vb_state       <= VB_IDLE;
            vb_strip_first <= 8'd0;
            vb_strip_size  <= 4'd0;
            vb_total_verts <= 8'd0;
            vb_a_ctr       <= 5'd0;
            vb_b_row       <= 4'd0;
            vb_b_col       <= 4'd0;
            vb_collect_ctr <= 6'd0;
        end else begin
            case (vb_state)

            VB_IDLE: if (enter_transform_vert) begin
                vb_total_verts <= vertex_count;
                vb_strip_first <= 8'd0;
                // Strip size: min(vertex_count, 4)
                vb_strip_size  <= (vertex_count >= 8'd4) ? 4'd4 : vertex_count[3:0];
                vb_state       <= VB_PREP_A;
            end

            VB_PREP_A: begin
                // mat_rst pulses this cycle; tm_rd_addr=0 presented.
                vb_a_ctr <= 5'd0;
                vb_state <= VB_STREAM_A;
            end

            VB_STREAM_A: begin
                // Each cycle: capture MVP element vb_a_ctr from tm_rd_data,
                // and present next address (vb_a_ctr+1). Exit when last
                // captured.
                if (vb_a_ctr == 5'd15) begin
                    vb_state <= VB_PREP_B;
                end else begin
                    vb_a_ctr <= vb_a_ctr + 5'd1;
                end
            end

            VB_PREP_B: begin
                // loaded_a pulses this cycle. Present first obj_mem read addr.
                vb_b_row <= 4'd0;
                vb_b_col <= 4'd0;
                vb_state <= VB_STREAM_B_XYZ;
            end

            VB_STREAM_B_XYZ: begin
                // Streaming rows 0..2 (P*3 cycles).
                if (vb_b_col == vb_strip_size - 4'd1) begin
                    if (vb_b_row == 4'd2) begin
                        // Done with rows 0..2; transition to W row.
                        vb_b_row <= 4'd0;
                        vb_b_col <= 4'd0;
                        vb_state <= VB_STREAM_B_W;
                    end else begin
                        vb_b_row <= vb_b_row + 4'd1;
                        vb_b_col <= 4'd0;
                    end
                end else begin
                    vb_b_col <= vb_b_col + 4'd1;
                end
            end

            VB_STREAM_B_W: begin
                // Row 3: P copies of 1.0
                if (vb_b_col == vb_strip_size - 4'd1) begin
                    vb_collect_ctr <= 6'd0;
                    vb_state       <= VB_COLLECT;
                end else begin
                    vb_b_col <= vb_b_col + 4'd1;
                end
            end

            VB_COLLECT: begin
                // Wait for out_valid pulses. Each pulse: write to
                // transform_mem at computed addr (handled combinationally).
                if (mat_out_valid) begin
                    if (vb_collect_ctr == {2'd0, vb_strip_size, 2'd0} - 6'd1) begin
                        // Last element collected (4*P - 1)
                        vb_state <= VB_STRIP_DONE;
                    end else begin
                        vb_collect_ctr <= vb_collect_ctr + 6'd1;
                    end
                end
            end

            VB_STRIP_DONE: begin
                // Wait for mat_busy to deassert, then advance to next strip
                // or finish.
                if (!mat_busy) begin
                    if (vb_strip_first + {4'd0, vb_strip_size} >= vb_total_verts) begin
                        vb_state <= VB_FINISH;
                    end else begin
                        vb_strip_first <= vb_strip_first + {4'd0, vb_strip_size};
                        // Size of next strip
                        if (vb_remaining_next >= 8'd4)
                            vb_strip_size <= 4'd4;
                        else
                            vb_strip_size <= vb_remaining_next[3:0];
                        vb_state <= VB_PREP_A;
                    end
                end
            end

            VB_FINISH: vb_state <= VB_IDLE;

            default: vb_state <= VB_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Combinational outputs
    //
    // The streaming logic uses a one-cycle-shifted "address presented" vs
    // "element captured" relationship to account for memory read latency.
    // In VB_STREAM_A, on cycle K: tm_rd_addr presented for next cycle's K+1,
    // and current tm_rd_data is element K (presented at K-1, or by PREP_A
    // for K=0).
    // -------------------------------------------------------------------------

    // Current obj_mem address for row r of vertex at strip column c:
    //   (vb_strip_first + c) * 3 + r  =  ((x)<<1) + x + r
    wire [10:0] vb_vert_idx_curr = {3'd0, vb_strip_first} + {7'd0, vb_b_col};
    wire [10:0] vb_obj_addr_curr =
        (vb_vert_idx_curr << 1) + vb_vert_idx_curr + {7'd0, vb_b_row};

    // Likewise the address to present for the NEXT cycle's obj_mem read.
    // We need to predict (next_b_col, next_b_row) and compute that address.
    wire [3:0]  vb_b_col_p1   = vb_b_col + 4'd1;
    wire        vb_col_end    = (vb_b_col == vb_strip_size - 4'd1);
    wire [3:0]  vb_next_b_col = vb_col_end ? 4'd0 : vb_b_col_p1;
    wire [3:0]  vb_next_b_row = vb_col_end ? (vb_b_row + 4'd1) : vb_b_row;
    wire [10:0] vb_vert_idx_next = {3'd0, vb_strip_first} + {7'd0, vb_next_b_col};
    wire [10:0] vb_obj_addr_next =
        (vb_vert_idx_next << 1) + vb_vert_idx_next + {7'd0, vb_next_b_row};

    // For VB_COLLECT: compute the transform_mem write address for the
    // collect_ctr'th output element. Output is row-major: element index
    // i = r*P + c (0-indexed), where r is row (component), c is column
    // (vertex within strip). The destination address:
    //   VERT_BASE + 4*(strip_first + c) + r
    wire [5:0]  vb_collect_idx = vb_collect_ctr;     // alias for clarity
    wire [3:0]  vb_collect_r;
    wire [3:0]  vb_collect_c;
    // r = i / P, c = i mod P. For variable P (1..4) we can't use shifts.
    // Use a divider-free approach: small lookup based on vb_strip_size.
    // For P=4: r = i[5:2], c = i[1:0]
    // For P<4: r and c need actual division. Synthesizable as a small divider.
    // To keep this simple and timing-friendly, we restrict the divide via
    // explicit case on strip_size.
    reg [3:0] vb_collect_r_reg, vb_collect_c_reg;
    always @(*) begin
        case (vb_strip_size)
            4'd1: begin vb_collect_r_reg = vb_collect_idx[3:0]; vb_collect_c_reg = 4'd0; end
            4'd2: begin vb_collect_r_reg = vb_collect_idx[3:1]; vb_collect_c_reg = {3'd0, vb_collect_idx[0]}; end
            4'd3: begin
                // For P=3: division by 3. Use a 4-bit divide table.
                case (vb_collect_idx[3:0])
                    4'd0:  begin vb_collect_r_reg = 4'd0; vb_collect_c_reg = 4'd0; end
                    4'd1:  begin vb_collect_r_reg = 4'd0; vb_collect_c_reg = 4'd1; end
                    4'd2:  begin vb_collect_r_reg = 4'd0; vb_collect_c_reg = 4'd2; end
                    4'd3:  begin vb_collect_r_reg = 4'd1; vb_collect_c_reg = 4'd0; end
                    4'd4:  begin vb_collect_r_reg = 4'd1; vb_collect_c_reg = 4'd1; end
                    4'd5:  begin vb_collect_r_reg = 4'd1; vb_collect_c_reg = 4'd2; end
                    4'd6:  begin vb_collect_r_reg = 4'd2; vb_collect_c_reg = 4'd0; end
                    4'd7:  begin vb_collect_r_reg = 4'd2; vb_collect_c_reg = 4'd1; end
                    4'd8:  begin vb_collect_r_reg = 4'd2; vb_collect_c_reg = 4'd2; end
                    4'd9:  begin vb_collect_r_reg = 4'd3; vb_collect_c_reg = 4'd0; end
                    4'd10: begin vb_collect_r_reg = 4'd3; vb_collect_c_reg = 4'd1; end
                    4'd11: begin vb_collect_r_reg = 4'd3; vb_collect_c_reg = 4'd2; end
                    default: begin vb_collect_r_reg = 4'd0; vb_collect_c_reg = 4'd0; end
                endcase
            end
            4'd4: begin vb_collect_r_reg = vb_collect_idx[5:2]; vb_collect_c_reg = vb_collect_idx[3:0] & 4'd3; end
            default: begin vb_collect_r_reg = 4'd0; vb_collect_c_reg = 4'd0; end
        endcase
    end
    assign vb_collect_r = vb_collect_r_reg;
    assign vb_collect_c = vb_collect_c_reg;

    // Final transform_mem write address for the current collect element.
    // (Offset by VERT_BASE since vertex data lives at transform_mem[16+])
    wire [9:0] vb_collect_tm_addr =
        VERT_BASE + ({4'd0, vb_strip_first, 2'd0} + {4'd0, vb_collect_c, 2'd0}) + {6'd0, vb_collect_r};

    always @(*) begin
        // Defaults
        vb_mat_rst_r       = 1'b0;
        vb_mat_N_r         = 8'd4;
        vb_mat_M_r         = 8'd4;
        vb_mat_P_r         = {4'd0, vb_strip_size};
        vb_mat_write_a_r   = 1'b0;
        vb_mat_write_b_r   = 1'b0;
        vb_mat_data_a_r    = tm_rd_data;
        vb_mat_data_b_r    = 16'd0;
        vb_mat_loaded_a_r  = 1'b0;
        vb_mat_loaded_b_r  = 1'b0;
        vb_tm_rd_addr_r    = 10'd0;
        vb_obj_rd_addr_r   = 11'd0;
        vb_tm_wr_en_r      = 1'b0;
        vb_tm_wr_addr_r    = 10'd0;
        vb_tm_wr_data_r    = 16'd0;
        vb_done_r          = 1'b0;

        case (vb_state)

        VB_PREP_A: begin
            // Pulse mat_rst this cycle; present transform_mem addr 0.
            vb_mat_rst_r    = 1'b1;
            vb_tm_rd_addr_r = 10'd0;
        end

        VB_STREAM_A: begin
            // Each cycle: capture element vb_a_ctr from tm_rd_data; assert
            // write_a; present next addr (a_ctr + 1).
            vb_mat_write_a_r = 1'b1;
            vb_mat_data_a_r  = tm_rd_data;
            // Present the next address if there is one
            if (vb_a_ctr != 5'd15) vb_tm_rd_addr_r = {5'd0, vb_a_ctr + 5'd1};
            else                    vb_tm_rd_addr_r = 10'd15;   // hold last
        end

        VB_PREP_B: begin
            vb_mat_loaded_a_r = 1'b1;
            // First obj_mem read: row 0, col 0 -> addr = strip_first*3
            // Use shift-add to avoid a synthesised multiplier.
            vb_obj_rd_addr_r  = ({3'd0, vb_strip_first} << 1)
                               + {3'd0, vb_strip_first};
        end

        VB_STREAM_B_XYZ: begin
            // Capture obj_rd_data as data_b; present next addr.
            vb_mat_write_b_r = 1'b1;
            vb_mat_data_b_r  = obj_rd_data;
            vb_obj_rd_addr_r = vb_obj_addr_next;
        end

        VB_STREAM_B_W: begin
            // Row 3: stream P copies of fp16 1.0; no obj_mem read needed.
            vb_mat_write_b_r = 1'b1;
            vb_mat_data_b_r  = FP16_ONE;
        end

        VB_COLLECT: begin
            // First cycle of COLLECT: pulse loaded_b. Then, on each
            // out_valid, write the next result element to transform_mem.
            if (vb_collect_ctr == 6'd0) vb_mat_loaded_b_r = 1'b1;

            if (mat_out_valid) begin
                vb_tm_wr_en_r   = 1'b1;
                vb_tm_wr_addr_r = vb_collect_tm_addr;
                vb_tm_wr_data_r = mat_data_out;
            end
        end

        VB_FINISH: vb_done_r = 1'b1;

        default: ;
        endcase
    end

    // =========================================================================
    // MEMORY PORT MUXES
    //
    // Combinational selects driven off the FSM state. Each port has at most
    // one active driver per state.
    // =========================================================================

    // ---- transform_mem vertex base offset ----------------------------------
    // perspective_divide and wireframe_gen address per-vertex data starting
    // at zero; the MVP matrix occupies addresses 0..15, so vertex data lives
    // starting at address 16. The mux wiring adds the offset.
    localparam [9:0] VERT_BASE = 10'd16;

    // ---- transform_mem write port ------------------------------------------
    // TRANSFORM_MVP   -> MVP_matrix_maker (4-bit addr, MVP region 0..15)
    // TRANSFORM_VERT  -> vertex-batch FSM (addresses VERT_BASE+)
    // PROJECT         -> perspective_divide (addresses VERT_BASE + pd_write_addr)
    // default         -> wen=0
    assign tm_wr_en   = (state == S_TRANSFORM_MVP)  ? mvp_ram_wen
                      : (state == S_TRANSFORM_VERT) ? vb_tm_wr_en
                      : (state == S_PROJECT)        ? pd_write_en
                      :                                1'b0;

    assign tm_wr_addr = (state == S_TRANSFORM_MVP)  ? {6'd0, mvp_ram_addr}
                      : (state == S_TRANSFORM_VERT) ? vb_tm_wr_addr
                      : (state == S_PROJECT)        ? (pd_write_addr + VERT_BASE)
                      :                                10'd0;

    assign tm_wr_data = (state == S_TRANSFORM_MVP)  ? mvp_ram_din
                      : (state == S_TRANSFORM_VERT) ? vb_tm_wr_data
                      : (state == S_PROJECT)        ? pd_write_data
                      :                                16'd0;

    // ---- transform_mem read port -------------------------------------------
    // TRANSFORM_VERT  -> vertex-batch FSM (reads MVP at 0..15, no offset)
    // PROJECT         -> perspective_divide (addresses VERT_BASE + pd_read_addr)
    // RENDER          -> wireframe_gen      (addresses VERT_BASE + wfg_tf_addr)
    // default         -> 0
    assign tm_rd_addr = (state == S_TRANSFORM_VERT) ? vb_tm_rd_addr
                      : (state == S_PROJECT)        ? (pd_read_addr + VERT_BASE)
                      : (state == S_RENDER)         ? (wfg_tf_addr   + VERT_BASE)
                      :                                10'd0;

    // ---- obj_mem write port ------------------------------------------------
    // SWAP -> inline SWAP FSM. default -> wen=0.
    assign obj_wr_en   = (state == S_SWAP) ? swap_obj_wen   : 1'b0;
    assign obj_wr_addr = (state == S_SWAP) ? swap_obj_addr  : 11'd0;
    assign obj_wr_data = (state == S_SWAP) ? swap_obj_din   : 16'd0;

    // ---- obj_mem read port -------------------------------------------------
    // TRANSFORM_VERT -> vertex-batch FSM (vertex coords)
    // RENDER         -> wireframe_gen (face indices)
    // default        -> 0
    assign obj_rd_addr = (state == S_TRANSFORM_VERT) ? vb_obj_rd_addr
                       : (state == S_RENDER)         ? wfg_obj_addr
                       :                                11'd0;

    // =========================================================================
    // BACK-BUFFER WRITE MUX
    //
    // framebuffer_clear and wireframe_gen both write to the back buffer's
    // port A, never overlapping. framebuffer_clear runs during the early
    // states (started at vblank, busy through CLEAR_WAIT); wireframe_gen
    // runs only in RENDER. clear_busy is the priority signal.
    // =========================================================================
    wire        bb_wr_en   = fbc_busy ? fbc_fb_wen  : wfg_fb_wen;
    wire [13:0] bb_wr_addr = fbc_busy ? fbc_fb_addr : wfg_fb_addr;
    wire [31:0] bb_wr_data = fbc_busy ? fbc_fb_din  : wfg_fb_din;

    // =========================================================================
    // FRAMEBUFFER SWAP MUX
    //
    // Each framebuffer is true dual-port:
    //   port A (100 MHz): renderer-side read+write - used as BACK
    //   port B (25 MHz):  VGA scanout read         - used as FRONT
    //
    // front_buf = 0:
    //   fb_a is FRONT: vga_fb_addr drives fb_a port B
    //   fb_b is BACK : renderer writes drive fb_b port A
    //                  wireframe_gen's RMW read comes from fb_b port A
    // front_buf = 1: reversed.
    // =========================================================================
    // (vga_fb_addr already declared near the vga_controller instance above)

    // Back-buffer port A (read+write) routing - only the BACK buffer's port A
    // is driven by the renderer; the FRONT buffer's port A is tied off
    // (the buffer isn't being written, and its port A read goes unused).
    assign fb_a_wr_en   = (front_buf == 1'b1) ? bb_wr_en   : 1'b0;
    assign fb_a_wr_addr = (front_buf == 1'b1) ? bb_wr_addr : 14'd0;
    assign fb_a_wr_data = (front_buf == 1'b1) ? bb_wr_data : 32'd0;

    assign fb_b_wr_en   = (front_buf == 1'b0) ? bb_wr_en   : 1'b0;
    assign fb_b_wr_addr = (front_buf == 1'b0) ? bb_wr_addr : 14'd0;
    assign fb_b_wr_data = (front_buf == 1'b0) ? bb_wr_data : 32'd0;

    // Port B (read) address for both buffers comes from the VGA controller.
    // Only the front buffer's douta matters; the back buffer's port B is
    // unused this frame.
    assign fb_a_rd_addr = vga_fb_addr;
    assign fb_b_rd_addr = vga_fb_addr;

    // wireframe_gen consumes the BACK buffer's port A read (douta)
    wire [31:0] back_fb_rd_data = (front_buf == 1'b0) ? fb_b_rd_data_pa : fb_a_rd_data_pa;

    // VGA controller consumes the FRONT buffer's port B read (doutb)
    assign vga_fb_dout = (front_buf == 1'b0) ? fb_a_rd_data : fb_b_rd_data;
    //
    // Each submodule expects a one-cycle `start` pulse when its state is
    // entered. We detect "state changed to S_X" by comparing the current
    // state with a delayed copy.
    // =========================================================================
    reg [2:0] state_prev;
    always @(posedge clk) state_prev <= state;

    wire enter_swap           = (state == S_SWAP)           & (state_prev != S_SWAP);
    wire enter_transform_mvp  = (state == S_TRANSFORM_MVP)  & (state_prev != S_TRANSFORM_MVP);
    wire enter_transform_vert = (state == S_TRANSFORM_VERT) & (state_prev != S_TRANSFORM_VERT);
    wire enter_project        = (state == S_PROJECT)        & (state_prev != S_PROJECT);
    wire enter_clear_wait     = (state == S_CLEAR_WAIT)     & (state_prev != S_CLEAR_WAIT);
    wire enter_render         = (state == S_RENDER)         & (state_prev != S_RENDER);

    // =========================================================================
    // SUBMODULE INSTANCES
    // =========================================================================

    // ---- MVP_matrix_maker ---------------------------------------------------
    wire        mvp_mat_rst;
    wire [7:0]  mvp_mat_N, mvp_mat_M, mvp_mat_P;
    wire        mvp_mat_write_a;
    wire [15:0] mvp_mat_data_a;
    wire        mvp_mat_loaded_a;
    wire        mvp_mat_write_b;
    wire [15:0] mvp_mat_data_b;
    wire        mvp_mat_loaded_b;
    wire        mvp_ram_wen;
    wire [3:0]  mvp_ram_addr;
    wire [15:0] mvp_ram_din;
    wire        mvp_done_w;

    // mat_mul outputs are broadcast to all callers; each ignores them when
    // not active. mat_data_out / mat_out_valid / mat_busy are the shared
    // wires declared further down.
    wire [15:0] mat_data_out;
    wire        mat_out_valid;
    wire        mat_busy;

    MVP_matrix_maker u_mvp_matrix_maker (
        .clk           (clk),
        .rst           (rst),
        .start         (enter_transform_mvp),
        .speed_x       (speed_x),
        .speed_y       (speed_y),

        .mat_rst       (mvp_mat_rst),
        .mat_N         (mvp_mat_N),
        .mat_M         (mvp_mat_M),
        .mat_P         (mvp_mat_P),
        .mat_write_a   (mvp_mat_write_a),
        .mat_data_a    (mvp_mat_data_a),
        .mat_loaded_a  (mvp_mat_loaded_a),
        .mat_write_b   (mvp_mat_write_b),
        .mat_data_b    (mvp_mat_data_b),
        .mat_loaded_b  (mvp_mat_loaded_b),
        .mat_data_out  (mat_data_out),
        .mat_out_valid (mat_out_valid),
        .mat_busy      (mat_busy),

        .ram_wen       (mvp_ram_wen),
        .ram_addr      (mvp_ram_addr),
        .ram_din       (mvp_ram_din),

        .done          (mvp_done_w)
    );

    // ---- Vertex-batch FSM mat_mul interface ---------------------------------
    // Driven by the inline vertex-batch FSM above.
    wire        vb_mat_rst       = vb_mat_rst_r;
    wire [7:0]  vb_mat_N         = vb_mat_N_r;
    wire [7:0]  vb_mat_M         = vb_mat_M_r;
    wire [7:0]  vb_mat_P         = vb_mat_P_r;
    wire        vb_mat_write_a   = vb_mat_write_a_r;
    wire [15:0] vb_mat_data_a    = vb_mat_data_a_r;
    wire        vb_mat_loaded_a  = vb_mat_loaded_a_r;
    wire        vb_mat_write_b   = vb_mat_write_b_r;
    wire [15:0] vb_mat_data_b    = vb_mat_data_b_r;
    wire        vb_mat_loaded_b  = vb_mat_loaded_b_r;

    // ---- Vertex-batch FSM memory port interface -----------------------------
    // These wires feed the transform_mem and obj_mem mux logic.
    wire [9:0]   vb_tm_rd_addr  = vb_tm_rd_addr_r;
    wire         vb_tm_wr_en    = vb_tm_wr_en_r;
    wire [9:0]   vb_tm_wr_addr  = vb_tm_wr_addr_r;
    wire [15:0]  vb_tm_wr_data  = vb_tm_wr_data_r;
    wire [10:0]  vb_obj_rd_addr = vb_obj_rd_addr_r;

    // ---- mat_owner mux (mat_mul input selection) ----------------------------
    // mat_owner = 0 -> MVP_matrix_maker drives mat_mul
    // mat_owner = 1 -> vertex-batch FSM drives mat_mul
    wire mat_owner = (state == S_TRANSFORM_VERT);

    wire        mm_rst      = mat_owner ? vb_mat_rst      : mvp_mat_rst;
    wire [7:0]  mm_N        = mat_owner ? vb_mat_N        : mvp_mat_N;
    wire [7:0]  mm_M        = mat_owner ? vb_mat_M        : mvp_mat_M;
    wire [7:0]  mm_P        = mat_owner ? vb_mat_P        : mvp_mat_P;
    wire        mm_write_a  = mat_owner ? vb_mat_write_a  : mvp_mat_write_a;
    wire [15:0] mm_data_a   = mat_owner ? vb_mat_data_a   : mvp_mat_data_a;
    wire        mm_loaded_a = mat_owner ? vb_mat_loaded_a : mvp_mat_loaded_a;
    wire        mm_write_b  = mat_owner ? vb_mat_write_b  : mvp_mat_write_b;
    wire [15:0] mm_data_b   = mat_owner ? vb_mat_data_b   : mvp_mat_data_b;
    wire        mm_loaded_b = mat_owner ? vb_mat_loaded_b : mvp_mat_loaded_b;

    // ---- mat_mul (shared) ---------------------------------------------------
    mat_mul #(.MAX_DIM(4)) u_mat_mul (
        .clk       (clk),
        .rst       (rst | mm_rst),
        .N         (mm_N),
        .M         (mm_M),
        .P         (mm_P),
        .write_a   (mm_write_a),
        .data_a    (mm_data_a),
        .loaded_a  (mm_loaded_a),
        .write_b   (mm_write_b),
        .data_b    (mm_data_b),
        .loaded_b  (mm_loaded_b),
        .data_out  (mat_data_out),
        .out_valid (mat_out_valid),
        .busy      (mat_busy)
    );

    // ---- perspective_divide -------------------------------------------------
    wire [9:0]  pd_read_addr;
    wire [9:0]  pd_write_addr;
    wire [15:0] pd_write_data;
    wire        pd_write_en;
    wire        pd_done_w;

    perspective_divide u_perspective_divide (
        .clk          (clk),
        .rst          (rst),
        .start        (enter_project),
        .vertex_count (vertex_count),
        .read_addr    (pd_read_addr),
        .read_data    (tm_rd_data),
        .write_addr   (pd_write_addr),
        .write_data   (pd_write_data),
        .write_en     (pd_write_en),
        .done         (pd_done_w)
    );

    // ---- framebuffer_clear --------------------------------------------------
    wire [13:0] fbc_fb_addr;
    wire [31:0] fbc_fb_din;
    wire        fbc_fb_wen;
    wire        fbc_busy;

    framebuffer_clear u_framebuffer_clear (
        .clk     (clk),
        .rst     (rst),
        .start   (vblank_rise),     // started at vblank - CLEAR_WAIT just waits
        .fb_addr (fbc_fb_addr),
        .fb_din  (fbc_fb_din),
        .fb_wen  (fbc_fb_wen),
        .busy    (fbc_busy)
    );

    // ---- wireframe_gen ------------------------------------------------------
    wire [10:0] wfg_obj_addr;
    wire [9:0]  wfg_tf_addr;
    wire [13:0] wfg_fb_addr;
    wire [31:0] wfg_fb_din;
    wire        wfg_fb_wen;
    wire        wfg_done_w;

    // wireframe_gen's fb_dout input comes from the BACK buffer's port B,
    // routed by the swap mux (back_fb_rd_data).
    wire [31:0] wfg_fb_dout = back_fb_rd_data;

    wireframe_gen u_wireframe_gen (
        .clk          (clk),
        .rst          (rst),
        .start        (enter_render),
        .face_count   (face_count),
        .vertex_count (vertex_count),
        .obj_addr     (wfg_obj_addr),
        .obj_data     (obj_rd_data),
        .tf_addr      (wfg_tf_addr),
        .tf_data      (tm_rd_data),
        .fb_addr      (wfg_fb_addr),
        .fb_din       (wfg_fb_din),
        .fb_dout      (wfg_fb_dout),
        .fb_wen       (wfg_fb_wen),
        .done         (wfg_done_w)
    );

    // ---- int_to_fp16 (used by inline SWAP FSM) -----------------------
    wire [15:0] i2f_fp16_out;
    int_to_fp16 u_int_to_fp16 (
        .int_in   ($signed(shadow_rd_data)),
        .fp16_out (i2f_fp16_out)
    );

endmodule
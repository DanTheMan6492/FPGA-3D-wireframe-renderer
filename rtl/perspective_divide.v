// =============================================================================
// perspective_divide.v  —  Per-vertex perspective divide + viewport transform
// =============================================================================
// For each of `vertex_count` vertices in transform_mem:
//   1. Read 4 fp16 components (x, y, z, w) from addresses 4N..4N+3.
//      (z is read but unused for 2D wireframe; reserved for flat-shading.)
//   2. Compute w_recip = 1/w (registered).
//   3. Compute x_ndc = x * w_recip, y_ndc = y * w_recip (registered).
//   4. Compute pixel coords (registered):
//        px = (x_ndc + 1.0) * 320.0
//        py = (1.0 - y_ndc) * 240.0
//      Y is flipped because NDC y points up, screen y points down.
//   5. Write px and py to transform_mem at addresses 2N and 2N+1.
//
// transform_mem is true dual-port: read on port A (this module's read_addr/
// read_data), write on port B (write_addr/write_data/write_en). The write
// pointer (2N) always trails the read pointer (4N..4N+3), so there is no
// read/write hazard within or across vertices.
//
// transform_mem has 1-cycle read latency: address presented on cycle K,
// data valid on cycle K+1. The FSM handles this explicitly.
// =============================================================================

module perspective_divide (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [7:0]  vertex_count,

    // transform_mem read port (port A, 1-cycle latency)
    output reg  [9:0]  read_addr,
    input  wire [15:0] read_data,

    // transform_mem write port (port B)
    output reg  [9:0]  write_addr,
    output reg  [15:0] write_data,
    output reg         write_en,

    output reg         done
);

    // -------------------------------------------------------------------------
    // FP16 constants
    // -------------------------------------------------------------------------
    localparam [15:0] FP16_ONE = 16'h3c00;  // +1.0
    localparam [15:0] FP16_320 = 16'h5d00;  // +320.0
    localparam [15:0] FP16_240 = 16'h5b80;  // +240.0

    // -------------------------------------------------------------------------
    // Per-vertex latched clip-space coordinates
    // -------------------------------------------------------------------------
    reg [15:0] vx, vy, vz, vw;

    // Pipelined intermediates
    reg [15:0] w_recip_q;
    reg [15:0] x_ndc_q, y_ndc_q;
    reg [15:0] px_q, py_q;

    // -------------------------------------------------------------------------
    // Combinational arithmetic submodules.
    // The compute states latch the outputs into registers above, so each
    // state's combinational path is only one fp16 module (or two in COMP_PIX).
    // -------------------------------------------------------------------------
    wire [15:0] w_recip_w;
    fp16_recip u_recip (.a(vw), .result(w_recip_w));

    wire [15:0] x_ndc_w, y_ndc_w;
    fp16_mul u_mul_xn (.a(vx), .b(w_recip_q), .result(x_ndc_w));
    fp16_mul u_mul_yn (.a(vy), .b(w_recip_q), .result(y_ndc_w));

    // px = (x_ndc + 1.0) * 320.0
    wire [15:0] x_shifted, px_w;
    fp16_add u_add_x  (.a(x_ndc_q),  .b(FP16_ONE),  .result(x_shifted));
    fp16_mul u_mul_px (.a(x_shifted), .b(FP16_320), .result(px_w));

    // py = (1.0 - y_ndc) * 240.0   — implemented as (1.0 + (-y_ndc)) * 240
    wire [15:0] y_ndc_neg = {~y_ndc_q[15], y_ndc_q[14:0]};
    wire [15:0] y_shifted, py_w;
    fp16_add u_add_y  (.a(FP16_ONE), .b(y_ndc_neg), .result(y_shifted));
    fp16_mul u_mul_py (.a(y_shifted), .b(FP16_240), .result(py_w));

    // -------------------------------------------------------------------------
    // FSM
    //
    //   IDLE       — wait for start.
    //   READ_X     — present addr 4N+0. read_data will reflect this 2 cycles later.
    //   READ_Y     — present addr 4N+1. (read_data is still the previous value.)
    //   READ_Z     — present addr 4N+2. read_data now = tm[4N+0]: latch as vx.
    //   READ_W     — present addr 4N+3. read_data = tm[4N+1]: latch as vy.
    //   WAIT_Z     — read_data = tm[4N+2]: latch as vz.
    //   WAIT_W     — read_data = tm[4N+3]: latch as vw.
    //
    // i.e. each latch is TWO states after the matching address was presented.
    // This matches the testbench/SDPRAM model where read_addr drives a
    // registered output, giving an effective two-cycle read-to-use latency
    // when both the address and the consumer are registered.
    localparam IDLE     = 4'd0;
    localparam READ_X   = 4'd1;
    localparam READ_Y   = 4'd2;
    localparam READ_Z   = 4'd3;
    localparam READ_W   = 4'd4;
    localparam WAIT_Z   = 4'd5;
    localparam WAIT_W   = 4'd6;
    localparam COMP_REC = 4'd7;
    localparam COMP_NDC = 4'd8;
    localparam COMP_PIX = 4'd9;
    localparam WRITE_PX = 4'd10;
    localparam WRITE_PY = 4'd11;
    localparam DONE_S   = 4'd12;
    reg [3:0] state;

    reg [7:0] v_idx;  // current vertex index, 0..vertex_count-1

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            v_idx     <= 0;
            done      <= 1'b0;
            write_en  <= 1'b0;
        end else begin
            done     <= 1'b0;
            write_en <= 1'b0;

            case (state)

            IDLE: if (start) begin
                v_idx <= 0;
                state <= READ_X;
            end

            // Present 4N+0 (vx address). Don't latch yet — vx data will be
            // valid two cycles from now.
            READ_X: begin
                read_addr <= {v_idx, 2'b00};
                state     <= READ_Y;
            end

            // Present 4N+1 (vy). vx data still not valid.
            READ_Y: begin
                read_addr <= {v_idx, 2'b01};
                state     <= READ_Z;
            end

            // Present 4N+2 (vz). NOW read_data holds tm[4N+0] = vx.
            READ_Z: begin
                read_addr <= {v_idx, 2'b10};
                vx        <= read_data;
                state     <= READ_W;
            end

            // Present 4N+3 (vw). read_data = tm[4N+1] = vy.
            READ_W: begin
                read_addr <= {v_idx, 2'b11};
                vy        <= read_data;
                state     <= WAIT_Z;
            end

            // No new address. read_data = tm[4N+2] = vz.
            WAIT_Z: begin
                vz    <= read_data;
                state <= WAIT_W;
            end

            // read_data = tm[4N+3] = vw.
            WAIT_W: begin
                vw    <= read_data;
                state <= COMP_REC;
            end

            COMP_REC: begin
                w_recip_q <= w_recip_w;
                state     <= COMP_NDC;
            end

            COMP_NDC: begin
                x_ndc_q <= x_ndc_w;
                y_ndc_q <= y_ndc_w;
                state   <= COMP_PIX;
            end

            COMP_PIX: begin
                px_q  <= px_w;
                py_q  <= py_w;
                state <= WRITE_PX;
            end

            WRITE_PX: begin
                write_addr <= {1'b0, v_idx, 1'b0};   // 2N+0
                write_data <= px_q;
                write_en   <= 1'b1;
                state      <= WRITE_PY;
            end

            WRITE_PY: begin
                write_addr <= {1'b0, v_idx, 1'b1};   // 2N+1
                write_data <= py_q;
                write_en   <= 1'b1;
                if (v_idx == vertex_count - 1) begin
                    state <= DONE_S;
                end else begin
                    v_idx <= v_idx + 1;
                    state <= READ_X;
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

// WAIT_Z is declared but never reached because the READ states pipeline the
// latches one ahead. Left in the localparam list as a sanity reference for
// the read-latency pattern.
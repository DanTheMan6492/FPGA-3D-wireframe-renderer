// =============================================================================
// uart_packet_decoder.v  -  Mesh upload packet interpreter
// =============================================================================
// Consumes the byte stream from uart_rx and interprets the upload packet:
//
//   byte 0           : vertex_count (V)
//   byte 1           : face_count   (F)
//   bytes 2 .. 2+3V-1: vertex coordinate bytes (V * 3, 8-bit signed)
//   bytes 2+3V .. end: face index bytes        (F * 3, 8-bit unsigned)
//
// The two header bytes are latched into output registers for the top-level
// FSM and display_top to read. All payload bytes are written into shadow_mem
// at addresses starting from 0 - vertex bytes first, then face bytes.
//
// On the cycle the last expected byte arrives, `new_data_flag` is set high
// and held until the top-level FSM acknowledges by pulsing `flag_clear`.
// `writing` is high from the first byte of a packet until the cycle the
// last byte is received, so the top-level FSM can avoid starting SWAP
// while an upload is in progress.
//
// If the host sends fewer bytes than declared, this module simply waits in
// the BODY state forever. The top-level FSM is responsible for not relying
// on a timely packet completion in that case.
// =============================================================================

`timescale 1ns / 1ps
module uart_packet_decoder #(
    // Default mesh preload. When non-zero, the packet decoder boots with the
    // given V and F values so the top-level FSM knows how many vertices/faces
    // are valid. The mesh data itself must be preloaded into obj_mem via that
    // memory's MEMORY_INIT_FILE parameter (see renderer_top.v).
    //
    // We deliberately do NOT assert new_data_flag at boot: that would trigger
    // SWAP on the first vblank, which would copy from the empty shadow_mem
    // into obj_mem and wipe out the preloaded mesh. By leaving new_data_flag
    // low, the FSM goes directly from IDLE -> TRANSFORM_MVP and renders the
    // preloaded mesh straight away.
    //
    // If both parameters are zero, the system boots with no mesh and waits
    // for a UART upload as normal. Once a real packet arrives, the defaults
    // are overwritten just like any other packet.
    parameter [7:0] INIT_VERTEX_COUNT = 8'd0,
    parameter [7:0] INIT_FACE_COUNT   = 8'd0
)(
    input  wire        clk,
    input  wire        rst,

    // Byte input from uart_rx
    input  wire [7:0]  byte_data,
    input  wire        byte_valid,

    // shadow_mem write port (8-bit single-port BRAM)
    output reg  [10:0] mem_addr,
    output reg  [7:0]  mem_data,
    output reg         mem_wen,

    // Latched packet header - held across packets, updated on each new one
    output reg  [7:0]  vertex_count,
    output reg  [7:0]  face_count,

    // Status
    output reg         writing,
    output reg         new_data_flag,
    input  wire        flag_clear        // top-level pulses to ack the flag
);

    // -------------------------------------------------------------------------
    // FSM
    //   IDLE        - wait for the first byte of a new packet
    //   HEADER_F    - first byte received as vertex_count; wait for face_count
    //   BODY        - writing payload bytes into shadow_mem
    // -------------------------------------------------------------------------
    localparam IDLE     = 2'd0;
    localparam HEADER_F = 2'd1;
    localparam BODY     = 2'd2;
    reg [1:0] state;

    // -------------------------------------------------------------------------
    // Payload counter - bytes written to shadow_mem so far
    // Width 11 bits covers up to ~2048 bytes (max payload = 255*3 + 255*3 = 1530)
    // -------------------------------------------------------------------------
    reg [10:0] byte_idx;

    // Total expected payload bytes for the current packet.
    reg [10:0] payload_total;

    // Pending header values - latched as the header bytes arrive, but NOT
    // exposed on vertex_count/face_count until the whole packet is received.
    // This prevents the renderer from using the new counts against the old
    // obj_mem contents during the (potentially long) upload window. At 9600
    // baud a large mesh takes over a second to transmit; without this, the
    // renderer would draw the new vertex/face count using stale obj_mem data
    // for that entire window, producing rotating garbage that vanishes only
    // when SWAP finally runs at the end of the upload.
    reg [7:0] pending_vertex_count;
    reg [7:0] pending_face_count;

    // Power-on initial values. These set the boot mesh's counts at FPGA
    // configuration time. A logic reset does NOT touch these (see reset block),
    // so an uploaded mesh survives reset.
    initial begin
        vertex_count         = INIT_VERTEX_COUNT;
        face_count           = INIT_FACE_COUNT;
        pending_vertex_count = INIT_VERTEX_COUNT;
        pending_face_count   = INIT_FACE_COUNT;
    end

    // =========================================================================
    // FSM and datapath
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            // Reset only the FSM control state and the write strobes. The mesh
            // counts (vertex_count/face_count) and obj_mem contents persist
            // across reset - the reset button resets the rotation/view, not the
            // loaded mesh. If a reset lands mid-upload, abandoning the partial
            // packet here (state -> IDLE) leaves the counts at their last
            // committed values, which still match obj_mem. Power-on values come
            // from the register initializers below.
            state         <= IDLE;
            byte_idx      <= 11'd0;
            payload_total <= 11'd0;
            writing       <= 1'b0;
            new_data_flag <= 1'b0;
            mem_wen       <= 1'b0;
            mem_addr      <= 11'd0;
            mem_data      <= 8'd0;
            // NOTE: vertex_count, face_count, pending_* are deliberately NOT
            // reset here so the loaded mesh survives a reset.
        end else begin
            // Defaults - overridden below
            mem_wen <= 1'b0;

            // Allow the top level to clear the new_data_flag when it consumes
            // the packet (typically on entry to SWAP). flag_clear and the
            // start of a new packet are exclusive cases.
            if (flag_clear) new_data_flag <= 1'b0;

            case (state)

            // -----------------------------------------------------------------
            // IDLE - first byte of a new packet is vertex_count.
            // -----------------------------------------------------------------
            IDLE: if (byte_valid) begin
                pending_vertex_count <= byte_data;
                writing      <= 1'b1;
                byte_idx     <= 11'd0;
                state        <= HEADER_F;
            end

            // -----------------------------------------------------------------
            // HEADER_F - second byte is face_count.
            // Use byte_data directly for both multiplies - vertex_count was
            // updated on the previous clock edge and is already stable in the
            // register, so it IS the new value here. face_count hasn't been
            // latched yet so we read it from byte_data directly.
            // -----------------------------------------------------------------
            HEADER_F: if (byte_valid) begin
                pending_face_count <= byte_data;
                // payload_total = V*3 + F*3, computed with shift-add to avoid
                // a synthesized multiplier. x*3 = (x<<1) + x.
                payload_total <= ({2'd0, pending_vertex_count, 1'b0} + {3'd0, pending_vertex_count})
                               + ({2'd0, byte_data,            1'b0} + {3'd0, byte_data});
                if (pending_vertex_count == 8'd0 && byte_data == 8'd0) begin
                    // Empty mesh - no payload, packet is done. Expose the new
                    // (zero) counts now and flag completion.
                    vertex_count  <= pending_vertex_count;
                    face_count    <= byte_data;
                    writing       <= 1'b0;
                    new_data_flag <= 1'b1;
                    state         <= IDLE;
                end else begin
                    state <= BODY;
                end
            end

            // -----------------------------------------------------------------
            // BODY - write each subsequent byte into shadow_mem at byte_idx.
            // On the last expected byte, deassert writing and set the flag.
            // -----------------------------------------------------------------
            BODY: if (byte_valid) begin
                mem_addr <= byte_idx;
                mem_data <= byte_data;
                mem_wen  <= 1'b1;

                if (byte_idx == payload_total - 11'd1) begin
                    // Last byte - the full packet is now in shadow_mem.
                    // Expose the new counts NOW (atomically with new_data_flag)
                    // so the renderer doesn't use them against stale obj_mem
                    // during the upload window.
                    vertex_count  <= pending_vertex_count;
                    face_count    <= pending_face_count;
                    writing       <= 1'b0;
                    new_data_flag <= 1'b1;
                    state         <= IDLE;
                end else begin
                    byte_idx <= byte_idx + 11'd1;
                end
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule
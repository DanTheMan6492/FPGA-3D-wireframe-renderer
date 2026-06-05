// =============================================================================
// mat_mul.v  -  Systolic array matrix multiplier (Vivado 2018.2 Stable)
// =============================================================================
`timescale 1ns / 1ps
module mat_mul #(
    parameter MAX_DIM = 4
)(
    input  wire        clk,
    input  wire        rst,       // synchronous reset - clears module to IDLE

    input  wire [7:0]  N,         // Rows of A / rows of C
    input  wire [7:0]  M,         // Cols of A / rows of B (shared dimension)
    input  wire [7:0]  P,         // Cols of B / cols of C

    input  wire        write_a,   // High while streaming matrix A elements
    input  wire [15:0] data_a,    // fp16 element of A (row-major)
    input  wire        loaded_a,  // Pulse high when all of A has been streamed

    input  wire        write_b,   // High while streaming matrix B elements
    input  wire [15:0] data_b,    // fp16 element of B (row-major)
    input  wire        loaded_b,  // Pulse high when all of B has been streamed

    output reg  [15:0] data_out,  // fp16 result element, row-major
    output reg         out_valid, // Pulses high per valid output element
    output reg         busy       // High from LOADING through DRAIN
);

    // -------------------------------------------------------------------------
    // Derived constants
    // -------------------------------------------------------------------------
    localparam CELLS = MAX_DIM * MAX_DIM;
    localparam CNT_W = $clog2(CELLS);
    localparam DIM_W = $clog2(MAX_DIM + 1);

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam IDLE    = 2'd0;
    localparam LOADING = 2'd1;
    localparam FEED    = 2'd2;
    localparam DRAIN   = 2'd3;
    reg [1:0] state = IDLE;

    // -------------------------------------------------------------------------
    // Operand storage - stored with MAX_DIM stride so feed_a/feed_b can use
    // purely static (compile-time) row offsets (gi*MAX_DIM) while still
    // accessing the correct element via the runtime feed_t column offset.
    // Element at logical row r, col c goes to mat_a[r*MAX_DIM + c].
    // -------------------------------------------------------------------------
    reg [15:0] mat_a [0:CELLS-1];
    reg [15:0] mat_b [0:CELLS-1];

    // Row/col counters for the MAX_DIM-stride loading scheme.
    // Rows go from 0 to N-1/M-1; cols go from 0 to M-1/P-1.
    reg [DIM_W-1:0] row_a, col_a;  // row and col within A (N rows, M cols)
    reg [DIM_W-1:0] row_b, col_b;  // row and col within B (M rows, P cols)

    // Latched load-complete flags
    reg loaded_a_q;
    reg loaded_b_q;

    // -------------------------------------------------------------------------
    // FEED phase counter
    // -------------------------------------------------------------------------
    reg [DIM_W+2:0] feed_t;
    wire [DIM_W+3:0] feed_len  = M + 2*MAX_DIM + 1;  // +1 for PE multiply pipeline stage
    wire             feed_done = (feed_t >= feed_len);
    wire             drain_done;

    // Loop integer for initialization block
    integer k;

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE:    if (write_a || write_b)        state <= LOADING;
                LOADING: if (loaded_a_q && loaded_b_q)  state <= FEED;
                FEED:    if (feed_done)                 state <= DRAIN;
                DRAIN:   if (drain_done)                state <= IDLE;
            endcase
        end
    end

    always @(*) busy = (state != IDLE);

    // =========================================================================
    // Operand loading + padding
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            row_a <= 0; col_a <= 0;
            row_b <= 0; col_b <= 0;
            loaded_a_q <= 0;
            loaded_b_q <= 0;
            for (k = 0; k < CELLS; k = k + 1) begin
                mat_a[k] <= 16'b0;
                mat_b[k] <= 16'b0;
            end
        end else if (state == IDLE) begin
            // Reset row/col counters and clear arrays each time we're idle
            loaded_a_q <= 0;
            loaded_b_q <= 0;
            row_a <= 0; col_a <= 0;
            row_b <= 0; col_b <= 0;
            if (write_a) begin
                mat_a[0] <= data_a;    // row=0,col=0 -> index 0*MAX_DIM+0 = 0
                // Next write will be col 1 (if M>1) or next row
                if (M > 1) begin col_a <= 1; row_a <= 0; end
                else       begin col_a <= 0; row_a <= 1; end
            end
            if (write_b) begin
                mat_b[0] <= data_b;
                if (P > 1) begin col_b <= 1; row_b <= 0; end
                else       begin col_b <= 0; row_b <= 1; end
            end
        end else begin
            if (write_a) begin
                mat_a[row_a * MAX_DIM + col_a] <= data_a;
                if (col_a == M - 1) begin
                    col_a <= 0;
                    row_a <= row_a + 1;
                end else begin
                    col_a <= col_a + 1;
                end
            end
            if (write_b) begin
                mat_b[row_b * MAX_DIM + col_b] <= data_b;
                if (col_b == P - 1) begin
                    col_b <= 0;
                    row_b <= row_b + 1;
                end else begin
                    col_b <= col_b + 1;
                end
            end
            if (loaded_a) loaded_a_q <= 1;
            if (loaded_b) loaded_b_q <= 1;
        end
    end

    // =========================================================================
    // FEED counter
    // =========================================================================
    always @(posedge clk) begin
        if (rst || state != FEED)
            feed_t <= 0;
        else
            feed_t <= feed_t + 1;
    end

    // =========================================================================
    // SKEW FEED LOGIC
    // =========================================================================
    // feed_a[i] / feed_b[j]: data injected at row i / col j of the systolic
    // array each FEED cycle. Must be *wires* (continuous assignment) so the
    // PEs see the correct values at the posedge when pe_en fires. An
    // always @(*) reg would deliver values one delta-cycle late, causing the
    // PEs to sample 0 on the first accumulation cycle.
    //
    // Using MAX_DIM (compile-time constant) as the row stride avoids the
    // Synth 8-196 error from the original generate loop. The loader writes
    // elements linearly into mat_a/mat_b, but we pack them with MAX_DIM
    // stride at write time (see loading block below). feed_t is a runtime
    // signal used as an offset - that's fine in a continuous assign, unlike
    // in a genvar-based generate expression.
    wire [15:0] feed_a [0:MAX_DIM-1];
    wire [15:0] feed_b [0:MAX_DIM-1];

    assign feed_a[0] = (state==FEED && feed_t<M) ? mat_a[0*MAX_DIM + feed_t] : 16'b0;
    assign feed_a[1] = (state==FEED && feed_t<M) ? mat_a[1*MAX_DIM + feed_t] : 16'b0;
    assign feed_a[2] = (state==FEED && feed_t<M) ? mat_a[2*MAX_DIM + feed_t] : 16'b0;
    assign feed_a[3] = (state==FEED && feed_t<M) ? mat_a[3*MAX_DIM + feed_t] : 16'b0;

    assign feed_b[0] = (state==FEED && feed_t<M) ? mat_b[feed_t*MAX_DIM + 0] : 16'b0;
    assign feed_b[1] = (state==FEED && feed_t<M) ? mat_b[feed_t*MAX_DIM + 1] : 16'b0;
    assign feed_b[2] = (state==FEED && feed_t<M) ? mat_b[feed_t*MAX_DIM + 2] : 16'b0;
    assign feed_b[3] = (state==FEED && feed_t<M) ? mat_b[feed_t*MAX_DIM + 3] : 16'b0;

    // Explicitly declare only the exact delays needed for a 4x4 matrix:
    // Row/Col 0: 0 delays
    // Row/Col 1: 1 delay
    // Row/Col 2: 2 delays
    // Row/Col 3: 3 delays
    reg [15:0] a_delay_1_0, b_delay_1_0;
    
    reg [15:0] a_delay_2_0, a_delay_2_1;
    reg [15:0] b_delay_2_0, b_delay_2_1;
    
    reg [15:0] a_delay_3_0, a_delay_3_1, a_delay_3_2;
    reg [15:0] b_delay_3_0, b_delay_3_1, b_delay_3_2;

    always @(posedge clk) begin
        if (rst || state != FEED) begin
            a_delay_1_0 <= 16'b0;
            b_delay_1_0 <= 16'b0;
            
            a_delay_2_0 <= 16'b0; a_delay_2_1 <= 16'b0;
            b_delay_2_0 <= 16'b0; b_delay_2_1 <= 16'b0;
            
            a_delay_3_0 <= 16'b0; a_delay_3_1 <= 16'b0; a_delay_3_2 <= 16'b0;
            b_delay_3_0 <= 16'b0; b_delay_3_1 <= 16'b0; b_delay_3_2 <= 16'b0;
        end else begin
            // Row/Col 1 Pipeline (1 cycle delay)
            a_delay_1_0 <= feed_a[1];
            b_delay_1_0 <= feed_b[1];

            // Row/Col 2 Pipeline (2 cycle delay chain)
            a_delay_2_0 <= feed_a[2];
            a_delay_2_1 <= a_delay_2_0;
            
            b_delay_2_0 <= feed_b[2];
            b_delay_2_1 <= b_delay_2_0;

            // Row/Col 3 Pipeline (3 cycle delay chain)
            a_delay_3_0 <= feed_a[3];
            a_delay_3_1 <= a_delay_3_0;
            a_delay_3_2 <= a_delay_3_1;
            
            b_delay_3_0 <= feed_b[3];
            b_delay_3_1 <= b_delay_3_0;
            b_delay_3_2 <= b_delay_3_1;
        end
    end

    // -------------------------------------------------------------------------
    // Interconnect wire arrays & Edge Taps
    // -------------------------------------------------------------------------
    wire [15:0] h_wire [0:MAX_DIM-1][0:MAX_DIM  ];
    wire [15:0] v_wire [0:MAX_DIM  ][0:MAX_DIM-1];
    wire [15:0] o_wire [0:MAX_DIM-1][0:MAX_DIM-1];

    // Explicitly connect the edge taps directly to the named delay registers
    assign h_wire[0][0] = feed_a[0];
    assign h_wire[1][0] = a_delay_1_0;
    assign h_wire[2][0] = a_delay_2_1;
    assign h_wire[3][0] = a_delay_3_2;

    assign v_wire[0][0] = feed_b[0];
    assign v_wire[0][1] = b_delay_1_0;
    assign v_wire[0][2] = b_delay_2_1;
    assign v_wire[0][3] = b_delay_3_2;

    // -------------------------------------------------------------------------
    // PE control
    // -------------------------------------------------------------------------
    wire pe_en    = (state == FEED);
    wire pe_clear = (state == LOADING) && loaded_a_q && loaded_b_q;

    // -------------------------------------------------------------------------
    // The PE grid
    // -------------------------------------------------------------------------
    genvar i, j;
    generate
        for (i = 0; i < MAX_DIM; i = i + 1) begin : row
            for (j = 0; j < MAX_DIM; j = j + 1) begin : col
                pe pe_inst (
                    .clk   (clk),
                    .en    (pe_en),
                    .clear (pe_clear),
                    .a_in  (h_wire[i][j]),
                    .b_in  (v_wire[i][j]),
                    .a_out (h_wire[i][j+1]),
                    .b_out (v_wire[i+1][j]),
                    .c_out (o_wire[i][j])
                );
            end
        end
    endgenerate

    // =========================================================================
    // DRAIN - Incremental counters (Vivado Segfault Fix)
    // =========================================================================
    reg [7:0] r_cnt;
    reg [7:0] c_cnt;
    
    wire [15:0] result_count = N * P;
    localparam OUT_W = $clog2(MAX_DIM*MAX_DIM + 1);
    reg [OUT_W-1:0] drain_idx;

    assign drain_done = (state == DRAIN) && (drain_idx == result_count - 1);

    always @(posedge clk) begin
        if (rst) begin
            drain_idx <= 0;
            r_cnt     <= 0;
            c_cnt     <= 0;
            data_out  <= 16'b0;
            out_valid <= 1'b0;
        end else if (state == DRAIN) begin
            // STRICT BOUNDING: Truncate 8-bit counters to 2-bit for 4x4 array indexing
            // This prevents Vivado from trying to optimize out-of-bounds null pointers
            data_out  <= o_wire[r_cnt[1:0]][c_cnt[1:0]];
            out_valid <= 1'b1;

            if (drain_idx == result_count - 1) begin
                drain_idx <= 0;
                r_cnt     <= 0;
                c_cnt     <= 0;
            end else begin
                drain_idx <= drain_idx + 1;
                if (c_cnt == P - 1) begin
                    c_cnt <= 0;
                    r_cnt <= r_cnt + 1;
                end else begin
                    c_cnt <= c_cnt + 1;
                end
            end
        end else begin
            drain_idx <= 0;
            r_cnt     <= 0;
            c_cnt     <= 0;
            out_valid <= 1'b0;
        end
    end

endmodule
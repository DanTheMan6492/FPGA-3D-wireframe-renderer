// =============================================================================
// mat_mul.v  —  Systolic array matrix multiplier
// =============================================================================
// Computes C = A * B for matrices up to MAX_DIM x MAX_DIM.
//
//   A flows LEFT  -> RIGHT  (column index increments per PE)
//   B flows TOP   -> BOTTOM (row index increments per PE)
//
// Phases (FSM):
//   IDLE    — quiescent. rst clears everything.
//   LOADING — operands stream in via write_a/write_b. Waits for loaded_a/_b.
//   FEED    — skewed operand data flows into the grid edges; PEs accumulate.
//   DRAIN   — accumulators read out row-major via data_out / out_valid.
//
// SKEW: row i of A is delayed by i cycles entering the grid; column j of B is
// delayed by j cycles. Implemented with a uniform bank of shift-register delay
// stages, tapped at depth i (resp. j). See the feed logic below.
//
// STATUS: complete.
// =============================================================================

module mat_mul #(
    parameter MAX_DIM = 4
)(
    input  wire        clk,
    input  wire        rst,       // synchronous reset — clears module to IDLE

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
    localparam DIM_W = $clog2(MAX_DIM + 1);   // wide enough to count to MAX_DIM

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam IDLE    = 2'd0;
    localparam LOADING = 2'd1;
    localparam FEED    = 2'd2;
    localparam DRAIN   = 2'd3;
    reg [1:0] state = IDLE;

    // -------------------------------------------------------------------------
    // Operand storage — flat, row-major. mat_a[r*MAX_DIM + c] = A[r][c].
    // -------------------------------------------------------------------------
    reg [15:0] mat_a [0:CELLS-1];
    reg [15:0] mat_b [0:CELLS-1];
    reg [CNT_W-1:0] counter_a;     // write index for A
    reg [CNT_W-1:0] counter_b;     // write index for B

    // Latched load-complete flags
    reg loaded_a_q;
    reg loaded_b_q;

    // -------------------------------------------------------------------------
    // FEED phase counter: t = which element of each row/column is presented
    // this cycle. Also the cycle index within FEED.
    // -------------------------------------------------------------------------
    reg [DIM_W+2:0] feed_t;

    // FEED runs long enough for the last (most-delayed) data to ripple all the
    // way through the grid: M shared elements + worst-case skew on input and
    // a margin for ripple-through. M + 2*MAX_DIM is a safe upper bound.
    wire [DIM_W+3:0] feed_len  = M + 2*MAX_DIM;
    wire             feed_done = (feed_t >= feed_len);

    // Forward declaration: DRAIN completion (stubbed below).
    wire drain_done;

    // Loop integers
    integer r, c, k;

    // =========================================================================
    // FSM — single owner of `state`. Every transition lives here.
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

    // busy is the external "in use" contract: high whenever not IDLE.
    always @(*) busy = (state != IDLE);

    // =========================================================================
    // Operand loading + padding (single block, single driver of mat_a/mat_b).
    //
    // Capture is gated on write_a/write_b ONLY — never on state — so the first
    // element (arriving the same cycle the FSM decides IDLE->LOADING) is kept.
    //
    // Padding: while in IDLE the whole storage is held at zero, so once
    // streaming overwrites the active cells the unused cells remain zero.
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            counter_a  <= 0;
            counter_b  <= 0;
            loaded_a_q <= 0;
            loaded_b_q <= 0;
            for (k = 0; k < CELLS; k = k + 1) begin
                mat_a[k] <= 16'b0;
                mat_b[k] <= 16'b0;
            end
        end else if (state == IDLE) begin
            // Quiescent: keep counters/flags reset and storage zero-padded,
            // UNLESS the first element is arriving this very cycle.
            loaded_a_q <= 0;
            loaded_b_q <= 0;
            if (write_a) begin
                mat_a[0] <= data_a;
                counter_a <= 1;
            end else begin
                counter_a <= 0;
                for (k = 0; k < CELLS; k = k + 1) mat_a[k] <= 16'b0;
            end
            if (write_b) begin
                mat_b[0] <= data_b;
                counter_b <= 1;
            end else begin
                counter_b <= 0;
                for (k = 0; k < CELLS; k = k + 1) mat_b[k] <= 16'b0;
            end
        end else begin
            // LOADING (and beyond): capture streamed elements.
            if (write_a) begin
                mat_a[counter_a] <= data_a;
                counter_a <= counter_a + 1;
            end
            if (write_b) begin
                mat_b[counter_b] <= data_b;
                counter_b <= counter_b + 1;
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
    //
    // feed_a[i] : element of row i of A presented this FEED cycle (index feed_t,
    //             zero once feed_t >= M).
    // feed_b[j] : element of column j of B presented this FEED cycle.
    //
    // a_delay / b_delay : uniform shift-register banks. Row i / column j is
    //             tapped at depth i / j to realise the i / j cycle skew.
    // =========================================================================
    reg  [15:0] a_delay [0:MAX_DIM-1][0:MAX_DIM-1];
    reg  [15:0] b_delay [0:MAX_DIM-1][0:MAX_DIM-1];

    wire [15:0] feed_a [0:MAX_DIM-1];
    wire [15:0] feed_b [0:MAX_DIM-1];

    genvar gi;
    generate
        for (gi = 0; gi < MAX_DIM; gi = gi + 1) begin : feed_src
            // Row gi of A, column feed_t. A is N x M, row-major, so
            // A[gi][feed_t] is at flat index gi*M + feed_t. Stride is M,
            // the ACTUAL matrix width — not MAX_DIM.
            assign feed_a[gi] = (state == FEED && feed_t < M)
                                ? mat_a[gi*M + feed_t]
                                : 16'b0;
            // Column gi of B, row feed_t. B is M x P, row-major, so
            // B[feed_t][gi] is at flat index feed_t*P + gi. Stride is P.
            assign feed_b[gi] = (state == FEED && feed_t < M)
                                ? mat_b[feed_t*P + gi]
                                : 16'b0;
        end
    endgenerate

    // Shift-register banks. Stage 0 takes the feed source; each later stage
    // takes the previous stage.
    always @(posedge clk) begin
        if (rst || state != FEED) begin
            for (r = 0; r < MAX_DIM; r = r + 1)
                for (c = 0; c < MAX_DIM; c = c + 1) begin
                    a_delay[r][c] <= 16'b0;
                    b_delay[r][c] <= 16'b0;
                end
        end else begin
            for (r = 0; r < MAX_DIM; r = r + 1) begin
                a_delay[r][0] <= feed_a[r];
                b_delay[r][0] <= feed_b[r];
                for (c = 1; c < MAX_DIM; c = c + 1) begin
                    a_delay[r][c] <= a_delay[r][c-1];
                    b_delay[r][c] <= b_delay[r][c-1];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Interconnect wire arrays
    // -------------------------------------------------------------------------
    wire [15:0] h_wire [0:MAX_DIM-1][0:MAX_DIM  ];
    wire [15:0] v_wire [0:MAX_DIM  ][0:MAX_DIM-1];
    wire [15:0] o_wire [0:MAX_DIM-1][0:MAX_DIM-1];

    // Grid edge inputs: row i / column j tapped at delay depth i / j.
    // Row/col 0 taps the feed source directly — no delay.
    // The delay index uses (gi>0 ? gi-1 : 0) so the unused branch of the
    // ternary never produces an out-of-bounds array access.
    generate
        for (gi = 0; gi < MAX_DIM; gi = gi + 1) begin : edge_tap
            localparam TAP = (gi > 0) ? gi-1 : 0;
            assign h_wire[gi][0] = (gi == 0) ? feed_a[0] : a_delay[gi][TAP];
            assign v_wire[0][gi] = (gi == 0) ? feed_b[0] : b_delay[gi][TAP];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // PE control. pe_en accumulates during FEED; pe_clear zeroes accumulators
    // on the last LOADING cycle (just before entering FEED).
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
    // DRAIN — read the N x P active accumulator corner, row-major, one element
    // per cycle, driving data_out with out_valid high on the same cycle.
    //
    // The PE accumulators hold their values stably after FEED (nothing clears
    // them until the next job's pe_clear), so o_wire is stable throughout
    // DRAIN — there is no hazard and no rush.
    //
    //   drain_idx walks 0 .. N*P-1
    //   row = drain_idx / P    col = drain_idx % P
    //   drain_done asserts as the final element is emitted, so the FSM leaves
    //   DRAIN on the next edge — after that element was valid.
    // =========================================================================
    localparam OUT_W = $clog2(MAX_DIM*MAX_DIM + 1);
    reg [OUT_W-1:0] drain_idx;

    wire [7:0] drain_row = drain_idx / P;
    wire [7:0] drain_col = drain_idx % P;

    // Total result elements = N*P. Final index is N*P - 1.
    wire [15:0] result_count = N * P;

    // drain_done: high on the cycle the LAST element is being emitted.
    assign drain_done = (state == DRAIN) && (drain_idx == result_count - 1);

    always @(posedge clk) begin
        if (rst) begin
            drain_idx <= 0;
            data_out  <= 16'b0;
            out_valid <= 1'b0;
        end else if (state == DRAIN) begin
            // Emit the current element. data_out and out_valid are valid
            // together on this cycle.
            data_out  <= o_wire[drain_row][drain_col];
            out_valid <= 1'b1;

            if (drain_idx == result_count - 1)
                drain_idx <= 0;            // last element — reset for next job
            else
                drain_idx <= drain_idx + 1;
        end else begin
            // Not draining: hold index at 0, output idle.
            drain_idx <= 0;
            out_valid <= 1'b0;
        end
    end

endmodule
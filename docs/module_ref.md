# Module Reference

A per-module summary of every submodule in the FPGA wireframe renderer. Each
entry covers the module's purpose, its interface, and the non-obvious quirks
worth knowing when wiring it into the top level.

---

## Arithmetic primitives

### `pe`

**Purpose.** A single processing element of the systolic matrix multiplier.
Each cycle it multiplies its two inputs, accumulates the product into an
internal register, and forwards both inputs to its neighbors (registered, so
data advances exactly one PE per clock).

**Interface.**
```verilog
module pe (
    input  wire        clk,
    input  wire        en,        // accumulate enable
    input  wire        clear,     // synchronous accumulator clear
    input  wire [15:0] a_in,
    input  wire [15:0] b_in,
    output reg  [15:0] a_out,     // registered pass-through
    output reg  [15:0] b_out,
    output reg  [15:0] c_out      // accumulator
);
```

**Quirks.**
- The registered `a_out` / `b_out` are non-negotiable. Replacing them with
  combinational wires breaks the systolic skew because data would propagate
  across the whole row in one cycle instead of one PE per cycle.
- `clear` and `en` are separate signals: `clear` synchronously zeroes the
  accumulator (used once before each multiply), `en` gates accumulation per
  cycle (used to prevent spurious accumulation during input streaming and
  draining).
- Instantiates one `fp16_mul` and one `fp16_add`, so the 4×4 grid totals 16
  multipliers and 16 adders.

---

### `mat_mul`

**Purpose.** Systolic-array matrix multiplier computing C = A × B for
matrices up to `MAX_DIM × MAX_DIM` (default 4×4). Supports arbitrary `N`,
`M`, `P` dimensions at runtime via the dimension inputs; the operand
storage is zero-padded for non-full matrices.

**Interface.**
```verilog
module mat_mul #(parameter MAX_DIM = 4) (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  N, M, P,           // C is N×P, B has M rows
    input  wire        write_a,
    input  wire [15:0] data_a,
    input  wire        loaded_a,
    input  wire        write_b,
    input  wire [15:0] data_b,
    input  wire        loaded_b,
    output reg  [15:0] data_out,
    output reg         out_valid,
    output reg         busy
);
```

**Protocol.** Stream A row-major via (`write_a`, `data_a`), B row-major via
(`write_b`, `data_b`). The two streams may run concurrently or independently.
Pulse `loaded_a` / `loaded_b` once when each operand is fully streamed.
Module then feeds the systolic array, accumulates, and emits the N×P result
elements row-major via (`out_valid`, `data_out`). `busy` is high from LOADING
through DRAIN.

**Quirks.**
- Element capture is gated on `write_a` / `write_b` only, not on FSM state —
  this is critical so the first element isn't dropped during the IDLE→LOADING
  transition.
- Operand storage is zeroed in IDLE; subsequent partial streams overwrite
  only the active region, leaving the unused part correctly zero-padded for
  the systolic feed.
- After DRAIN completes, mat_mul returns to IDLE on its own — but it has
  not been definitively tested that it does so cleanly enough to accept a
  second job without an external `rst` pulse. Current callers
  (MVP_matrix_maker, the planned vertex-batch logic) defensively pulse
  `rst` between jobs. Investigating whether this is necessary is a TODO.
- Feed and drain take additional cycles beyond the operand streaming —
  budget approximately `M + 3·MAX_DIM` cycles for FEED plus `N·P` cycles
  for DRAIN.

---

### `fp16_mul`

**Purpose.** Combinational IEEE 754 half-precision multiplier with FTZ on
denormals and round-to-nearest-even on the result.

**Interface.**
```verilog
module fp16_mul (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [15:0] result
);
```

**Quirks.**
- NaN inputs are unsupported. The module assumes well-formed inputs.
- Denormals (exp == 0, mantissa != 0) are treated as zero on input. Outputs
  that would be denormal are flushed to zero.
- Tested against numpy.float16 on 20 directed and ~200 random cases — exact
  match including rounding.

---

### `fp16_add`

**Purpose.** Combinational IEEE 754 half-precision adder with FTZ and
round-to-nearest-even.

**Interface.**
```verilog
module fp16_add (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [15:0] result
);
```

**Quirks.**
- Like `fp16_mul`, no NaN support and FTZ on denormals.
- The effective-subtract path has a subtle sticky-bit adjustment: when bits
  are shifted off the smaller operand during alignment and the operation is
  an effective subtract, an extra LSB must be subtracted and the sticky
  polarity flipped, otherwise the result is off by 1 LSB. The comment in
  the source explains this; it was the bug that took two attempts to get
  right.
- Internally instantiates `clz` for normalization after subtraction.

---

### `fp16_recip`

**Purpose.** Combinational fp16 reciprocal via a 1024-entry mantissa LUT.

**Interface.**
```verilog
module fp16_recip (
    input  wire [15:0] a,
    output wire [15:0] result
);
```

**Quirks.**
- The LUT (`recip_lut.hex`) is generated by `gen_recip_lut.py` and must be
  in the project source list for `$readmemh` to find it during elaboration.
- Special cases: input 0 → ±∞ (sign preserved), input ±∞ → ±0, input
  denormal → ±∞ (FTZ-treated as zero).
- The exponent formula has a conditional `-1` for `mantissa_nonzero`,
  accounting for the fact that `1/1.0 = 1.0` needs no normalization shift
  but `1/1.x` (for nonzero x) does.

---

### `fp16_to_int`

**Purpose.** Combinational conversion from fp16 to a parameterized signed
integer width. Truncates toward zero. Saturates on overflow.

**Interface.**
```verilog
module fp16_to_int #(parameter WIDTH = 12) (
    input  wire        [15:0]      fp16_in,
    output wire signed [WIDTH-1:0] int_out
);
```

**Quirks.**
- Denormals and exact-zero map to integer 0. ±∞ saturates.
- Truncation toward zero means -3.7 → -3, +3.7 → +3. Suitable for screen
  pixel coordinates where "pixel X covers [X, X+1)".
- The intermediate magnitude width is `max(WIDTH+1, 18)` — accommodates the
  largest fp16 normal value (exp = 30, requiring a 17-bit shift).

---

### `int_to_fp16`

**Purpose.** Combinational conversion from 8-bit signed integer to fp16.
All 256 input values are exactly representable in fp16, so no rounding is
needed.

**Interface.**
```verilog
module int_to_fp16 (
    input  wire signed [7:0]  int_in,
    output wire        [15:0] fp16_out
);
```

**Quirks.**
- The `-128` case requires special handling: negating `-128` in 8 bits
  overflows back to `-128`. The module widens to 9 bits before taking the
  absolute value to avoid this.
- Instantiates `clz` to find the magnitude's MSB position for exponent
  determination.
- Tested exhaustively across all 256 input values.

---

### `clz`

**Purpose.** Parameterized count-leading-zeros — a combinational priority
encoder. Returns the number of leading zero bits before the first 1, or
`WIDTH` if the input is all zero.

**Interface.**
```verilog
module clz #(parameter WIDTH = 16) (
    input  wire [WIDTH-1:0]            value,
    output reg  [$clog2(WIDTH+1)-1:0]  count,
    output wire                        all_zero
);
```

**Quirks.**
- Output width is `$clog2(WIDTH+1)`, not `$clog2(WIDTH)`. The +1 is needed
  to represent the all-zero case where count equals WIDTH.
- Implementation scans LSB to MSB; the last 1 encountered (i.e. the MSB
  of the input) determines the count. Idiom is "last 1 wins."
- Synthesizes to a small priority encoder. Fine up to several dozen bits;
  for very large widths a tree-style implementation would be preferable.

---

## Lookup tables

### `sincos_lut`

**Purpose.** Combinational fp16 sine and cosine lookup indexed by an 8-bit
angle. Index represents a fraction of one full turn: 0 → 0°, 64 → 90°,
128 → 180°, 192 → 270°.

**Interface.**
```verilog
module sincos_lut (
    input  wire [7:0]  angle,
    output wire [15:0] sin_val,
    output wire [15:0] cos_val
);
```

**Quirks.**
- Requires `sin_lut.hex` and `cos_lut.hex` in the project source list;
  both are generated by `gen_sincos_lut.py`.
- Resolution is 360°/256 ≈ 1.4°. Adequate for visually smooth rotation.
- No octant symmetry / interpolation — full 256-entry table per axis. The
  hardware cost is negligible (~8 Kbits) and the simpler design is more
  robust.

---

## Application modules

### `bresenham`

**Purpose.** Draws a single straight line between two integer pixel
endpoints into a 32-bit-word framebuffer. Read-modify-write per pixel.

**Interface.**
```verilog
module bresenham (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [9:0]  x0, y0,
    input  wire [9:0]  x1, y1,
    output reg  [13:0] fb_addr,
    output reg  [31:0] fb_din,
    input  wire [31:0] fb_dout,
    output reg         fb_wen,
    output reg         done
);
```

**Quirks.**
- Per-pixel FSM is `READ → WAIT → MOD → WRITE` — 4 cycles per pixel. The
  WAIT state is required because SDPRAM has a one-cycle read latency from
  presenting an address to the data being usable; omitting it produces
  every-other-pixel output (the original draft hit this).
- Endpoints are 10-bit values, assumed already clipped to [0..639] × [0..479].
  The module performs no clipping itself.
- A "batched" version that buffers a 32-bit dirty word and only flushes on
  word-boundary crossings is a known optimization for halving per-pixel cost.
  Not implemented yet; the current 4-cycle cost is sufficient for realistic
  meshes but tight for the absolute worst case.

---

### `perspective_divide`

**Purpose.** Performs per-vertex perspective divide and viewport transform.
Reads 4 fp16 clip-space components (x, y, z, w) per vertex from
transform_mem, writes 2 fp16 pixel coordinates (px, py) back.

**Interface.**
```verilog
module perspective_divide (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [7:0]  vertex_count,
    output reg  [9:0]  read_addr,
    input  wire [15:0] read_data,
    output reg  [9:0]  write_addr,
    output reg  [15:0] write_data,
    output reg         write_en,
    output reg         done
);
```

**Quirks.**
- The read pipeline uses a "two states between address presentation and
  data latch" pattern to accommodate the SDPRAM 1-cycle read latency
  combined with the FSM's own non-blocking register updates. The bug here
  was the same shape as bresenham's missing WAIT state.
- Read stride is 4 (4N..4N+3), write stride is 2 (2N, 2N+1). The write
  pointer never overtakes the read pointer; reading and writing the same
  transform_mem is hazard-free.
- Pixel coordinates are computed as `(x_ndc + 1) * 320` and `(1 - y_ndc) * 240`.
  The Y flip handles NDC-up vs screen-down convention.
- The compute path is split into three pipeline stages (`COMP_REC`,
  `COMP_NDC`, `COMP_PIX`) to keep each cycle's combinational chain to at
  most two fp16 ops in series.

---

### `MVP_matrix_maker`

**Purpose.** Builds the per-frame MVP matrix. Latches rotation speeds,
advances angle registers, looks up sin/cos, constructs Rx and Ry rotation
matrices, then drives mat_mul twice: first to compute `M = Ry × Rx`, then
`MVP = (P×V) × M`. Writes the 16 fp16 result elements to transform_mem.

**Interface.**
```verilog
module MVP_matrix_maker (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire signed [7:0] speed_x, speed_y,

    // mat_mul interface (muxed at top level)
    output reg          mat_rst,
    output reg  [7:0]   mat_N, mat_M, mat_P,
    output reg          mat_write_a, mat_write_b,
    output reg  [15:0]  mat_data_a, mat_data_b,
    output reg          mat_loaded_a, mat_loaded_b,
    input  wire [15:0]  mat_data_out,
    input  wire         mat_out_valid,
    input  wire         mat_busy,

    // transform_mem write port (MVP destination)
    output reg          ram_wen,
    output reg  [3:0]   ram_addr,
    output reg  [15:0]  ram_din,

    output reg          done
);
```

**Quirks.**
- The P×V constant matrix is hardcoded as fp16 literals computed for fixed
  camera parameters (CAM_DIST=400, NEAR=10, FAR=1000, FOV=90°). If camera
  parameters change, regenerate the constants.
- Drives `mat_rst` for one cycle between its two multiplies as a defensive
  reset. Whether mat_mul actually needs this is the open TODO above.
- Instantiates two `sincos_lut` instances (one for angle_x, one for angle_y).
- The angle registers wrap naturally in 8 bits — wraparound IS the 360°
  modulus, no special handling needed.

---

### `wireframe_gen`

**Purpose.** Walks the face list of the current mesh and draws each face's
three edges into the framebuffer by invoking the internal `bresenham`
submodule.

**Interface.**
```verilog
module wireframe_gen (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [7:0]  face_count,
    input  wire [7:0]  vertex_count,

    // obj_mem read port (face indices)
    output reg  [10:0] obj_addr,
    input  wire [15:0] obj_data,

    // transform_mem read port (pixel coordinates)
    output reg  [9:0]  tf_addr,
    input  wire [15:0] tf_data,

    // framebuffer write port (pass-through from internal bresenham)
    output wire [13:0] fb_addr,
    output wire [31:0] fb_din,
    input  wire [31:0] fb_dout,
    output wire        fb_wen,

    output reg         done
);
```

**Quirks.**
- Instantiates one `bresenham` submodule internally; the `fb_*` ports just
  pass through.
- Instantiates six `fp16_to_int` converters in parallel — one per (px, py)
  coordinate of A, B, C — so all three vertex's integer coords are ready
  simultaneously after the read phase. This avoids re-running a shared
  converter sequentially.
- Pixel coordinates are clamped into [0..639] × [0..479] before being fed to
  bresenham. There is no proper line clipping; off-screen vertices are
  clamped to the screen edge, which is acceptable for well-behaved camera
  setups.
- Face data starts at `obj_mem[vertex_count * 3]` — top level must place
  vertices first, then faces.
- The same two-states-of-read-latency pattern as `perspective_divide` is
  used for both obj_mem and transform_mem reads.

---

### `framebuffer_clear`

**Purpose.** Zeroes the entire framebuffer at the start of each frame. One
32-bit word per cycle, 9,600 cycles total.

**Interface.**
```verilog
module framebuffer_clear (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg  [13:0] fb_addr,
    output reg  [31:0] fb_din,
    output reg         fb_wen,
    output reg         busy
);
```

**Quirks.**
- 9,600 cycles ≈ 96 µs at 100 MHz — well under the 1.44 ms vblank window.
- `fb_din` is always 32'b0 during the sweep.
- Top level gates wireframe_gen on `!busy` so the two never write the same
  framebuffer concurrently.
- Operates on the *back* buffer post-swap.

---

## Periphery

### `uart_rx`

**Purpose.** 8N1 UART receiver. Pulses `valid` for one cycle when a byte
arrives. No knowledge of packet structure; the top level interprets the
byte stream.

**Interface.**
```verilog
module uart_rx #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire        clk,
    input  wire        rx,
    output reg  [7:0]  data,
    output reg         valid
);
```

**Quirks.**
- Two-stage synchronizer on `rx` for metastability.
- Centered sampling: after detecting the start-bit falling edge, waits
  CLKS_PER_HALF cycles to verify the bit is still low (glitch reject),
  then samples each data bit at its center.
- `valid` is a single-cycle pulse. The top level must capture `data` on
  that cycle or lose the byte.
- Does not verify the stop bit is high. Framing errors are not detected;
  for our controlled host → FPGA stream this is acceptable.

---

### `debouncer`

**Purpose.** Cleans one asynchronous button input into a synchronous level
signal. Filters out mechanical bounce.

**Interface.**
```verilog
module debouncer #(
    parameter CLK_FREQ    = 100_000_000,
    parameter SAMPLE_RATE = 500
)(
    input  wire clk,
    input  wire btn_in,
    output reg  btn_out
);
```

**Quirks.**
- Two-stage synchronizer on `btn_in` for metastability.
- Resamples the synchronized signal at 500 Hz. The 2 ms sample period is
  comfortably longer than typical bounce (1-5 ms peak, but mostly short
  bursts), so bounce is invisible to the sampler.
- Output is a *level*. Edge detection (one-cycle rising-edge pulse, etc.)
  is the caller's responsibility.
- Instantiate once per button.

---

### `vga_controller`

**Purpose.** Drives VGA timing for 640×480 @ 60 Hz, fetches pixel data
from the front framebuffer through an internal fb_read_adapter that
widens 32-bit memory reads into per-pixel bits, and produces RGB outputs.

**Interface.** As provided by the existing implementation. Verified on real
hardware.

**Quirks.**
- The fb_read_adapter is internal: vga_controller talks to the framebuffer
  via 32-bit reads, decoding to individual bits internally. The rest of the
  system sees only "give me the bit at pixel (x, y)."
- Exposes a `vblank` (or equivalent) signal — top level uses this to trigger
  the per-frame pipeline.

---

## Top-level building blocks (not standalone modules)

### Framebuffer memories (×2)

Two SDPRAM instances, both 9,600 × 32 bits. The "front" buffer is read by
vga_controller via the fb_read_adapter; the "back" buffer is written by
framebuffer_clear and then wireframe_gen. A `swap` register flips which is
which on each vblank, implemented as a 2:1 mux on the port connections.

### obj_mem

Single-port BRAM, 16-bit wide, sized to hold the vertex coordinates (3 fp16
words per vertex) plus face data (3 16-bit-wrapped indices per face). Max
255 vertices and 255 faces, so 255·3 + 255·3 = 1530 words.

Vertices arrive via UART as 8-bit signed integers; `int_to_fp16` widens each
to fp16 during the SWAP state, which is the only time obj_mem is written
post-upload.

### shadow_mem

Single-port BRAM, 8-bit wide, sized to hold raw upload bytes during UART
streaming (vertex bytes plus face index bytes — max ~1530 bytes for largest
mesh). Written by the UART path, drained by the SWAP state which transfers
data into obj_mem (with widening through int_to_fp16 for the vertex section).

### transform_mem

True dual-port BRAM, 16-bit wide, 1024 entries.
- Port A reads (perspective_divide reads clip-space coords; wireframe_gen
  reads pixel coords).
- Port B writes (perspective_divide writes pixel coords; mat_mul writes
  transformed vertices via the top-level vertex-batch logic; MVP_matrix_maker
  writes the MVP matrix at addresses 0..15).

Layout: addresses 0..15 hold the MVP, addresses 16+ hold per-vertex data
(originally 4-component clip-space written by the vertex batch, then
overwritten with 2-component pixel coords by perspective_divide).

---

## Files generated by Python scripts

These must be present in the project source list for `$readmemh`:

- `recip_lut.hex` — generated by `gen_recip_lut.py`, used by `fp16_recip`
- `sin_lut.hex`, `cos_lut.hex` — generated by `gen_sincos_lut.py`, used
  by `sincos_lut`
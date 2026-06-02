This document describes the top-level FSM, the modules it instantiates, and how they connect. 

---

## What this project does

A real-time 3D wireframe renderer on a Basys 3 FPGA (Artix-7). It accepts an arbitrary triangle mesh — up to 255 vertices and 255 faces — uploaded from a host PC over UART, then continuously displays a rotating 2D wireframe projection of that mesh on a 640×480 VGA monitor at 60 frames per second. Four directional buttons control the rotation speed around the X and Y axes in real time; the seven-segment display shows the current vertex and face counts.

Each frame the design takes the uploaded mesh through a complete graphics pipeline implemented entirely in hardware:

1. **Build a Model-View-Projection matrix** from the user's current rotation angles and the fixed camera parameters.
2. **Transform every vertex** of the mesh through that matrix into clip space, using a shared 4×4 fp16 systolic-array multiplier.
3. **Perspective-divide and viewport-transform** each vertex into 2D pixel coordinates.
4. **Clear the back framebuffer**.
5. **Rasterize every edge** of every face using Bresenham's algorithm, read-modify-writing into the bit-packed framebuffer.
6. **Swap front and back buffers** at the next vertical blank.

The VGA controller continuously reads from the "front" buffer while the pipeline draws into the "back" buffer, so frames are produced without tearing. The whole compute pipeline operates on fp16 (half-precision) arithmetic, including a custom multiplier, adder, reciprocal, and an all-Verilog systolic-array matrix multiplier. The fp16 stack matches numpy's behavior exactly on the cases tested.

---

## Instantiated modules

The top level instantiates one of each, except where noted:

|Instance|Purpose|
|---|---|
|`uart_rx`|Receives one byte at a time from the host PC|
|`vga_controller`|Drives VGA timing and reads from the front framebuffer|
|`MVP_matrix_maker`|Builds the per-frame 4×4 MVP matrix|
|`mat_mul`|Shared systolic-array multiplier; arbitrated between MVP_matrix_maker and the vertex-batch logic|
|`perspective_divide`|Per-vertex perspective divide + viewport transform|
|`wireframe_gen`|Draws all faces' edges into the back framebuffer|
|`framebuffer_clear`|Zeroes the back framebuffer at the start of each frame|
|`display_top`|7-segment display showing vertex/face counts (provided externally)|
|`debouncer` (×4)|One per direction button: up, down, left, right|
|`obj_mem` (BRAM)|Vertex coordinates and face indices|
|`shadow_mem` (BRAM)|UART receive staging buffer|
|`transform_mem` (TDPRAM)|Per-frame transformed vertex data + MVP matrix|
|`framebuffer` (×2 SDPRAM)|Double-buffered, swapped per vblank|
|`int_to_fp16`|Used during SWAP to widen 8-bit shadow_mem bytes to fp16 obj_mem entries|
|`fp16_to_int`|Used by wireframe_gen internally (not instantiated at top level)|

The top level also implements, inline:

- The vertex-batch FSM that drives mat_mul during TRANSFORM_VERT (streams the MVP and a 4-vertex strip into mat_mul, collects transformed results into transform_mem)
- The mat_mul arbitration mux (between MVP_matrix_maker and the vertex-batch FSM)
- The framebuffer write mux (between framebuffer_clear and wireframe_gen)
- The buffer-swap register and front/back routing muxes
- Button-edge detection on each debounced output, modifying the speed_x / speed_y registers
- A vertex / face count display path feeding `display_top`
- The UART byte interpreter (counts arriving bytes against expected packet structure: vertex_count byte, face_count byte, then vertex bytes, then face index bytes; writes them into shadow_mem and sets a `new_data_flag` on completion)

---

## FSM states

The top-level state machine sequences one frame's pipeline. It runs continuously, driven by `vblank` from the VGA controller.

| State            | Description                                                                                                                                                                                                                                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `IDLE`           | Waits for vblank to start a new frame. Also handles SWAP: if `new_data_flag` is set and the UART path is not still writing shadow_mem, transition to SWAP; otherwise to TRANSFORM_MVP.                                                                                                           |
| `SWAP`           | Copies vertex coordinates from shadow_mem (8-bit signed) through `int_to_fp16` into obj_mem (16-bit fp16), and face indices through a zero-extend into obj_mem. Latches the new `vertex_count` and `face_count`. On completion, clears `new_data_flag` and proceeds to TRANSFORM_MVP.            |
| `TRANSFORM_MVP`  | Pulses MVP_matrix_maker.start. mat_mul arbitration is routed to MVP_matrix_maker. Waits for MVP_matrix_maker.done — the MVP matrix is now in transform_mem at addresses 0-15.                                                                                                                    |
| `TRANSFORM_VERT` | The inline vertex-batch FSM tiles the vertex array into 4-wide strips; for each strip, streams the MVP as A and the strip as B into mat_mul, collects transformed vertices into transform_mem. mat_mul arbitration is routed to this FSM. Loops until all `vertex_count` vertices are processed. |
| `PROJECT`        | Pulses perspective_divide.start. Waits for done. Each vertex's 4-component clip-space coords are overwritten with 2-component pixel coords in transform_mem.                                                                                                                                     |
| `CLEAR_WAIT`     | Pulses framebuffer_clear.start at the moment of vblank (or shortly after, if it hasn't completed from the previous frame). Waits for `clear_busy` to deassert. The back framebuffer is now zero.                                                                                                 |
| `RENDER`         | Pulses wireframe_gen_start. Waits for done. wireframe_gen reads face indices from obj_mem, pixel coords from transform_mem, and draws edges into the back framebuffer.                                                                                                                           |
| (back to IDLE)   | When wireframe_gen finishes, the FSM returns to IDLE to wait for the next vblank. On the next vblank rising edge, the buffer-swap register flips, framebuffer_clear starts on the new back buffer, and the cycle repeats.                                                                        |

The SWAP state branch in IDLE handles the asynchrony of UART uploads: a new mesh arriving mid-frame must wait until the _next_ IDLE before being transferred from shadow_mem into obj_mem. If the UART path is still actively writing shadow_mem when vblank arrives, IDLE self-loops one more frame.

---

## Arbitration: mat_mul

Two callers want mat_mul: MVP_matrix_maker (during TRANSFORM_MVP) and the vertex-batch FSM (during TRANSFORM_VERT). The top level holds a `mat_owner` bit and routes all mat_mul input ports through a 2:1 mux gated by it. mat_mul's outputs (`data_out`, `out_valid`, `busy`) fan out to both callers; each ignores them when not active.

`mat_owner` is set on entry to TRANSFORM_MVP (= 0, MVP path) and on entry to TRANSFORM_VERT (= 1, vertex-batch path). The vertex-batch FSM may pulse `mat_rst` between strip multiplies if needed (see the open mat_mul self- reset TODO).

---

## Arbitration: framebuffer write port

Two writers want the back framebuffer's port A: framebuffer_clear (during CLEAR_WAIT) and wireframe_gen (during RENDER). Both never overlap because RENDER is gated on `!clear_busy`. A simple priority mux routes the active writer; the inactive writer's signals are masked off.

---

## Buffer swap

A `front_buf` register selects which of the two framebuffer instances is "front" (read by vga_controller) versus "back" (written by clear and wireframe_gen). It toggles on the rising edge of vblank, exactly once per frame.

The mux is wide: each framebuffer has port A (32-bit write) and port B (32-bit read), and the swap routes:

- Active writer's `fb_addr`, `fb_din`, `fb_wen` → back's port A
- vga_controller's read → front's port B
- Active writer's `fb_dout` ← back's port B (for wireframe_gen RMW reads)

The unused ports on each buffer are tied off this frame and become active the next frame after the swap.

---

## Memory layout summary

**obj_mem (16-bit, single port):**

```
0 .. vertex_count*3 - 1        : fp16 vertex coordinates (3 per vertex: x, y, z)
vertex_count*3 .. end          : face indices (3 per face, low byte used)
```

**shadow_mem (8-bit, single port):**

```
0                  : vertex_count
1                  : face_count
2 .. 2 + vc*3 - 1  : raw 8-bit signed vertex coords (3 bytes per vertex)
2 + vc*3 .. end    : raw 8-bit face indices (3 bytes per face)
```

The first two bytes (vertex_count, face_count) are interpreted by the UART byte-counter at the top level, not stored in shadow_mem.

**transform_mem (16-bit, true dual port, 1024 entries):**

```
0 .. 15            : MVP matrix (row-major), written by MVP_matrix_maker
16 .. 16 + vc*4 - 1: clip-space transformed vertices (x, y, z, w per vertex),
                     written by the vertex-batch FSM during TRANSFORM_VERT;
                     overwritten with pixel coords during PROJECT
16 .. 16 + vc*2 - 1: after PROJECT, holds (px, py) per vertex (read by
                     wireframe_gen during RENDER)
```

Note that perspective_divide writes pixel coords starting at address `2N` (not offset by 16) — this assumes the MVP matrix has been consumed and the vertex data starts at the same low address. **Open question:** the perspective_divide and wireframe_gen modules currently address vertices starting at 0 (no MVP offset). If the MVP needs to coexist with vertex data in transform_mem, either the modules need to take a base address as input, or vertex data lives in a separate memory. Worth resolving at integration time.

**Framebuffer (32-bit, SDPRAM, ×2):**

```
9,600 words × 32 bits = 307,200 bits = 1 bit per pixel × 640 × 480
```

---

## Open integration items

- **mat_mul self-reset** — verify whether the defensive `mat_rst` pulse between consecutive multiplies is actually necessary.
- **fp16_to_int instances in wireframe_gen vs serial sharing** — currently six parallel converters are instantiated. If LUT count becomes an issue in synthesis, they could share one converter sequentially. Not expected to be needed.
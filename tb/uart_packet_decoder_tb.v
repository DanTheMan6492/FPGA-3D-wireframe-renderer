// =============================================================================
// uart_packet_decoder_tb.v  —  Testbench for the mesh upload packet decoder
// =============================================================================
// Drives byte_valid pulses with successive bytes representing a small mesh
// upload. A simulated shadow_mem records every (addr, data) write so the
// test can verify both the payload contents and the addresses.
//
// Cases:
//   1. A 3-vertex, 1-face mesh — exercises both vertex and face payload
//      regions, header latch, writing/new_data_flag timing.
//   2. flag_clear handshake — flag stays high until cleared, then drops.
//   3. A second back-to-back packet — counters reset, header re-latches.
//
// Run:
//   iverilog -g2012 -o pd_tb uart_packet_decoder.v uart_packet_decoder_tb.v
//   vvp pd_tb
// =============================================================================

`timescale 1ns / 1ps

module uart_packet_decoder_tb;

    reg         clk;
    reg         rst;
    reg  [7:0]  byte_data;
    reg         byte_valid;
    wire [10:0] mem_addr;
    wire [7:0]  mem_data;
    wire        mem_wen;
    wire [7:0]  vertex_count, face_count;
    wire        writing;
    wire        new_data_flag;
    reg         flag_clear;

    uart_packet_decoder dut (
        .clk(clk), .rst(rst),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .mem_addr(mem_addr), .mem_data(mem_data), .mem_wen(mem_wen),
        .vertex_count(vertex_count), .face_count(face_count),
        .writing(writing), .new_data_flag(new_data_flag),
        .flag_clear(flag_clear)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Simulated shadow_mem: record every write
    // -------------------------------------------------------------------------
    reg [7:0]  shadow [0:2047];
    reg [10:0] last_addr;     // verify writes are sequential
    integer    writes_total;

    always @(posedge clk) begin
        if (mem_wen) begin
            shadow[mem_addr] = mem_data;
            last_addr        = mem_addr;
            writes_total     = writes_total + 1;
        end
    end

    integer errors;

    // -------------------------------------------------------------------------
    // Helper: drive one byte with a one-cycle valid pulse
    // -------------------------------------------------------------------------
    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            byte_data  = b;
            byte_valid = 1'b1;
            @(negedge clk);
            byte_valid = 1'b0;
            byte_data  = 8'h00;
        end
    endtask

    task expect_eq;
        input [127:0]  label;
        input [31:0]   got;
        input [31:0]   exp;
        begin
            if (got !== exp) begin
                $display("FAIL [%0s]: got %0d, expected %0d", label, got, exp);
                errors = errors + 1;
            end else
                $display("ok   [%0s]: %0d", label, got);
        end
    endtask

    // -------------------------------------------------------------------------
    // Test program
    // -------------------------------------------------------------------------
    integer i;
    initial begin
        errors       = 0;
        writes_total = 0;
        rst        = 1'b1;
        byte_valid = 1'b0;
        byte_data  = 8'h00;
        flag_clear = 1'b0;

        @(negedge clk); @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("=== uart_packet_decoder test ===");

        // --- Case 1: 3-vertex, 1-face packet --------------------------------
        // vertex_count = 3, face_count = 1
        // payload = 3*3 + 1*3 = 12 bytes
        //   v0 = (10, 20, 30), v1 = (40, 50, 60), v2 = (-1, -2, -3)
        //   face = (0, 1, 2)
        $display("-- case 1: 3 verts, 1 face --");

        // Header
        send_byte(8'd3);
        expect_eq("vertex_count latched", vertex_count, 3);
        expect_eq("writing high after hdr0", writing, 1);

        send_byte(8'd1);
        expect_eq("face_count latched", face_count, 1);

        // Vertex bytes
        send_byte(8'd10);  send_byte(8'd20);  send_byte(8'd30);
        send_byte(8'd40);  send_byte(8'd50);  send_byte(8'd60);
        send_byte(8'hff);  send_byte(8'hfe);  send_byte(8'hfd);   // -1, -2, -3

        // Face bytes
        send_byte(8'd0);   send_byte(8'd1);   send_byte(8'd2);

        // After the last byte arrives, writing should drop and flag should rise
        @(negedge clk);
        expect_eq("writes_total",         writes_total, 12);
        expect_eq("last_addr",            last_addr,    11);
        expect_eq("writing low after end", writing,     0);
        expect_eq("new_data_flag set",    new_data_flag, 1);

        // Check shadow_mem contents
        expect_eq("shadow[0]  v0.x", shadow[0],  10);
        expect_eq("shadow[1]  v0.y", shadow[1],  20);
        expect_eq("shadow[2]  v0.z", shadow[2],  30);
        expect_eq("shadow[5]  v1.z", shadow[5],  60);
        expect_eq("shadow[6]  v2.x", shadow[6],  8'hff);
        expect_eq("shadow[9]  face0",shadow[9],  0);
        expect_eq("shadow[10] face1",shadow[10], 1);
        expect_eq("shadow[11] face2",shadow[11], 2);

        // --- Case 2: flag_clear handshake -----------------------------------
        $display("-- case 2: flag_clear handshake --");
        expect_eq("flag still high", new_data_flag, 1);

        @(negedge clk);
        flag_clear = 1'b1;
        @(negedge clk);
        flag_clear = 1'b0;
        @(negedge clk);
        expect_eq("flag cleared", new_data_flag, 0);

        // --- Case 3: back-to-back second packet -----------------------------
        $display("-- case 3: second packet --");
        send_byte(8'd2);
        send_byte(8'd0);                       // empty mesh — only vertex bytes
        // payload = 2*3 + 0*3 = 6
        send_byte(8'h01); send_byte(8'h02); send_byte(8'h03);
        send_byte(8'h04); send_byte(8'h05); send_byte(8'h06);

        @(negedge clk);
        expect_eq("vc updated",   vertex_count, 2);
        expect_eq("fc updated",   face_count,   0);
        expect_eq("flag re-set",  new_data_flag, 1);

        // Writes from this packet land at addr 0 again (new packet resets idx)
        expect_eq("shadow[0] reused", shadow[0], 8'h01);
        expect_eq("shadow[5]",        shadow[5], 8'h06);

        $display("=== done ===");
        if (errors == 0) $display("RESULT: ALL PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
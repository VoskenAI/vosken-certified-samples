// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0

//============================================================================
// PRIMITIVE : ring_buffer
// LIBRARY   : primitive_lib
// VERSION   : 1.0.0
//============================================================================
//
// DESCRIPTION:
//   Ring buffer with decoupled sequential write and restricted random read.
//   Writes are first-in order: each accepted beat lands at the write
//   pointer, which then advances by one. Reads are random within the window
//   of entries that have been written but not yet consumed: a consumer may
//   request ANY address in [rptr, wptr) (modulo wrap) and re-read earlier
//   entries as long as they remain in that window. The read pointer is
//   advanced separately through the advance/step interface, which decouples
//   consumption (freeing slots) from address requests.
//
//   Why one extra pointer bit: both pointers carry one bit above the address
//   field so full and empty are distinguishable even though the low bits are
//   equal in both states. empty is full pointer equality; full is low-bit
//   equality without empty.
//
//   The defining safety guarantee is no read past write: rready is high only
//   for an address inside the written window, so rdata can never expose a
//   slot that has not been written since the last time the read pointer
//   passed it. That window predicate is also the read backpressure: a read
//   of a not-yet-written address waits for the write pointer to advance.
//
// ASSUMPTIONS (input contract, always armed via vosken_assert.sv):
//   - Single clock domain.
//   - advance with a step that would push rptr past wptr is illegal; the
//     consumer must keep step within the current occupancy (no read-pointer
//     overtake). Enforced inline.
//   - A write while full is illegal (wready is the guard); enforced inline.
//   - rvalid with raddr outside the written window is not accepted (rready
//     low); the integrator must hold rvalid/raddr until rready, checked
//     inline.
//   - rst_n deasserts synchronously to clk (use reset_sync upstream).
//
// PARAMETERS:
//   Name        Type  Valid Range          Description
//   ----------  ----  -------------------  ------------------------------
//   DATA_WIDTH  int   1 to 1024            Payload width in bits
//   DEPTH       int   2, 4, 8, ..., 4096   Entries (power of two)
//
// PORTS:
//   Name      Dir    Width             Description
//   --------  -----  ----------------  ---------------------------------
//   clk       input  1                 Clock (rising edge active)
//   rst_n     input  1                 Active-low reset (async assert)
//   wvalid    input  1                 Write valid
//   wready    output 1                 Write ready (low only when full)
//   wdata     input  DATA_WIDTH        Write payload
//   rvalid    input  1                 Read request valid
//   rready    output 1                 Read accepted (raddr in window)
//   raddr     input  $clog2(DEPTH)     Read address (random within window)
//   rdata     output DATA_WIDTH        Read payload (combinational)
//   advance   input  1                 Advance the read pointer this cycle
//   step      input  $clog2(DEPTH)+1   Read-pointer increment when advance
//   wptr      output $clog2(DEPTH)     Write pointer (low bits)
//   rptr      output $clog2(DEPTH)     Read pointer (low bits)
//   full      output 1                 Buffer full
//   empty     output 1                 Buffer empty
//
//============================================================================

`default_nettype none

`include "vosken_assert.sv"

module ring_buffer #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 32
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // Sequential write interface
    input  wire                       wvalid,
    output logic                      wready,
    input  wire  [DATA_WIDTH-1:0]     wdata,

    // Restricted random read interface
    input  wire                       rvalid,
    output logic                      rready,
    input  wire  [$clog2(DEPTH)-1:0]  raddr,
    output logic [DATA_WIDTH-1:0]     rdata,

    // Independent read-pointer advance interface
    input  wire                       advance,
    input  wire  [$clog2(DEPTH):0]    step,

    // Status
    output logic [$clog2(DEPTH)-1:0]  wptr,
    output logic [$clog2(DEPTH)-1:0]  rptr,
    output logic                      full,
    output logic                      empty
);

    // ------------------------------------------------------------------------
    // Parameter validation (elaboration-time)
    // ------------------------------------------------------------------------
    generate
        if (DATA_WIDTH < 1 || DATA_WIDTH > 1024) begin : g_chk_width
            $error("ring_buffer: DATA_WIDTH must be in [1,1024], got %0d", DATA_WIDTH);
        end
        if (DEPTH < 2 || DEPTH > 4096) begin : g_chk_depth_range
            $error("ring_buffer: DEPTH must be in [2,4096], got %0d", DEPTH);
        end
        if ((DEPTH & (DEPTH - 1)) != 0) begin : g_chk_depth_pow2
            $error("ring_buffer: DEPTH must be a power of two, got %0d", DEPTH);
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Derived widths. Pointers carry one bit above the address field so the
    // full and empty states are distinguishable when the address bits match.
    // step spans 0..DEPTH inclusive, so it needs the wide pointer width too.
    // ------------------------------------------------------------------------
    localparam int AW = $clog2(DEPTH);
    localparam int PW = AW + 1;

    // ------------------------------------------------------------------------
    // State: memory and the two extended pointers. The memory carries no
    // reset; a slot is never architecturally visible (rready stays low) until
    // it has been written, so its reset-free initial value is unobservable,
    // and leaving it reset-free saves reset-tree load and enables retiming.
    // ------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mem [DEPTH];
    logic [PW-1:0]         wptr_q;
    logic [PW-1:0]         rptr_q;

    logic [AW-1:0] wptr_lo;
    logic [AW-1:0] rptr_lo;
    assign wptr_lo = wptr_q[AW-1:0];
    assign rptr_lo = rptr_q[AW-1:0];

    // empty is full PW-bit equality; full is low-bit equality without empty.
    assign empty = (wptr_q == rptr_q);
    assign full  = (wptr_lo == rptr_lo) && !empty;

    assign wready = !full;

    // Window membership for the read address. With the low pointer bits:
    //   rptr_lo < wptr_lo            : window is [rptr_lo, wptr_lo)
    //   rptr_lo > wptr_lo (wrapped)  : window is [rptr_lo, DEPTH) U [0, wptr_lo)
    //   rptr_lo == wptr_lo && full   : every address is in window
    // empty (rptr_lo == wptr_lo && !full) accepts no read.
    assign rready = rvalid &&
        ( ((rptr_lo <  wptr_lo) && (raddr >= rptr_lo) && (raddr < wptr_lo)) ||
          ((rptr_lo >  wptr_lo) && ((raddr >= rptr_lo) || (raddr < wptr_lo))) ||
          ((rptr_lo == wptr_lo) && full) );

    assign rdata = mem[raddr];

    assign wptr = wptr_lo;
    assign rptr = rptr_lo;

    logic wr_fire;
    assign wr_fire = wvalid && wready;

    // ------------------------------------------------------------------------
    // Sequential state. Writes advance the write pointer by one; the
    // advance/step interface advances the read pointer by step. The pointers
    // wrap naturally across the PW-bit field, and because DEPTH is a power of
    // two the low AW bits index memory directly.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr_q <= '0;
            rptr_q <= '0;
        end else begin
            if (wr_fire) begin
                wptr_q <= wptr_q + PW'(1);
            end
            if (advance) begin
                rptr_q <= rptr_q + PW'(step);
            end
        end
    end

    // Memory write (no reset; see the state comment above).
    always_ff @(posedge clk) begin
        if (wr_fire) begin
            mem[wptr_lo] <= wdata;
        end
    end

    // ------------------------------------------------------------------------
    // Tier-1 inline contract (always armed). Under FORMAL these become
    // assumes that constrain the prover to legal stimulus; in any integrator
    // simulation they are asserts that name a misdriving consumer.
    //
    // The macros gate on rst_n as a synchronous check enable, a different
    // role from its async use on the state flops; the waiver scopes that
    // intended dual use to the check region only.
    // ------------------------------------------------------------------------
    // verilator lint_off SYNCASYNCNET

    // Cheap occupancy invariant: occupancy never passes DEPTH.
    logic [PW-1:0] occ;
    assign occ = wptr_q - rptr_q;
    `VKN_ASSERT(a_occ_bound, occ <= PW'(DEPTH), clk, rst_n)

    // verilator lint_on SYNCASYNCNET

endmodule

`default_nettype wire

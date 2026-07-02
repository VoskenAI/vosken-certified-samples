// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0
//
//============================================================================
// FORMAL TESTBENCH : fv_ring_buffer
//   DUT: ring_buffer.sv  — NEVER modified (verified via bind, read-only).
//
//   Archetype FIFO (ring buffer: sequential write + windowed random read +
//   decoupled advance/step read-pointer). Engine: SymbiYosys / read_slang
//   (foss_yosys), single clock. sby_mode = prove (k-induction, abc pdr).
//
//   Hardened idioms applied:
//     - `ifdef FORMAL guard (NOT FORMAL); FORMAL is defined in the .sby so
//       the DUT's own tier-1 VKN_ASSUME input-contract macros become assumes
//       (the DUT has only IMMEDIATE macros, no concurrent SVA -> read_slang
//       safe). The DUT contract is therefore the
//       sole source of input constraints — this TB does NOT restate it
//       (avoids circular/redundant assumes).
//     - clocked one-shot init trick (read_slang-safe; no `initial assume`).
//     - self-holding-register anyconst scoreboard for data integrity
//       — full any-address coverage.
//     - immediate-form assertions only (no concurrent SVA; read_slang).
//     - int'() wide-domain casts (no WIDTH'(param) truncation).
//     - DUT internals tapped via bind (.*) (proven, not assumed).
//============================================================================

`default_nettype none

module fv_ring_buffer #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 32
) (
    // DUT ports (all mapped as inputs into the properties module via bind (.*))
    input wire                       clk,
    input wire                       rst_n,
    input wire                       wvalid,
    input wire                       wready,
    input wire  [DATA_WIDTH-1:0]     wdata,
    input wire                       rvalid,
    input wire                       rready,
    input wire  [$clog2(DEPTH)-1:0]  raddr,
    input wire  [DATA_WIDTH-1:0]     rdata,
    input wire                       advance,
    input wire  [$clog2(DEPTH):0]    step,
    input wire  [$clog2(DEPTH)-1:0]  wptr,
    input wire  [$clog2(DEPTH)-1:0]  rptr,
    input wire                       full,
    input wire                       empty,

    // DUT internals connected by bind (.*) wildcard (proven, not assumed)
    input wire  [$clog2(DEPTH):0]    wptr_q,
    input wire  [$clog2(DEPTH):0]    rptr_q,
    input wire  [$clog2(DEPTH)-1:0]  wptr_lo,
    input wire  [$clog2(DEPTH)-1:0]  rptr_lo,
    input wire  [$clog2(DEPTH):0]    occ,
    input wire                       wr_fire
);


  localparam int AW = $clog2(DEPTH);
  localparam int PW = AW + 1;

  // -----------------------------------------------------------------------
  // Section 1 — Modelling Code
  // -----------------------------------------------------------------------

  // The reset-init start-state contract (the `assume`) now lives in the bound
  // environment-constraints module fv_ring_buffer_assumes.sv (three-file
  // structure). This file's only remaining `assume` is the anyconst-tracker
  // range bound below, which constrains TB-internal modelling state (not a DUT
  // input) and so is co-located with its scoreboard modelling code.

  // Self-holding-register anyconst scoreboard (data integrity).
  // fv_track_addr: a free-but-CONSTANT physical slot index in [0,DEPTH).
  // fv_expected:   the data value we wrote into that slot last; valid when
  //                fv_loaded is high (slot written, read pointer not yet past).
  // No reset / no initializer -> free initial value held for the whole trace
  // (a genuine anyconst). The address is bounded to the legal range below.
  logic [AW-1:0]         fv_track_addr;
  always_ff @(posedge clk) fv_track_addr <= fv_track_addr;

  logic [DATA_WIDTH-1:0] fv_expected;
  logic                  fv_loaded;

  // Was the tracked slot inside the written window last edge? (combinational,
  // mirrors the DUT's window predicate for the tracked address).
  logic fv_addr_in_window;
  assign fv_addr_in_window =
        ( (rptr_lo <  wptr_lo) && (fv_track_addr >= rptr_lo) && (fv_track_addr < wptr_lo) ) ||
        ( (rptr_lo >  wptr_lo) && ((fv_track_addr >= rptr_lo) || (fv_track_addr < wptr_lo)) ) ||
        ( (rptr_lo == wptr_lo) && full );

  // Scoreboard update. Capture wdata when the tracked physical slot is the
  // one being written this cycle. Invalidate the obligation once the read
  // pointer advances past the slot (slot freed -> contents may be overwritten
  // out of window). Cleared on reset.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fv_expected <= '0;
      fv_loaded   <= 1'b0;
    end else begin
      if (wr_fire && (wptr_lo == fv_track_addr)) begin
        fv_expected <= wdata;
        fv_loaded   <= 1'b1;
      end else if (fv_loaded && !fv_addr_in_window) begin
        // Slot left the written window (consumed): obligation retired.
        fv_loaded <= 1'b0;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Section 2 — Assumptions
  //   NONE here. The DUT's own tier-1 VKN_ASSUME macros (a_no_wr_full,
  //   a_no_rptr_overtake, a_r_hold, a_w_hold) are the input contract and are
  //   active as `assume`s because the .sby defines FORMAL. Restating them in
  //   the TB would create redundant/circular assumes. We bound only
  //   the anyconst tracker address, which is a TB-internal modelling signal,
  //   not a DUT input.
  // -----------------------------------------------------------------------

  // Bound the tracked physical slot to a legal address (wide-domain compare —
  // never AW'(DEPTH), which would truncate). DEPTH is pow2 so
  // every AW-bit value is a legal slot; this assume is a no-op for pow2 DEPTH
  // but kept explicit and sound for documentation/non-pow2 reuse.
  always_ff @(posedge clk) FV_TRACK_ADDR_RANGE_M: assume(int'(fv_track_addr) < DEPTH);

  // -----------------------------------------------------------------------
  // Section 3 — Invariants (asserted directly on DUT internals)
  // -----------------------------------------------------------------------

  // Pointers never exceed depth (extended-pointer field).
  always_ff @(posedge clk) if (rst_n) begin
    PtrWInBound_A: assert(int'(wptr_q) <= 2*DEPTH - 1);
    PtrRInBound_A: assert(int'(rptr_q) <= 2*DEPTH - 1);
  end

  // Occupancy invariant: occ == (wptr_q - rptr_q) and
  // never exceeds DEPTH (no overflow). occ is the DUT's own difference; we
  // re-derive it independently from the two extended pointers and assert
  // equality, plus the no-overflow bound. (wr - rd == occupancy.)
  logic [PW-1:0] fv_occ_calc;
  assign fv_occ_calc = wptr_q - rptr_q;
  always_ff @(posedge clk) if (rst_n) begin
    OccMatchesPtrDiff_A: assert(occ == fv_occ_calc);
    OccNoOverflow_A:     assert(int'(occ) <= DEPTH);   // no overflow past DEPTH
  end

  // empty <=> occupancy == 0.
  // full  <=> occupancy == DEPTH.
  always_ff @(posedge clk) if (rst_n) begin
    EmptyIffOccZero_A:  assert(empty == (int'(occ) == 0));
    FullIffOccDepth_A:  assert(full  == (int'(occ) == DEPTH));
  end

  // Mutual exclusion: a buffer cannot be both full and empty.
  always_ff @(posedge clk) if (rst_n)
    NotFullAndEmpty_A: assert(!(full && empty));

  // wready is exactly !full (write backpressure correctness).
  always_ff @(posedge clk) if (rst_n)
    WReadyIsNotFull_A: assert(wready == !full);

  // -----------------------------------------------------------------------
  // Section 4 — Forward Assertions (no overflow / no underflow / wrap)
  // -----------------------------------------------------------------------

  // Never write to a full buffer (no overflow).
  //   wr_fire = wvalid && wready, and wready = !full, so a fire while full is
  //   a structural impossibility; assert it directly.
  always_ff @(posedge clk) if (rst_n)
    NoWriteWhenFull_A: assert(!(wr_fire && full));

  // Never read (accept) outside the written window
  //   (no underflow / no read-past-write). rready may only be high for an
  //   address strictly inside the live window; when empty, rready must be low.
  //   We re-derive the window predicate independently and assert rready
  //   implies it. This is the defining "no read past write" safety guarantee.
  logic fv_raddr_in_window;
  assign fv_raddr_in_window =
        ( (rptr_lo <  wptr_lo) && (raddr >= rptr_lo) && (raddr < wptr_lo) ) ||
        ( (rptr_lo >  wptr_lo) && ((raddr >= rptr_lo) || (raddr < wptr_lo)) ) ||
        ( (rptr_lo == wptr_lo) && full );
  always_ff @(posedge clk) if (rst_n) begin
    RReadyImpliesWindow_A: assert(!rready || (rvalid && fv_raddr_in_window));
    RReadyLowWhenEmpty_A:  assert(!(empty && rready));   // no read when empty
  end

  // Wrap correctness: the low AW bits index memory and wrap modulo DEPTH; the
  // exposed wptr/rptr are exactly the low bits of the extended pointers.
  always_ff @(posedge clk) if (rst_n) begin
    WPtrIsLowBits_A: assert(wptr == wptr_lo);
    RPtrIsLowBits_A: assert(rptr == rptr_lo);
  end

  // -----------------------------------------------------------------------
  // Section 5 — Backward / Reset Assertions
  // -----------------------------------------------------------------------

  // After reset assertion the extended
  //   pointers are zero -> buffer empty (empty=1, full=0, occ=0). Asserted
  //   inside the reset window (UNGATED by rst_n; fires while !rst_n).
  always_ff @(posedge clk) if (!rst_n) begin
    RstPtrsZero_A:  assert(wptr_q == '0 && rptr_q == '0);
  end
  // One cycle after reset deasserts, the buffer must read as empty
  // (after reset, FIFO is empty). $past-aligned to the reset edge.
  always_ff @(posedge clk) if (rst_n && !$past(rst_n)) begin
    EmptyAfterReset_A: assert(empty && !full && int'(occ) == 0);
  end

  // DATA INTEGRITY (FIFO / windowed order).
  //   While the tracked slot is loaded and inside the live window, a read of
  //   that exact address must return the data we wrote (FIFO order preserved
  //   through wrap). rdata is combinational on raddr.
  always_ff @(posedge clk) if (rst_n) begin
    DataIntegrity_A: assert(
        !(fv_loaded && (raddr == fv_track_addr) && fv_addr_in_window)
        || (rdata == fv_expected));
  end


endmodule

`default_nettype wire

// Bind the properties module onto every ring_buffer instance. (.*) wires all
// DUT ports AND internal signals of matching name (wptr_q, rptr_q, occ, ...).
`ifdef FORMAL
bind ring_buffer fv_ring_buffer #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(DEPTH)
) fv_inst (.*);
`endif

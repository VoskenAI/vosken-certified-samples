// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0
//
//============================================================================
// FORMAL ENVIRONMENT CONSTRAINTS : fv_ring_buffer_assumes
// DUT                            : ring_buffer (DATA_WIDTH=32, DEPTH=32)
//============================================================================
// Environment constraints for ring_buffer that reference ONLY DUT inputs live
// HERE (three-file structure). The reset-init start-state pin is migrated here.
//
// No restated contracts: the ring_buffer DUT ALREADY embeds its own tier-1 VKN_ASSUME
// input-contract macros (a_no_wr_full, a_no_rptr_overtake, a_r_hold, a_w_hold)
// under `ifdef FORMAL. Under -D FORMAL those expand to `assume` and ARE the
// prover's input contract. We do NOT restate them here (that would be a
// redundant/circular assume). This module therefore carries ONLY the
// formal start-state pin.
//
// NOTE: the anyconst scoreboard-tracker bound (FV_TRACK_ADDR_RANGE_M) constrains
// a TB-INTERNAL modelling register (fv_track_addr, declared in fv_ring_buffer.sv
// and consumed by the data-integrity assertion), not a DUT input — it is NOT an
// environment constraint and remains co-located with its modelling code in the TB.
//============================================================================

`include "vosken_assert.sv"

`default_nettype none

module fv_ring_buffer_assumes #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 32
) (
    input wire                       clk,
    input wire                       rst_n,
    // DUT ports referenced by the input-channel environment contracts.
    // wready, rready are DUT outputs; wptr_q/rptr_q are internal nets,
    // both accessible post-flatten via bind.
    input wire                       wvalid,
    input wire                       wready,
    input wire [DATA_WIDTH-1:0]      wdata,
    input wire                       rvalid,
    input wire                       rready,
    input wire [$clog2(DEPTH)-1:0]   raddr,
    input wire                       advance,
    input wire [$clog2(DEPTH):0]     step,
    input wire                       full,
    // Internal extended pointers (accessible via bind post-flatten)
    input wire [$clog2(DEPTH):0]     wptr_q,
    input wire [$clog2(DEPTH):0]     rptr_q
);

    // ------------------------------------------------------------------------
    // Section 1 — Reset-init one-shot (formal start-state contract)
    // ------------------------------------------------------------------------
    // Force the solver to start with reset ASSERTED in cycle 0 so every proof
    // trace begins from a real reset state. Directly labelled clocked assume
    // (NEVER `initial assume` on the slang path; NOT routed through VKN_ASSUME,
    // which is reset-gated and would make the start-state pin vacuous).
    logic fv_assumes_init_r = 1'b0;
    always_ff @(posedge clk) fv_assumes_init_r <= 1'b1;
    always_ff @(posedge clk)
        FV_ASSUMES_RST_INIT_M: assume(fv_assumes_init_r || !rst_n);  // active-low: reset low in cycle 0

    // ------------------------------------------------------------------------
    // Section 2 — Input environment constraints (VKN_ASSUME / VKN_ASSUME_PAST)
    // ------------------------------------------------------------------------
    // No write when full: wready is the guard and the integrator must honor it.
    `VKN_ASSUME(a_no_wr_full, !(wvalid && full), clk, rst_n)

    // Read-pointer overtake guard: an advance must not push rptr past wptr.
    // occ is the current occupancy (0..DEPTH); step beyond it would overtake.
    localparam int PW = $clog2(DEPTH) + 1;
    logic [PW-1:0] fv_occ;
    assign fv_occ = wptr_q - rptr_q;
    `VKN_ASSUME(a_no_rptr_overtake, !advance || (step <= fv_occ), clk, rst_n)

    // Read request stability: an offered read holds rvalid and raddr until
    // accepted (valid_ready discipline on the read request channel).
    `VKN_ASSUME_PAST(a_r_hold,
        !($past(rvalid) && !$past(rready))
            || (rvalid && (raddr == $past(raddr))),
        clk, rst_n)

    // Write data stability: an offered write holds wvalid and wdata until
    // accepted.
    `VKN_ASSUME_PAST(a_w_hold,
        !($past(wvalid) && !$past(wready))
            || (wvalid && (wdata == $past(wdata))),
        clk, rst_n)

endmodule

`default_nettype wire

// ----------------------------------------------------------------------------
// bind — attach the environment-constraints module to every ring_buffer instance.
// DUT ports and internal nets (wptr_q, rptr_q) referenced by the constraints
// are wired (accessible post-flatten via bind).
// ----------------------------------------------------------------------------
bind ring_buffer fv_ring_buffer_assumes #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
) fv_ring_buffer_assumes_i (
    .clk     (clk),
    .rst_n   (rst_n),
    .wvalid  (wvalid),
    .wready  (wready),
    .wdata   (wdata),
    .rvalid  (rvalid),
    .rready  (rready),
    .raddr   (raddr),
    .advance (advance),
    .step    (step),
    .full    (full),
    .wptr_q  (wptr_q),
    .rptr_q  (rptr_q)
);

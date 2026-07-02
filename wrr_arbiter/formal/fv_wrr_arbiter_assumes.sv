// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0
//
//============================================================================
// FORMAL ENVIRONMENT CONSTRAINTS : fv_wrr_arbiter_assumes
// DUT                            : wrr_arbiter
//============================================================================
// Environment / input-stability constraints for wrr_arbiter live HERE, never
// inline in fv_wrr_arbiter.sv. (Migrated from fv_wrr_arbiter.sv Section "Reset
// anchor" + "Config-strap freeze" — three-file structure.)
//
// What moved here (A and B):
//   A. FV_ASSUMES_RST_INIT_M  — reset start-state pin (was FV_RST_INIT_M, the
//      clocked init-trick reset anchor). Pins rst_n LOW in cycle 0 so the prover
//      starts from a true reset state. DIRECT labelled clocked assume (not
//      VKN_ASSUME, which is reset-gated `if (rst_n)` and would make the
//      reset-init pin vacuous).
//   B. FV_WEIGHT_STRAP_M      — config-strap freeze of `weight` across the
//      reset-deassertion edge. A genuine input/config-stability environment
//      constraint on the DUT input `weight`. The RTL tier-1 a_weight_stable
//      holds weight constant only while (rst_n && $past(rst_n)) — it SKIPS the
//      deassert edge — yet the quota bank loads from weight AT that edge, so
//      weight must also be stable across it for quota==weight in cycle 1. This
//      strap completes that contract.
//
//      Its guard is the ORIGINAL `if (!fv_init_r)` (every cycle EXCEPT cycle 0),
//      NOT rst_n. That difference is load-bearing: the strap must hold across
//      the reset edge, where rst_n-gated forms (VKN_ASSUME_PAST: gated by
//      rst_n && $past(rst_n)) would not fire. So it is kept as an EXPLICIT
//      clocked assume reusing the same init one-shot, NOT routed through
//      VKN_ASSUME_PAST. Guard equivalence: the original one-shot fv_init_r was
//      1'b1 in cycle 0 then 1'b0 (so `if (!fv_init_r)` = cycle 1 onward); the
//      one-shot below is 1'b0 in cycle 0 then 1'b1 (so `if (fv_assumes_init_r)`
//      = cycle 1 onward) — identical timing, inverted polarity.
//
// What did NOT move (kept in fv_wrr_arbiter.sv): FV_FIDX_RANGE_M — the
// anyconst-domain bound (f_idx <= IDX_MAX) on the no-starvation symbolic
// requester index. f_idx is a proof-construction free variable that LIVES in
// the assertion module and is read by the no-starvation assertions there; it is
// not a DUT input. Moving its domain restriction out (without moving f_idx,
// which cannot move) would be unsound, so it stays inline as a documented
// exception.
//============================================================================

`include "vosken_assert.sv"

`default_nettype none

module fv_wrr_arbiter_assumes #(
    parameter int NUM_IN       = 4,
    parameter int DATA_WIDTH   = 32,
    parameter int WEIGHT_WIDTH = 4
) (
    input wire                           clk,
    input wire                           rst_n,
    // Only the DUT INPUT the environment constraints reference: the flat
    // [NUM_IN*WEIGHT_WIDTH-1:0] weight bus (B). A references rst_n only.
    input wire [NUM_IN*WEIGHT_WIDTH-1:0] weight
);

    // ------------------------------------------------------------------------
    // Section 1 — Reset-init one-shot (formal start-state contract)  [A]
    // ------------------------------------------------------------------------
    // Force the solver to start with reset ASSERTED in cycle 0. NOT routed
    // through VKN_ASSUME: that macro is reset-gated (`if (rst_n)`), which would
    // make the reset-init pin vacuous. Directly labelled clocked assume — the
    // house pattern for the start-state pin. (Migrated from FV_RST_INIT_M.)
    logic fv_assumes_init_r = 1'b0;
    always_ff @(posedge clk) fv_assumes_init_r <= 1'b1;
    always_ff @(posedge clk)
        FV_ASSUMES_RST_INIT_M: assume (fv_assumes_init_r || !rst_n);  // active-low: reset low in cycle 0

    // ------------------------------------------------------------------------
    // Section 2 — Config-strap freeze of `weight` across the reset edge  [B]
    // ------------------------------------------------------------------------
    // EXACT original guard `if (!fv_init_r)` (every cycle except cycle 0),
    // re-expressed against the inverted one-shot above as `if (fv_assumes_init_r)`
    // (same timing). Deliberately NOT VKN_ASSUME_PAST — that macro's guard
    // (rst_n && $past(rst_n)) skips the reset-deassertion edge, which is exactly
    // the edge this strap must cover. Preserve the explicit form.
    always_ff @(posedge clk) begin : fv_weight_strap
        if (fv_assumes_init_r) begin
            FV_WEIGHT_STRAP_M: assume (weight == $past(weight));
        end
    end

endmodule

`default_nettype wire

// ----------------------------------------------------------------------------
// bind — attach the environment-constraints module to EVERY wrr_arbiter
// instance (all 3 swept configs), matching how fv_wrr_arbiter is bound in
// fv_wrr_arbiter_bind.sv. Only the DUT INPUT ports the constraints reference
// are wired (clk, rst_n, weight). NUM_IN / DATA_WIDTH / WEIGHT_WIDTH propagate.
// ----------------------------------------------------------------------------
bind wrr_arbiter fv_wrr_arbiter_assumes #(
    .NUM_IN       (NUM_IN),
    .DATA_WIDTH   (DATA_WIDTH),
    .WEIGHT_WIDTH (WEIGHT_WIDTH)
) fv_wrr_arbiter_assumes_i (
    .clk    (clk),
    .rst_n  (rst_n),
    .weight (weight)
);

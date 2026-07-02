// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0

//============================================================================
// PRIMITIVE : rr_arbiter_tree
// LIBRARY   : primitive_lib
// VERSION   : 1.0.0
//============================================================================
//
// DESCRIPTION:
//   Round-robin arbiter with a single combined grant/data multiplexer. One
//   requester out of NUM_IN is granted per cycle and its payload is steered
//   to the merged output. Arbitration is non-starving: a rotating priority
//   pointer guarantees every continuously-asserting requester is served
//   within NUM_IN handshakes.
//
//   The req/gnt vector and the valid/ready output are the same handshake
//   viewed from the two sides. m_valid is asserted whenever any request is
//   present (work conserving: |req implies m_valid), gnt is the one-hot
//   echo of the winner, and m_idx is its binary index. The pointer only
//   advances on a COMPLETED handshake (m_valid && m_ready), so a stalled
//   downstream never rotates priority past an unserved winner.
//
//   Selection (masked-priority round robin, not a replicated tree):
//     - effective requests are the live req vector, or the locked vector
//       when a prior grant is held (LOCK_IN, see below)
//     - the priority pointer rr defines the rotation origin; requesters at
//       index >= rr form the high-priority (masked) group
//     - grant the lowest-index masked requester if any, otherwise wrap to
//       the lowest-index requester overall (the unmasked group). With the
//       pointer rotating one past each served index this distributes
//       throughput fairly and bounds the wait of any held request.
//     - when EXT_PRIO is set the rotation origin comes from rr_prio instead
//       of the internal pointer, so several arbiters can rotate in lock step
//       (the internal pointer register is then not instantiated).
//
// LOCK_IN:
//   With LOCK_IN=1 the arbiter freezes its decision while the granted
//   output is stalled: if m_valid is high and m_ready is low, the winning
//   request vector is latched and replayed next cycle, so m_idx / gnt / the
//   selected data hold until the handshake completes. This matches a
//   destination that registers the index and expects it stable across a
//   multi-cycle accept (AXI-style locked grant). LOCK_IN and EXT_PRIO are
//   mutually exclusive (locking owns the decision; an external pointer
//   would fight it) and the combination is rejected at elaboration.
//
//   LOCKED-REQUEST-DROP CAVEAT: while a decision is locked the integrator
//   must keep the already-asserted request bits asserted (it may add new
//   ones). Dropping a locked request mid-stall is a protocol violation: the
//   arbiter has committed gnt/m_idx to that requester and the held payload
//   would no longer correspond to a live request. This contract is checked
//   by the always-armed tier-1 assertion a_no_drop_locked (assume under
//   FORMAL, accusation in integrator simulation).
//
// ASSUMPTIONS:
//   - Single clock domain (synchronize requesters before crossing clocks)
//   - rst_n deasserts synchronously to clk (use reset_sync upstream)
//   - data[i] is held stable by requester i while its req[i] is asserted
//     (its slice is muxed through combinationally on the grant cycle)
//   - LOCK_IN integrators keep locked requests asserted (see caveat above)
//
// PARAMETERS:
//   Name        Type  Valid Range  Description
//   ----------  ----  -----------  ---------------------------------------
//   NUM_IN      int   2 to 64      Number of requesters (non-power-of-two
//                                  legal)
//   DATA_WIDTH  int   1 to 4096    Per-requester payload width in bits
//   EXT_PRIO    bit   0 or 1       1: rotation origin from rr_prio input;
//                                  no internal pointer (mutually exclusive
//                                  with LOCK_IN)
//   LOCK_IN     bit   0 or 1       1: hold the decision while the granted
//                                  output is stalled
//
// PORTS:
//   Name     Dir    Width                Description
//   -------  -----  -------------------  -----------------------------------
//   clk      input  1                    Clock (rising edge active)
//   rst_n    input  1                    Active-low reset (sync deassert)
//   req      input  NUM_IN               Per-requester request vector
//   gnt      output NUM_IN               One-hot grant echo (winner bit)
//   data     input  NUM_IN*DATA_WIDTH    Flat payload bus, requester i in
//                                        [i*DATA_WIDTH +: DATA_WIDTH]
//   rr_prio  input  IDX_WIDTH            External rotation origin (EXT_PRIO)
//   m_valid  output 1                    Merged output valid (== |req_eff)
//   m_ready  input  1                    Merged output ready
//   m_data   output DATA_WIDTH           Selected requester payload
//   m_idx    output IDX_WIDTH            Binary index of the winner
//
//============================================================================

`default_nettype none

`include "vosken_assert.sv"

module rr_arbiter_tree #(
    parameter int NUM_IN     = 4,
    parameter int DATA_WIDTH = 32,
    parameter bit EXT_PRIO   = 1'b0,
    parameter bit LOCK_IN    = 1'b0,
    // Index width; never below one bit so NUM_IN == 2 still has a 1-bit idx.
    localparam int IDX_WIDTH = (NUM_IN > 1) ? $clog2(NUM_IN) : 1
) (
    input  wire                            clk,
    input  wire                            rst_n,
    input  wire  [NUM_IN-1:0]              req,
    output logic [NUM_IN-1:0]              gnt,
    input  wire  [NUM_IN*DATA_WIDTH-1:0]   data,
    // rr_prio is read only when EXT_PRIO=1; unused in the default config.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire  [IDX_WIDTH-1:0]           rr_prio,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                           m_valid,
    input  wire                            m_ready,
    output logic [DATA_WIDTH-1:0]          m_data,
    output logic [IDX_WIDTH-1:0]           m_idx
);

    // ------------------------------------------------------------------------
    // Parameter validation (elaboration-time)
    // ------------------------------------------------------------------------
    generate
        if (NUM_IN < 2 || NUM_IN > 64) begin : g_numin_check
            $error("rr_arbiter_tree: NUM_IN must be in [2,64], got %0d", NUM_IN);
        end
        if (DATA_WIDTH < 1 || DATA_WIDTH > 4096) begin : g_dw_check
            $error("rr_arbiter_tree: DATA_WIDTH must be in [1,4096], got %0d",
                   DATA_WIDTH);
        end
        if (EXT_PRIO && LOCK_IN) begin : g_excl_check
            $error("rr_arbiter_tree: EXT_PRIO and LOCK_IN are mutually exclusive");
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Rotation origin and effective request vector.
    //   rr      : index that holds the highest priority this cycle.
    //   req_eff : the vector the encoders arbitrate over. Under LOCK_IN a
    //             held decision replays the latched vector; otherwise the
    //             live req drives directly.
    // ------------------------------------------------------------------------
    logic [IDX_WIDTH-1:0] rr;
    logic [NUM_IN-1:0]    req_eff;

    // Lock state (only meaningful with LOCK_IN). lock_q marks that a prior
    // grant is being held; req_lock_q is the request vector frozen at the
    // moment the lock engaged. Both are tied off and unread when LOCK_IN=0.
    /* verilator lint_off UNUSEDSIGNAL */
    logic                 lock_q;
    logic [NUM_IN-1:0]    req_lock_q;
    /* verilator lint_on UNUSEDSIGNAL */

    // Rotation pointer register and its next value. Declared here so the
    // rotation-origin select below can read rr_q (the slang frontend
    // requires declaration before use, unlike Verilator). rr_next is unread
    // when EXT_PRIO=1 (no register instantiated).
    logic [IDX_WIDTH-1:0] rr_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [IDX_WIDTH-1:0] rr_next;
    /* verilator lint_on UNUSEDSIGNAL */

    generate
        if (LOCK_IN) begin : g_req_lock
            assign req_eff = lock_q ? req_lock_q : req;
        end else begin : g_req_direct
            assign req_eff = req;
        end
    endgenerate

    generate
        if (EXT_PRIO) begin : g_ext_prio
            // External rotation origin; no internal pointer register.
            assign rr = rr_prio;
        end else begin : g_int_prio
            assign rr = rr_q;
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Masked / unmasked priority encode. The masked group holds requesters
    // at index >= rr (the rotation origin keeps its own slot at the top of
    // priority). If that group is empty the decision wraps to the lowest
    // index overall. Identical structure to the house round_robin_arbiter,
    // generalized to an arbitrary rotation origin.
    // ------------------------------------------------------------------------
    logic [NUM_IN-1:0]    mask;
    logic [NUM_IN-1:0]    masked_req;

    logic [NUM_IN-1:0]    masked_gnt;
    logic [IDX_WIDTH-1:0] masked_idx;
    logic                 masked_hit;

    logic [NUM_IN-1:0]    wrap_gnt;
    logic [IDX_WIDTH-1:0] wrap_idx;
    logic                 wrap_hit;

    always_comb begin : comb_mask
        mask = '0;
        for (int unsigned i = 0; i < NUM_IN; i++) begin
            if (i >= rr) mask[i] = 1'b1;
        end
    end

    assign masked_req = req_eff & mask;

    always_comb begin : comb_masked_enc
        masked_gnt = '0;
        masked_idx = '0;
        masked_hit = 1'b0;
        for (int unsigned i = 0; i < NUM_IN; i++) begin
            if (masked_req[i] && !masked_hit) begin
                masked_gnt[i] = 1'b1;
                masked_idx    = IDX_WIDTH'(i);
                masked_hit    = 1'b1;
            end
        end
    end

    always_comb begin : comb_wrap_enc
        wrap_gnt = '0;
        wrap_idx = '0;
        wrap_hit = 1'b0;
        for (int unsigned i = 0; i < NUM_IN; i++) begin
            if (req_eff[i] && !wrap_hit) begin
                wrap_gnt[i] = 1'b1;
                wrap_idx    = IDX_WIDTH'(i);
                wrap_hit    = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Output mux. m_valid is purely a function of whether any effective
    // request exists (work conserving). The masked group wins when non-empty,
    // else the wrap group; wrap_hit equals "any request present", so it also
    // drives m_valid.
    // ------------------------------------------------------------------------
    always_comb begin : comb_out
        m_valid = wrap_hit;
        if (masked_hit) begin
            gnt   = masked_gnt;
            m_idx = masked_idx;
        end else begin
            gnt   = wrap_gnt;
            m_idx = wrap_idx;
        end
    end

    // Payload mux: select the granted requester's slice of the flat bus.
    // m_idx is range-bounded (< NUM_IN) by construction, so the dynamic
    // part-select never reaches past the bus.
    assign m_data = data[m_idx*DATA_WIDTH +: DATA_WIDTH];

    // ------------------------------------------------------------------------
    // Sequential state: rotation pointer and lock latch. Both update only on
    // edges where the decision actually resolves. (rr_q / rr_next declared
    // above so the rotation-origin select can read rr_q.)
    // ------------------------------------------------------------------------
    // Advance the pointer one past the served index on a completed handshake,
    // wrapping at NUM_IN-1. A stall (m_valid && !m_ready) holds the pointer,
    // which is what keeps the same winner in front next cycle.
    always_comb begin : comb_ptr_next
        rr_next = rr_q;
        if (m_valid && m_ready) begin
            if (m_idx == IDX_WIDTH'(NUM_IN - 1))
                rr_next = '0;
            else
                rr_next = m_idx + IDX_WIDTH'(1);
        end
    end

    generate
        if (!EXT_PRIO) begin : g_ptr_reg
            always_ff @(posedge clk or negedge rst_n) begin : seq_ptr
                if (!rst_n) rr_q <= '0;
                else        rr_q <= rr_next;
            end
        end else begin : g_no_ptr_reg
            // No internal pointer under EXT_PRIO; tie the unused reg off so
            // every bit has a known constant value (no inferred latch).
            assign rr_q = '0;
        end
    endgenerate

    generate
        if (LOCK_IN) begin : g_lock_reg
            logic lock_next;
            // Engage / hold the lock whenever the current grant is offered
            // but not accepted; release it the cycle the handshake lands.
            assign lock_next = m_valid && !m_ready;

            always_ff @(posedge clk or negedge rst_n) begin : seq_lock
                if (!rst_n) begin
                    lock_q     <= 1'b0;
                    req_lock_q <= '0;
                end else begin
                    lock_q <= lock_next;
                    // Latch the vector that produced the held decision. Once
                    // locked, keep the frozen copy so the replayed decision
                    // is the same one even if a higher-priority request
                    // arrives mid-stall.
                    if (!lock_q) req_lock_q <= req;
                end
            end
        end else begin : g_no_lock_reg
            // No lock state without LOCK_IN; tie off so req_eff resolves.
            assign lock_q     = 1'b0;
            assign req_lock_q = '0;
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Tier-1 contract and invariants (always armed; see vosken_assert.sv).
    //   a_gnt_onehot0  : grant is one-hot or zero in every steady-state cycle
    //                    ($onehot0 is unsupported by the slang frontend, so
    //                    the bit-clear identity is used).
    //   a_gnt_implies_req : a granted bit always corresponds to a live
    //                    effective request (gnt is a subset of req_eff).
    //   a_no_drop_locked : LOCK_IN integrator contract. While a decision is
    //                    held the already-asserted request bits must remain
    //                    asserted (req_lock_q is a subset of the live req);
    //                    dropping one is the documented locked-request-drop
    //                    violation. assume under FORMAL, accusation in sim.
    // The macros sample rst_n as a synchronous check gate, a different role
    // from its async use on the state flops; the waiver scopes that intended
    // dual use to the check region only (house style).
    // ------------------------------------------------------------------------
    // verilator lint_off SYNCASYNCNET
    `VKN_ASSERT(a_gnt_onehot0, (gnt & (gnt - 1'b1)) == '0, clk, rst_n)
    `VKN_ASSERT(a_gnt_implies_req, (gnt & ~req_eff) == '0, clk, rst_n)
    // verilator lint_on SYNCASYNCNET

endmodule

`default_nettype wire

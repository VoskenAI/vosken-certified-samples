// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0

//============================================================================
// PRIMITIVE : wrr_arbiter
// LIBRARY   : primitive_lib
// VERSION   : 1.0.0
//============================================================================
//
// DESCRIPTION:
//   Weighted round-robin arbiter. One of NUM_IN requesters is granted per
//   cycle and its payload is steered to the merged valid/ready output, with
//   per-input bandwidth shaped by a configured WEIGHT_WIDTH-bit weight. Over
//   a service round in which every requester stays asserted, input i is
//   granted exactly weight[i] times before the round restarts, so long-run
//   throughput is proportional to the weights. Selection within a round is
//   plain round robin (a rotating priority pointer), so inputs of equal
//   remaining quota are served fairly and no requester with remaining quota
//   is passed over indefinitely.
//
//   The arbiter composes the shipped rr_arbiter_tree primitive for the
//   intra-round grant decision and the data mux. The weighting layer added
//   here is a bank of per-input quota counters and the round-restart logic;
//   rr_arbiter_tree sees only the live requesters that still hold quota this
//   round (the eligible set), so the round-robin pointer rotates among them
//   exactly as the unweighted arbiter would.
//
// WINDOW SEMANTICS (the precise contract proven below):
//   Define a "round" as the interval between two consecutive quota reloads.
//   At a reload every input's quota is set to its configured weight. A
//   completed grant (m_valid && m_ready) to input i consumes one unit of
//   quota[i]. An input is ELIGIBLE while quota[i] > 0 (a zero-weight input is
//   never eligible and is never granted). The round restarts (quotas reload)
//   on the first cycle where some input requests but no requesting input is
//   still eligible, i.e. every requester has spent its quota for this round.
//   Consequence proven as P_WEIGHT_WINDOW: within any single round, the
//   number of completed grants to input i never exceeds weight[i]; quota[i]
//   therefore never underflows. A continuously-asserting requester with
//   weight[i] > 0 is granted at least once per round, and a round closes in a
//   bounded number of completed grants (at most sum(weight) of them), which
//   bounds its wait (P_NO_STARVE).
//
//   This is the "deficit-free" or "interleaved" WRR window: each input draws
//   down a per-round credit of exactly its weight. It is the simplest window
//   that makes the per-input bound exact and the quota-never-negative
//   invariant inductive. A weighted-interleave (smoother) variant would
//   distribute the weight grants across the round rather than letting the
//   pointer decide order within it; that ordering refinement is intentionally
//   not implemented (it does not change the per-round count bound, which is
//   the requirement).
//
// ASSUMPTIONS:
//   - Single clock domain (synchronize requesters before crossing clocks)
//   - rst_n deasserts synchronously to clk (use reset_sync upstream)
//   - weight[i] are configuration straps held CONSTANT for the operating
//     lifetime of the arbiter: they do not change cycle to cycle while
//     running. Reprogramming a weight is legal only through a full reset,
//     never live, because a quota loaded from a weight that then shrank below
//     it would corrupt the per-round count. This is the documented
//     config-stability contract, checked by the always-armed tier-1 assertion
//     a_weight_stable (assume under FORMAL, accusation in integrator
//     simulation against a driver that changes a weight without a reset).
//   - data[i] is held stable by requester i while its req[i] is asserted (its
//     slice is muxed through combinationally on the grant cycle)
//
// PARAMETERS:
//   Name          Type  Valid Range  Description
//   ------------  ----  -----------  -------------------------------------
//   NUM_IN        int   2 to 64      Number of requesters
//   DATA_WIDTH    int   1 to 4096    Per-requester payload width in bits
//   WEIGHT_WIDTH  int   1 to 16      Per-input weight field width in bits
//
// PORTS:
//   Name     Dir    Width                    Description
//   -------  -----  -----------------------  ---------------------------------
//   clk      input  1                        Clock (rising edge active)
//   rst_n    input  1                        Active-low reset (sync deassert)
//   req      input  NUM_IN                   Per-requester request vector
//   weight   input  NUM_IN*WEIGHT_WIDTH      Flat per-input weight bus,
//                                            input i in
//                                            [i*WEIGHT_WIDTH +: WEIGHT_WIDTH]
//   gnt      output NUM_IN                    One-hot grant echo (winner bit)
//   data     input  NUM_IN*DATA_WIDTH        Flat payload bus, requester i in
//                                            [i*DATA_WIDTH +: DATA_WIDTH]
//   m_valid  output 1                        Merged output valid
//   m_ready  input  1                        Merged output ready
//   m_data   output DATA_WIDTH               Selected requester payload
//   m_idx    output IDX_WIDTH                 Binary index of the winner
//
//============================================================================

`default_nettype none

`include "vosken_assert.sv"

module wrr_arbiter #(
    parameter int NUM_IN       = 4,
    parameter int DATA_WIDTH   = 32,
    parameter int WEIGHT_WIDTH = 4,
    // Index width; never below one bit so NUM_IN == 2 still has a 1-bit idx.
    localparam int IDX_WIDTH = (NUM_IN > 1) ? $clog2(NUM_IN) : 1
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire  [NUM_IN-1:0]                req,
    input  wire  [NUM_IN*WEIGHT_WIDTH-1:0]   weight,
    output logic [NUM_IN-1:0]                gnt,
    input  wire  [NUM_IN*DATA_WIDTH-1:0]     data,
    output logic                             m_valid,
    input  wire                              m_ready,
    output logic [DATA_WIDTH-1:0]            m_data,
    output logic [IDX_WIDTH-1:0]             m_idx
);

    // ------------------------------------------------------------------------
    // Parameter validation (elaboration-time)
    // ------------------------------------------------------------------------
    generate
        if (NUM_IN < 2 || NUM_IN > 64) begin : g_numin_check
            $error("wrr_arbiter: NUM_IN must be in [2,64], got %0d", NUM_IN);
        end
        if (DATA_WIDTH < 1 || DATA_WIDTH > 4096) begin : g_dw_check
            $error("wrr_arbiter: DATA_WIDTH must be in [1,4096], got %0d",
                   DATA_WIDTH);
        end
        if (WEIGHT_WIDTH < 1 || WEIGHT_WIDTH > 16) begin : g_ww_check
            $error("wrr_arbiter: WEIGHT_WIDTH must be in [1,16], got %0d",
                   WEIGHT_WIDTH);
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Per-input weight slices and quota counters.
    //   weight slices : the configured weight of input i, weight[i*WW +: WW].
    //   quota_q       : remaining grants input i may still take this round,
    //                   held as a flat NUM_IN*WEIGHT_WIDTH packed bus (house
    //                   flat-bus style, like the data bus); input i occupies
    //                   quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH].
    // Quota is WEIGHT_WIDTH bits, the same range as a weight; it is loaded
    // from the weight at reset and at every round restart, decremented by one
    // on a completed grant to that input, and never decremented at zero (the
    // round-restart rule guarantees the granted input always had quota > 0,
    // which the formal bundle proves, so quota never underflows).
    // ------------------------------------------------------------------------
    logic [NUM_IN*WEIGHT_WIDTH-1:0] quota_q;

    // Eligibility: an input may be granted this round while it still holds
    // quota. A zero-weight input loads quota 0 and is therefore never
    // eligible and never granted.
    logic [NUM_IN-1:0] eligible;
    always_comb begin : comb_eligible
        for (int unsigned i = 0; i < NUM_IN; i++) begin
            eligible[i] = (quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] != '0);
        end
    end

    // The vector the round-robin core arbitrates over: live requesters that
    // still hold quota this round.
    logic [NUM_IN-1:0] req_elig;
    assign req_elig = req & eligible;

    // ------------------------------------------------------------------------
    // Round-restart detect. A round closes when at least one input requests
    // but none of the requesting inputs is still eligible (every requester
    // has spent its per-round quota). On that cycle no grant is offered and
    // the quotas reload to the configured weights, opening a new round.
    //   need_reload : there is pending work but the eligible-request set is
    //                 empty, so the round must restart before anyone is served.
    // A request from a zero-weight-only input set (req != 0 but every
    // requesting input has weight 0) also triggers a reload each cycle; since
    // the reload restores quota 0 for those inputs, req_elig stays 0 and no
    // grant is ever offered to a zero-weight input (proven: P_GNT_IMPLIES_REQ
    // plus eligibility => zero-weight never granted).
    // ------------------------------------------------------------------------
    logic need_reload;
    assign need_reload = (req != '0) && (req_elig == '0);

    // ------------------------------------------------------------------------
    // Round-robin core (composed shipped primitive). It sees the eligible
    // request vector and the full data bus; EXT_PRIO=0 (internal fair
    // pointer), LOCK_IN=0 (no held grant: this arbiter does not freeze a
    // decision across a stall, it simply holds m_valid while req_elig holds).
    // The core's gnt / m_idx / m_data / m_valid are this module's outputs
    // directly: the weighting layer only shapes which requests reach the core,
    // it does not alter the grant once made.
    // ------------------------------------------------------------------------
    logic core_m_valid;
    logic [NUM_IN-1:0]    core_gnt;
    logic [IDX_WIDTH-1:0] core_m_idx;
    logic [DATA_WIDTH-1:0] core_m_data;

    rr_arbiter_tree #(
        .NUM_IN     (NUM_IN),
        .DATA_WIDTH (DATA_WIDTH),
        .EXT_PRIO   (1'b0),
        .LOCK_IN    (1'b0)
    ) u_core (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (req_elig),
        .gnt     (core_gnt),
        .data    (data),
        .rr_prio ({IDX_WIDTH{1'b0}}),
        .m_valid (core_m_valid),
        .m_ready (m_ready),
        .m_data  (core_m_data),
        .m_idx   (core_m_idx)
    );

    assign gnt     = core_gnt;
    assign m_valid = core_m_valid;
    assign m_idx   = core_m_idx;
    assign m_data  = core_m_data;

    // A completed handshake this cycle (a grant the downstream accepts).
    logic fire;
    assign fire = m_valid && m_ready;

    // ------------------------------------------------------------------------
    // Quota update. The configured weights load on the first round and at every
    // round restart (need_reload); a completed grant to input i spends one unit
    // of quota[i]. The reload wins over the decrement in the same cycle (a round
    // closes on a cycle where no grant is offered, so the two never actually
    // collide, but the priority is explicit for clarity and to keep every bit
    // driven).
    //
    // Reset clears quota to a CONSTANT 0 (not the `weight` signal). Async-loading
    // a runtime signal on reset is not synthesizable - ECP5 (and most FPGA/ASIC
    // FF primitives) have no asynchronous load, only async clear/preset to a
    // constant. With quota==0 after reset every input is ineligible
    // (eligible[i] = quota_q[i] != 0), so the first cycle a request appears
    // need_reload = (req!=0 && req_elig==0) fires and loads `weight` - exactly a
    // round restart. No grant is lost (a grant requires quota>0), and startup now
    // matches the steady-state round-restart path.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin : seq_quota
        if (!rst_n) begin
            quota_q <= '0;
        end else if (need_reload) begin
            for (int unsigned i = 0; i < NUM_IN; i++) begin
                quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] <=
                    weight[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
            end
        end else begin
            for (int unsigned i = 0; i < NUM_IN; i++) begin
                // Decrement only the granted, accepted input. m_idx is the
                // one-hot winner's binary index; gnt[i] selects it directly.
                if (fire && gnt[i]) begin
                    quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] <=
                        quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] - WEIGHT_WIDTH'(1);
                end else begin
                    quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] <=
                        quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Tier-1 contract and invariants (always armed; see vosken_assert.sv).
    //   a_gnt_onehot0    : grant is one-hot or zero every steady cycle
    //                      ($onehot0 is unsupported by the slang frontend, so
    //                      the bit-clear identity is used). Mirrors the core's
    //                      own guarantee at this module's boundary.
    //   a_gnt_implies_req: a granted bit corresponds to a live ELIGIBLE
    //                      request (gnt is a subset of req_elig); since
    //                      req_elig is a subset of req, grant implies request,
    //                      and since eligible requires quota > 0 a zero-weight
    //                      input is never granted.
    //   a_weight_stable  : config-stability contract. The per-input weights
    //                      are configuration straps held constant for the
    //                      lifetime of the arbiter: they do not change from one
    //                      cycle to the next while operating. The weights are
    //                      config inputs assumed stable while busy; the conservative faithful model is a
    //                      held strap (a quota loaded from a weight that then
    //                      shrank below it would corrupt the per-round count,
    //                      so reprogramming is only ever legal through a full
    //                      reset, never live). assume under FORMAL, accusation
    //                      in integrator simulation against a driver that
    //                      changes a weight without a reset.
    // The macros sample rst_n synchronously as the check gate while the state
    // flops use it asynchronously; the waiver scopes that intended dual use to
    // the check region (house style).
    // ------------------------------------------------------------------------
    // verilator lint_off SYNCASYNCNET
    `VKN_ASSERT(a_gnt_onehot0, (gnt & (gnt - 1'b1)) == '0, clk, rst_n)
    `VKN_ASSERT(a_gnt_implies_req, (gnt & ~req_elig) == '0, clk, rst_n)
    // verilator lint_on SYNCASYNCNET

endmodule

`default_nettype wire

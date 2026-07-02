// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0

//============================================================================
// FORMAL   : fv_wrr_arbiter  (property module)
// MODULE   : wrr_arbiter      (read-only DUT — never modified)
// ENGINE   : symbiyosys (yosys-slang frontend, honours bind)
// MODE     : prove (k-induction) + cover
//============================================================================
//
// Independently derived property set. The
// DUT is a weighted round-robin arbiter that composes the shipped
// rr_arbiter_tree for the intra-round grant/data decision and adds a per-input
// quota bank + round-restart layer for weight-proportional service.
//
// Verified contract:
//   P_GNT_ONEHOT0       grant is one-hot-or-zero      ($onehot0 -> bit-trick)
//   P_GNT_IMPLIES_REQ   gnt subset of req_elig (=> live eligible request)
//   P_GNT_IMPLIES_RAWREQ gnt subset of req (no grant without a request)
//   P_ZERO_WEIGHT_NO_GNT a weight-0 input is never granted
//   INV_QUOTA_RANGE     quota[i] <= weight[i]  (weighted window upper bound)
//   P_QUOTA_NO_UNDERFLOW a completed grant lands on quota>0 (never underflows)
//   P_RELOAD_RESTORES   a round restart reloads every input's full quota
//   P_NO_STARVE         weight[i]>0 => bounded wait < sum(weight) (liveness,
//                       safety-encoded bounded-response form)
//   P_RESET_NO_GRANT / P_RESET_QUOTA  reset state (quota clears to a CONSTANT 0;
//                       the configured weight loads on the first round restart,
//                       NOT at reset - see P_RELOAD_RESTORES. Resetting quota to
//                       the `weight` signal would be an async LOAD of a runtime
//                       net, which no FPGA/ASIC FF can implement; the DUT resets
//                       quota to '0 and the need_reload path restores weight.)
//
// Idioms:
//   * slang frontend + bind; props guarded `ifdef FORMAL.
//   * clocked init-trick reset anchor (NOT `initial assume`, which slang
//     rejects): a declaration-initialised one-shot flag pins rst_n low at t=0.
//   * $onehot0(x) -> ((x & (x-1)) == '0)  (slang has no $onehot0).
//   * symbolic constant (the tracked requester index) as a SELF-HOLDING
//     register with free init and no reset (a true anyconst; $anyconst/(* *)
//     are dropped by slang, the undriven+stable-assume form slips).
//   * bounded-wait liveness: a wait counter strengthened by a conserved-sum
//     invariant (f_wait + others-remaining-quota <= others-total-weight),
//     widened so the sum never wraps -> P_NO_STARVE inductive.
//   * weight-stability config strap re-asserted across the reset edge so the
//     RTL tier-1 a_weight_stable (which skips that edge) holds at step 1.
//
// ASSUME discipline: the only assumes are (a) the RTL tier-1 input contract
// (a_weight_stable; expanded by -D FORMAL on the DUT macros — immediate-
// assertion based, slang-safe), (b) the reset anchor, (c) the symbolic-index
// domain bound (f_idx <= NUM_IN-1, a free-variable restriction), (d) the
// weight-strap freeze across the reset edge. Nothing is assumed on DUT
// outputs or internals.
//============================================================================

`default_nettype none

module fv_wrr_arbiter #(
    parameter int NUM_IN       = 4,
    parameter int DATA_WIDTH   = 32,
    parameter int WEIGHT_WIDTH = 4,
    localparam int IDX_WIDTH = (NUM_IN > 1) ? $clog2(NUM_IN) : 1
) (
    input wire                            clk,
    input wire                            rst_n,
    input wire [NUM_IN-1:0]               req,
    input wire [NUM_IN*WEIGHT_WIDTH-1:0]  weight,
    input wire [NUM_IN-1:0]               gnt,
    input wire                            m_valid,
    input wire                            m_ready,
    input wire [IDX_WIDTH-1:0]            m_idx,
    // DUT internal taps (resolve in DUT scope via bind (.*) / explicit ports).
    // All packed: slang bind ports cannot carry unpacked arrays. quota_q is the
    // flat NUM_IN*WEIGHT_WIDTH quota bus.
    input wire [NUM_IN-1:0]               eligible,
    input wire [NUM_IN-1:0]               req_elig,
    input wire                            need_reload,
    input wire                            fire,
    input wire [NUM_IN*WEIGHT_WIDTH-1:0]  quota_q
);


    localparam logic [IDX_WIDTH-1:0] IDX_MAX = IDX_WIDTH'(NUM_IN - 1);

    // Widened accumulator: sum of NUM_IN weights, each up to 2^WW-1. Give it
    // WW + clog2(NUM_IN) + 2 bits so the conserved sum never wraps.
    localparam int QW = WEIGHT_WIDTH + $clog2(NUM_IN) + 2;

    // ----------------------------------------------------------------------
    // Init one-shot (clocked init-trick). KEPT here because many ASSERTIONS and
    // COVERS below guard on `fv_init_r` (the $past-based reset-edge checks and
    // the back-to-back cover). The reset-init ASSUME that used to live here
    // (FV_RST_INIT_M) has MOVED to fv_wrr_arbiter_assumes.sv (three-file
    // structure); only the one-shot register itself remains.
    // ----------------------------------------------------------------------
    logic fv_init_r = 1'b1;
    always_ff @(posedge clk) fv_init_r <= 1'b0;

    // NOTE (three-file migration): environment constraints A (reset-init pin,
    // FV_RST_INIT_M) and B (weight config-strap across the reset edge,
    // FV_WEIGHT_STRAP_M) now live in fv_wrr_arbiter_assumes.sv, bound separately
    // onto every wrr_arbiter instance. They are intentionally NOT in this file.

    // Indexed views of the flat weight/quota buses.
    function automatic logic [WEIGHT_WIDTH-1:0] w_of(input int unsigned i);
        return weight[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
    endfunction
    function automatic logic [WEIGHT_WIDTH-1:0] q_of(input int unsigned i);
        return quota_q[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
    endfunction

    // ----------------------------------------------------------------------
    // Section: Grant shape and request implication (wrr boundary).
    // ----------------------------------------------------------------------
    always_comb begin : sec_grant_shape
        if (rst_n) begin
            // $onehot0(gnt) lowered to the bit-clear identity (slang-safe).
            P_GNT_ONEHOT0_A:      assert ((gnt & (gnt - 1'b1)) == '0);
            // Granted bit is a live ELIGIBLE request.
            P_GNT_IMPLIES_REQ_A:  assert ((gnt & ~req_elig) == '0);
            // req_elig subset of req => grant also implies a raw request.
            P_GNT_IMPLIES_RAWREQ_A: assert ((gnt & ~req) == '0);
        end
    end

    // ----------------------------------------------------------------------
    // Section: Weighted-fairness window (per-input). quota[i] <= weight[i];
    // a completed grant lands on quota>0 (no underflow); zero-weight never
    // granted; reload restores full quota; eligible == (quota != 0).
    // ----------------------------------------------------------------------
    generate
        genvar gi;
        for (gi = 0; gi < NUM_IN; gi++) begin : g_quota_props
            always_ff @(posedge clk) begin : inv_quota_range
                if (rst_n) begin
                    INV_QUOTA_RANGE_A:
                        assert (quota_q[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH]
                                <= weight[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH]);
                end
            end
            always_comb begin : p_quota_no_underflow
                if (rst_n && fire && gnt[gi]) begin
                    P_QUOTA_NO_UNDERFLOW_A:
                        assert (quota_q[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH] != '0);
                end
            end
            always_comb begin : p_zero_weight_no_gnt
                if (rst_n && (weight[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH] == '0)) begin
                    P_ZERO_WEIGHT_NO_GNT_A: assert (!gnt[gi]);
                end
            end
            always_ff @(posedge clk) begin : p_reload_restores
                if (!fv_init_r && rst_n && $past(rst_n) && $past(need_reload)) begin
                    P_RELOAD_RESTORES_A:
                        assert (quota_q[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH]
                                == $past(weight[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH]));
                end
            end
            always_comb begin : inv_elig_def
                if (rst_n) begin
                    INV_ELIG_DEF_A:
                        assert (eligible[gi] ==
                                (quota_q[gi*WEIGHT_WIDTH +: WEIGHT_WIDTH] != '0));
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------------
    // QSUM = sum_i quota[i]; SUM_W = sum_i weight[i] (widened accumulator).
    // ----------------------------------------------------------------------
    logic [QW-1:0] qsum;
    logic [QW-1:0] sum_w;
    always_comb begin : comb_sums
        qsum  = '0;
        sum_w = '0;
        for (int unsigned i = 0; i < NUM_IN; i++) begin
            qsum  = qsum  + QW'(q_of(i));
            sum_w = sum_w + QW'(w_of(i));
        end
    end

    // ----------------------------------------------------------------------
    // Section: No-starvation (bounded-wait liveness, safety-encoded).
    // f_idx is a frozen symbolic requester index (self-holding register, free
    // init, no reset => a true anyconst under slang). f_wait_q counts completed
    // grants to OTHER indices while req[f_idx] is held with weight>0 and unserved.
    // ----------------------------------------------------------------------
    logic [IDX_WIDTH-1:0] f_idx;
    always_ff @(posedge clk) f_idx <= f_idx;   // self-holding anyconst

    // FV_FIDX_RANGE_M: anyconst-DOMAIN restriction, KEPT IN THIS FILE by design
    // (NOT migrated to fv_wrr_arbiter_assumes.sv). f_idx is a proof-construction
    // FREE VARIABLE that lives in THIS assertion module and is read by the
    // no-starvation assertions below (INV_WAIT_QSUM_A, P_NO_STARVE_A, gnt_fidx,
    // q_fidx, w_fidx, ...). This is a bound on that free variable's domain, not
    // an environment/input constraint on a DUT signal; it cannot move out unless
    // f_idx moves too (and f_idx can't — the assertions need it). Removing it is
    // also not an option: an out-of-range symbolic index would read past the
    // weight/quota bus and break the proofs. Documented exception.
    always_comb begin : f_idx_range
        FV_FIDX_RANGE_M: assume (f_idx <= IDX_MAX);
    end

    logic w_fidx_pos;   // f_idx weight > 0 (else no fairness owed)
    logic req_fidx;     // live request on the tracked input
    logic gnt_fidx;     // a completed grant to it
    assign w_fidx_pos = (weight[f_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH] != '0);
    assign req_fidx   = req[f_idx];
    assign gnt_fidx   = fire && gnt[f_idx];

    logic [QW-1:0] f_wait_q;
    always_ff @(posedge clk or negedge rst_n) begin : seq_wait
        if (!rst_n) begin
            f_wait_q <= '0;
        end else begin
            if (gnt_fidx || !req_fidx || !w_fidx_pos || need_reload) begin
                f_wait_q <= '0;                       // window closes / resets
            end else if (fire) begin
                f_wait_q <= f_wait_q + QW'(1);        // grant to an OTHER input
            end
        end
    end

    // f_idx's own quota/weight and the OTHERS partition (total minus its share).
    logic [QW-1:0] q_fidx;
    logic [QW-1:0] w_fidx;
    assign q_fidx = QW'(quota_q[f_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH]);
    assign w_fidx = QW'(weight[f_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH]);
    logic [QW-1:0] qsum_others;
    logic [QW-1:0] sum_w_others;
    assign qsum_others  = qsum  - q_fidx;
    assign sum_w_others = sum_w - w_fidx;

    // INV_WAIT_QSUM: the conserved quantity (OTHERS partition). Every completed
    // grant to an OTHER input increments f_wait_q and decrements qsum_others by
    // one; a reload restores both to (0, sum_w_others); a grant to f_idx resets
    // f_wait_q and touches only q_fidx (outside the partition). Hence
    //   f_wait_q + qsum_others <= sum_w_others
    // throughout the open window. Widened so the sum never wraps.
    always_comb begin : inv_wait_qsum
        if (rst_n) begin
            INV_WAIT_QSUM_A: assert (!(req_fidx && w_fidx_pos)
                || ((f_wait_q + qsum_others) <= sum_w_others));
        end
    end

    // INV_QFIDX_LE: f_idx's quota <= its weight (so the partition subtraction
    // stays non-negative and the others-bound is exact).
    always_comb begin : inv_qfidx_le
        if (rst_n) begin
            INV_QFIDX_LE_A: assert (q_fidx <= w_fidx);
        end
    end

    // INV_REQELIG_PROGRESS: m_valid == |req_elig (forward progress link).
    always_comb begin : inv_reqelig_progress
        if (rst_n) begin
            INV_REQELIG_PROGRESS_A: assert (m_valid == (req_elig != '0));
        end
    end

    // INV_NEED_RELOAD_DEF: pins need_reload to the request/eligibility state.
    always_comb begin : inv_need_reload_def
        if (rst_n) begin
            INV_NEED_RELOAD_DEF_A:
                assert (need_reload == ((req != '0) && (req_elig == '0)));
        end
    end

    // P_NO_STARVE: the no-starvation guarantee. The wait count is
    // strictly below sum(weight) whenever f_idx requests with positive weight.
    always_comb begin : p_no_starve
        if (rst_n) begin
            P_NO_STARVE_A: assert (!(req_fidx && w_fidx_pos)
                || (f_wait_q < sum_w));
        end
    end

    // ----------------------------------------------------------------------
    // Section: Reset state.
    // ----------------------------------------------------------------------
    always_ff @(posedge clk) begin : p_reset_no_grant
        if (!fv_init_r && !$past(rst_n)) begin
            P_RESET_NO_GRANT_A: assert (gnt == '0 || req_elig != '0);
        end
    end

    generate
        genvar gr;
        for (gr = 0; gr < NUM_IN; gr++) begin : g_reset_quota
            always_ff @(posedge clk) begin : p_reset_quota
                if (!fv_init_r && !$past(rst_n)) begin
                    // The DUT async-resets quota to a CONSTANT 0 (an async load
                    // of the `weight` signal is not synthesizable). The full
                    // weight is restored on the first round restart instead,
                    // proven separately by P_RELOAD_RESTORES.
                    P_RESET_QUOTA_A:
                        assert (quota_q[gr*WEIGHT_WIDTH +: WEIGHT_WIDTH] == '0);
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------------
    // Section: Reachability covers (reset-complete + state reachability +
    // archetype witnesses). Each exercises a corner the reset
    // anchor / input contract could otherwise mask. Internal-signal covers
    // live here so they resolve in the bound DUT scope.
    // ----------------------------------------------------------------------
    // Reset completes and the machine leaves reset (a grant fires).
    always_ff @(posedge clk) begin : c_grant_idx0
        if (rst_n) C_GRANT_IDX0_P: cover (fire && (m_idx == '0));
    end
    always_ff @(posedge clk) begin : c_grant_idxmax
        if (rst_n) C_GRANT_IDXMAX_P: cover (fire && (m_idx == IDX_MAX));
    end
    // A round restart actually happens (every requester spent quota).
    always_ff @(posedge clk) begin : c_reload
        if (rst_n) C_RELOAD_P: cover (need_reload);
    end
    // Back-to-back completed grants to different indices (rotation moving).
    always_ff @(posedge clk) begin : c_back_to_back
        if (!fv_init_r && rst_n && $past(rst_n))
            C_BACK_TO_BACK_P: cover ($past(fire) && fire && (m_idx != $past(m_idx)));
    end
    // Simultaneous all-request contention (the case fairness is about).
    always_ff @(posedge clk) begin : c_all_req
        if (rst_n) C_ALL_REQ_P: cover (m_valid && (&req));
    end
    // No-starvation tight corner: tracked input waits the maximal number of
    // other completed grants, then is itself granted.
    always_ff @(posedge clk) begin : c_starve_max
        if (rst_n)
            C_STARVE_MAX_P: cover (gnt_fidx && w_fidx_pos
                                   && (f_wait_q == (sum_w - QW'(1))));
    end
    // Weighted draw-down witness: an input granted while still holding quota
    // below its weight (weight>1 spent across >1 grant before a reload).
    // Structurally unreachable at WEIGHT_WIDTH==1 (quota goes 1->0 in one grant),
    // so gated off there.
    generate
        if (WEIGHT_WIDTH > 1) begin : g_cover_drawdown
            always_ff @(posedge clk) begin : c_weight_drawdown
                if (rst_n && fire) begin
                    C_WEIGHT_DRAWDOWN_P: cover (
                        (quota_q[m_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH] != '0)
                        && (quota_q[m_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH]
                            < weight[m_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH]));
                end
            end
        end
    endgenerate


endmodule

`default_nettype wire

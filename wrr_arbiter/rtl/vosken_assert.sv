// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0

//============================================================================
// HEADER  : vosken_assert.sv   (generic; nothing cell-specific lives here)
// LIBRARY : primitive_lib   VERSION : 3.0.0
//============================================================================
//
// SWITCH ARCHITECTURE
// -------------------
//   VKN_EN      MASTER enable. UNDEFINED => this header is fully INERT: every
//               macro expands to nothing, so the primitive compiles STANDALONE
//               in any context (synthesis, integration, unknown tool).
//               BRIDGE: FORMAL implies VKN_EN, so existing flows that pass only
//               `-D FORMAL` keep working; pure synthesis (no defines) stays inert.
//   FORMAL      formal-proof mode: VKN_ASSUME->assume, covers + reset-init pin
//               active, BARE assert/assume/cover (no `else` action block, which
//               native `read_verilog` rejects; read_slang accepts bare too).
//   (VKN_EN, no FORMAL)  => SIMULATION: VKN_ASSUME->assert(+$error message),
//               so a misdriving integrator is accused in its own sim log.
//
// FRONTEND CONSTRUCTS (orthogonal axis)
//   default     read_slang-safe: edge sugar uses $past/$countones lowerings and
//               X-checks ($isunknown) are SUPPRESSED. This is the safe default
//               because the deployed fleet runs read_slang (2-valued RTLIL
//               bridge that cannot lower the native sampled-value functions).
//   VKN_NATIVE  opt in to native $rose/$fell/$stable/$changed/$onehot/$onehot0
//               and to X-checks. Use on native `read_verilog -formal` (which
//               models inputs as X-capable: pair X-checks with an input
//               `assume(!$isunknown(..))`) and on 4-state simulators.
//
// Define combinations:
//   slang  formal (fleet)    : -D FORMAL                (default constructs)
//   native formal            : -D FORMAL -D VKN_NATIVE
//   simulation               : -D VKN_EN [-D VKN_NATIVE]
//   synthesis / standalone   : (no defines)  -> inert
//
// All checks are IMMEDIATE assertions in clocked/comb processes (no SVA engine).
//============================================================================

`ifndef VOSKEN_ASSERT_SV
`define VOSKEN_ASSERT_SV

// --- Master enable + backward-compat bridge --------------------------------
`ifdef FORMAL
  `ifndef VKN_EN
    `define VKN_EN
  `endif
`endif

// --- Edge / value sugar: PURE EXPRESSIONS. Default = read_slang-safe $past
//     lowerings; VKN_NATIVE => native sampled-value functions. Defined
//     unconditionally (only ever expanded inside an enabled assertion). --------
`ifdef VKN_NATIVE
  `define VKN_ROSE(__x)    $rose(__x)
  `define VKN_FELL(__x)    $fell(__x)
  `define VKN_STABLE(__x)  $stable(__x)
  `define VKN_CHANGED(__x) $changed(__x)
  `define VKN_ONEHOT(__x)  $onehot(__x)
  `define VKN_ONEHOT0(__x) $onehot0(__x)
`else
  `define VKN_ROSE(__x)    ((__x) && !$past(__x))
  `define VKN_FELL(__x)    (!(__x) && $past(__x))
  `define VKN_STABLE(__x)  ((__x) == $past(__x))
  `define VKN_CHANGED(__x) ((__x) != $past(__x))
  `define VKN_ONEHOT(__x)  ($countones(__x) == 1)
  `define VKN_ONEHOT0(__x) ($countones(__x) <= 1)
`endif

`ifdef VKN_EN
//=============================== VERIFICATION ===============================
`ifdef FORMAL
  //--------- FORMAL: bare assert/assume/cover (native + slang safe) ----------
  `define VKN_ASSERT(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if (__rst_n) begin __name: assert (__expr); end end
  `define VKN_ASSERT_PAST(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if ((__rst_n) && $past(__rst_n)) begin __name: assert (__expr); end end
  `define VKN_ASSERT_COMB(__name,__expr) \
    always_comb begin : __name``_blk __name: assert (__expr); end
  `define VKN_ASSUME(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if (__rst_n) begin __name: assume (__expr); end end
  `define VKN_ASSUME_PAST(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if ((__rst_n) && $past(__rst_n)) begin __name: assume (__expr); end end
  `define VKN_ASSUME_COMB(__name,__expr) \
    always_comb begin : __name``_blk __name: assume (__expr); end
  `define VKN_COVER(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if (__rst_n) begin __name: cover (__expr); end end
  `define VKN_ASSUME_RESET_INIT(__name,__clk,__rst_n) \
    logic __name``_r = 1'b0; \
    always_ff @(posedge __clk) __name``_r <= 1'b1; \
    always_ff @(posedge __clk) __name: assume (__name``_r || !(__rst_n));
  `ifdef VKN_NATIVE
    `define VKN_XASSERT(__name,__expr,__clk,__rst_n) \
      always_ff @(posedge __clk) begin : __name``_blk \
        if (__rst_n) begin __name: assert (__expr); end end
  `else
    // read_slang cannot lower $isunknown -> X-checks suppressed.
    `define VKN_XASSERT(__name,__expr,__clk,__rst_n)
  `endif
`else
  //--------- SIMULATION: assert (+$error); assumes accuse the integrator -----
  `define VKN_ASSERT(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if (__rst_n) begin __name: assert (__expr) \
        else $error("[%m] tier-1 assertion %s failed", `"__name`"); end end
  `define VKN_ASSERT_PAST(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if ((__rst_n) && $past(__rst_n)) begin __name: assert (__expr) \
        else $error("[%m] tier-1 assertion %s failed", `"__name`"); end end
  `define VKN_ASSERT_COMB(__name,__expr) \
    always_comb begin : __name``_blk __name: assert (__expr) \
      else $error("[%m] tier-1 assertion %s failed", `"__name`"); end
  `define VKN_ASSUME(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if (__rst_n) begin __name: assert (__expr) \
        else $error("[%m] input contract %s violated by integrator", `"__name`"); end end
  `define VKN_ASSUME_PAST(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if ((__rst_n) && $past(__rst_n)) begin __name: assert (__expr) \
        else $error("[%m] input contract %s violated by integrator", `"__name`"); end end
  `define VKN_ASSUME_COMB(__name,__expr) \
    always_comb begin : __name``_blk __name: assert (__expr) \
      else $error("[%m] input contract %s violated by integrator", `"__name`"); end
  `define VKN_COVER(__name,__expr,__clk,__rst_n)        // formal-only -> inert in sim
  `define VKN_ASSUME_RESET_INIT(__name,__clk,__rst_n)   // formal-only -> inert in sim
  `define VKN_XASSERT(__name,__expr,__clk,__rst_n) \
    always_ff @(posedge __clk) begin : __name``_blk \
      if (__rst_n) begin __name: assert (__expr) \
        else $error("[%m] X-prop check %s failed", `"__name`"); end end
`endif
`else
//=========================== VKN_EN OFF: INERT =============================
// Every macro empty -> primitive compiles standalone in any context.
  `define VKN_ASSERT(__name,__expr,__clk,__rst_n)
  `define VKN_ASSERT_PAST(__name,__expr,__clk,__rst_n)
  `define VKN_ASSERT_COMB(__name,__expr)
  `define VKN_ASSUME(__name,__expr,__clk,__rst_n)
  `define VKN_ASSUME_PAST(__name,__expr,__clk,__rst_n)
  `define VKN_ASSUME_COMB(__name,__expr)
  `define VKN_COVER(__name,__expr,__clk,__rst_n)
  `define VKN_ASSUME_RESET_INIT(__name,__clk,__rst_n)
  `define VKN_XASSERT(__name,__expr,__clk,__rst_n)
`endif

// Convenience: X-freedom of a signal. Wraps VKN_XASSERT, so it inherits the same
// mode gating (native->bare, sim->$error, slang->suppressed, off->empty).
`define VKN_KNOWN(__name,__sig,__clk,__rst_n) \
  `VKN_XASSERT(__name, !$isunknown(__sig), __clk, __rst_n)

`endif // VOSKEN_ASSERT_SV

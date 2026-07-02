// SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
// SPDX-License-Identifier: Apache-2.0

//============================================================================
// FORMAL   : fv_wrr_arbiter bind + parameter-sweep formal top
//============================================================================
//
// The bind attaches fv_wrr_arbiter to EVERY wrr_arbiter instance, so one prove
// task covers all swept parameterisations. Elaborated with the yosys-slang
// frontend (read_slang), which honours bind; the native Verilog frontend
// silently drops bind and MUST NOT be used.
//
// Bind port connections resolve in the TARGET (DUT) scope. Internal taps
// (eligible, req_elig, need_reload, fire, quota_q) are all packed — slang bind
// ports cannot carry unpacked arrays, which is why quota_q is a flat
// NUM_IN*WEIGHT_WIDTH bus in the RTL.
//
// Sweep (degenerate / non-pow2 / pow2 + degenerate payload):
//   NUM_IN=2, WW=2, DW=4   degenerate NUM_IN (1-bit index), weights 0..3
//   NUM_IN=3, WW=1, DW=2   non-power-of-two NUM_IN + WEIGHT_WIDTH=1 boundary
//                          (weights 0/1: weighted RR collapses to RR-with-skip)
//   NUM_IN=4, WW=2, DW=1   power-of-two NUM_IN + degenerate payload width
//
// All instances share clk/rst_n (single-clock cell). Per-instance req / weight
// / data / m_ready are free formal-top PORTS (bound modules cannot create free
// nets under slang).
//============================================================================

`default_nettype none

`ifdef FORMAL
bind wrr_arbiter fv_wrr_arbiter #(
    .NUM_IN       (NUM_IN),
    .DATA_WIDTH   (DATA_WIDTH),
    .WEIGHT_WIDTH (WEIGHT_WIDTH)
) u_fv_wrr_arbiter (
    .clk         (clk),
    .rst_n       (rst_n),
    .req         (req),
    .weight      (weight),
    .gnt         (gnt),
    .m_valid     (m_valid),
    .m_ready     (m_ready),
    .m_idx       (m_idx),
    .eligible    (eligible),
    .req_elig    (req_elig),
    .need_reload (need_reload),
    .fire        (fire),
    .quota_q     (quota_q)
);
`endif

module fv_wrr_arbiter_top (
    input wire        clk,
    input wire        rst_n,
    // free inputs per instance
    input wire [1:0]  req_n2,
    input wire [2:0]  req_n3,
    input wire [3:0]  req_n4,
    input wire [3:0]  weight_n2,   // 2 x WW=2
    input wire [2:0]  weight_n3,   // 3 x WW=1
    input wire [7:0]  weight_n4,   // 4 x WW=2
    input wire [7:0]  data_n2,     // 2 x DW=4
    input wire [5:0]  data_n3,     // 3 x DW=2
    input wire [3:0]  data_n4,     // 4 x DW=1
    input wire [2:0]  m_ready_v
);

    logic [1:0] gnt_n2;
    logic [2:0] gnt_n3;
    logic [3:0] gnt_n4;
    logic       mv_n2, mv_n3, mv_n4;
    logic [3:0] md_n2;
    logic [1:0] md_n3;
    logic [0:0] md_n4;
    logic [0:0] mi_n2;   // $clog2(2) = 1
    logic [1:0] mi_n3;   // $clog2(3) = 2
    logic [1:0] mi_n4;   // $clog2(4) = 2

    wrr_arbiter #(
        .NUM_IN       (2),
        .DATA_WIDTH   (4),
        .WEIGHT_WIDTH (2)
    ) u_n2 (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (req_n2),
        .weight  (weight_n2),
        .gnt     (gnt_n2),
        .data    (data_n2),
        .m_valid (mv_n2),
        .m_ready (m_ready_v[0]),
        .m_data  (md_n2),
        .m_idx   (mi_n2)
    );

    wrr_arbiter #(
        .NUM_IN       (3),
        .DATA_WIDTH   (2),
        .WEIGHT_WIDTH (1)
    ) u_n3 (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (req_n3),
        .weight  (weight_n3),
        .gnt     (gnt_n3),
        .data    (data_n3),
        .m_valid (mv_n3),
        .m_ready (m_ready_v[1]),
        .m_data  (md_n3),
        .m_idx   (mi_n3)
    );

    wrr_arbiter #(
        .NUM_IN       (4),
        .DATA_WIDTH   (1),
        .WEIGHT_WIDTH (2)
    ) u_n4 (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (req_n4),
        .weight  (weight_n4),
        .gnt     (gnt_n4),
        .data    (data_n4),
        .m_valid (mv_n4),
        .m_ready (m_ready_v[2]),
        .m_data  (md_n4),
        .m_idx   (mi_n4)
    );

endmodule

`default_nettype wire

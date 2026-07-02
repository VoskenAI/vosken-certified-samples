<!--
SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
SPDX-License-Identifier: Apache-2.0
-->

# vosken-certified-samples

This repo contains two production RTL primitives, the complete formal proof
bundle for each, and a certificate (`VERDICT.txt`) that pins every proof
obligation, the exact RTL bits it was proven against, and the exact toolchain
that proved it. One command re-runs the proofs on your machine and diffs the
result, assertion by assertion, against the certificate. You do not have to
trust us, our marketing, or our CI logs: the evidence regenerates locally or
it does not.

These are working samples of how VoskenAI ships IP: the deliverable is not
"RTL plus a report" but "RTL plus a machine-checkable argument that the RTL
meets its contract". Everything here is Apache-2.0, self-contained, and free
of any dependency on our internal tooling. The proofs run on the open-source
SymbiYosys stack, pinned to a dated oss-cad-suite release so the run is
bit-for-bit comparable to the certified one.

## The primitives

| Primitive | Contract proven (mode `prove`, unbounded, plus reachability covers) |
|---|---|
| `ring_buffer` | No overflow, no read past write, occupancy equals write minus read pointer, flag correctness, data integrity through wrap, reset state. Proven at DATA_WIDTH=32, DEPTH=32 by k-induction (abc pdr). |
| `wrr_arbiter` | Grant is one-hot-or-zero, no grant without an eligible request, zero-weight inputs never granted, per-round quota never exceeds the configured weight and never underflows, reload restores full quota, bounded-wait no-starvation. Proven by k-induction across three parameter configurations in one proof (NUM_IN=2/3/4, including a non-power-of-two count). |

Each primitive directory holds `rtl/` (the DUT, never modified by the proof),
`formal/` (the SymbiYosys `.sby` config, the property module, the environment
assumptions, the cover points, a Makefile), and `VERDICT.txt` (the
certificate).

## Quickstart

```
git clone <this repo> && cd vosken-certified-samples
./reproduce.sh
```

The default path uses Docker: it builds a pinned image (debian:bookworm-slim
plus the oss-cad-suite dated release recorded in `ENVIRONMENT.txt`, several
hundred MB downloaded once) and re-runs every prove and cover task inside it.
Exit code zero means every assertion, every cover point, and every RTL hash
matched the certificate.

No Docker? `./reproduce.sh --native` uses `sby` and `yosys` from your PATH.
If your tool versions exactly match the pins in `ENVIRONMENT.txt` the run
counts as a certified reproduction; otherwise it proceeds under a loud
"uncertified environment" banner, because a proof that passes under an
unpinned solver stack is evidence, but not the certified evidence.

## The tamper demo

A proof harness you cannot make fail is not measuring anything. So:

```
./tamper_demo.sh
```

This applies a one-line functional bug to `ring_buffer` (inverts the
write-ready condition, so the buffer reports ready exactly when it is full),
re-runs the prove task, shows the proof go red with the failing assertions
named, and restores the RTL to its certified state. If that script ever
prints a passing proof, discard this repo and tell us.

## Evaluator's checklist

What to demand from any "formally verified" claim, and where this repo
answers it:

- **Non-vacuity.** A property that can never fire proves nothing. Every
  bundle ships a `cover` task, and the certificate requires every cover point
  reached under the same assumption set the proofs use. Reachability of the
  interesting states (full, wrap, contention, the maximal-wait corner) is
  part of the verdict, not an afterthought.
- **Assumption discharge.** Every `assume` is visible and reviewable in one
  place (`formal/fv_*_assumes.sv` plus the DUT's inline input contract, which
  the `.sby` file expands). Assumptions constrain only DUT inputs and proof
  free variables, never DUT outputs or internals, and the same input contract
  becomes a runtime assertion against the integrator in simulation.
- **Hash binding.** `VERDICT.txt` records the md5 of every RTL file the proof
  read. `reproduce.sh` refuses to call a run reproduced if the bits changed.
  A verdict without hash binding is a claim about some other file.
- **Pinned environment.** `ENVIRONMENT.txt` pins the solver stack to a dated
  oss-cad-suite release with exact tool versions, and the Dockerfile rebuilds
  it. "Works with a recent yosys" is not a reproducible statement.
- **Unbounded proof.** Both primitives close by induction (`mode prove`), not
  by bounded model checking alone. A depth-k BMC result is a statement about
  the first k cycles; the certificate says which kind you are getting.

## What this is not

These two primitives are free samples at the bottom rung of a trust ladder.
The full pipeline, from plain-English specification to verified IP with the
same reproducible evidence discipline, is showcased at
[github.com/VoskenAI/voskenai-vf2026](https://github.com/VoskenAI/voskenai-vf2026).

## License

Apache-2.0 (see `LICENSE` and `NOTICE`). Copyright 2026 VoskenAI Ltd.

---

The question to ask any IP vendor: *Can I re-run your proofs in my CI?*

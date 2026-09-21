# Vendored lowRISC Ibex

Upstream: https://github.com/lowRISC/ibex
Commit:   e9f55342edbd27e9e17a0e41b1c95a81abb5eac8 (master, 2026-09-17)
License:  Apache-2.0 (see `LICENSE`, copied from upstream)

This is a **file subset**, not a full checkout. It contains exactly the files
Verilator consumes when elaborating `ibex_top` with the AgriASIC parameter
set (see `agriasic_rv32i_control_shell.sv`): RV32IM + Zca, `RV32MFast`,
`WritebackStage=1`, `BranchTargetALU=1`, no icache/PMP/lockstep/CHERIoT/
security features. Files for disabled features are still present because
their modules are referenced from generate blocks and must elaborate.

Layout (upstream path -> here):

| Upstream                                   | Here            |
|--------------------------------------------|-----------------|
| `rtl/*.sv`                                 | `rtl/`          |
| `vendor/lowrisc_ip/ip/prim/rtl/*`          | `prim/`         |
| `vendor/lowrisc_ip/ip/prim_generic/rtl/*`  | `prim_generic/` |
| `vendor/lowrisc_ip/dv/sv/dv_utils/*.svh`   | `dv_utils/`     |
| `lint/verilator_waiver.vlt`                | `lint/`         |

`ibex.f` is the flat compile list (relative to this directory) in the order
that lints cleanly. Tools need `+incdir+prim +incdir+dv_utils` and, for
synthesis, `+define+SYNTHESIS` (disables `prim_assert`). The shell selects the
latch register file only under `AGRIASIC_LATCH_REGFILE` (ASIC flow); Verilator
cannot simulate it.

`prim_generic/` holds the technology-independent implementations of the
lowRISC primitives. For the ASIC flow, `prim_clock_gating.sv` is the one
that should be swapped for the TSMC 180 nm integrated clock-gating cell when
`core_sleep_o` is used to gate the core clock (not done in Phase 1).

Local patches (re-apply when re-vendoring):

- `rtl/ibex_top.sv`, `gen_noscramble` branch: `logic unused_scramble_inputs = <expr>;`
  rewritten as a declaration plus `assign`. yosys-slang (the `read_slang`
  frontend used by `power/run_synthesis.py`) rejects variable initializers
  that read nets. Semantically identical; the signal is an unused-lint sink.

Otherwise upstream files are unmodified. Re-vendoring is a deliberate step:
re-run the lint harness against the new commit, regenerate `ibex.f`, re-apply
the patches above, and update this file.

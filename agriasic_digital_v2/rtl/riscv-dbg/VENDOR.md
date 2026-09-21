# Vendored RISC-V Debug Module (pulp-platform/riscv-dbg) and dependencies

| Component | Upstream | Commit / tag | License |
|---|---|---|---|
| riscv-dbg | https://github.com/pulp-platform/riscv-dbg | `643607e19df3435cfd77cc56143e2637f5900a6e` (master, 2026-09-15) | Solderpad 0.51 (`LICENSE.riscv-dbg`; debug ROM derives from SiFive, see upstream `LICENSE.SiFive`) |
| common_cells | https://github.com/pulp-platform/common_cells | `v1.37.0` (`c27bce3`) | Solderpad 0.51 (`LICENSE.common_cells`) |
| tech_cells_generic | https://github.com/pulp-platform/tech_cells_generic | `55cb54513e2d426be5992d311cb9d5dbcad10c78` (2026-08-20) | Solderpad 0.51 (`LICENSE.tech_cells_generic`) |

This is a **file subset**: exactly the files Verilator consumes when
elaborating `dm_top` (NrHarts=1, BusWidth=32, DmBaseAddress=0x1A11_0000) and
`dmi_jtag` (5-wire JTAG, IrLength=5).

Layout (upstream path -> here):

| Upstream | Here |
|---|---|
| `riscv-dbg/src/*.sv` | `src/` |
| `riscv-dbg/debug_rom/*.sv` | `debug_rom/` |
| `common_cells/src/*.sv` | `common_cells/` |
| `common_cells/include/common_cells/registers.svh` | `common_cells/include/common_cells/` |
| `tech_cells_generic/src/rtl/tc_clk.sv` | `tech_cells_generic/` |

`riscv_dbg.f` is the flat compile list (relative to this directory) in the
order that lints cleanly. Tools need `+incdir+common_cells/include`;
`lint/agriasic_waiver.vlt` silences upstream width/unused warnings for
Verilator without touching our own RTL's strictness.

Local patches (re-apply when re-vendoring):

- `src/dm_mem.sv`, block `p_regs`: two consecutive `if (!rst_ni) ... else ...`
  pairs merged into one. Identical behaviour; yosys-slang (the `read_slang`
  frontend in `power/run_synthesis.py`) accepts only a single if/else per
  asynchronous-reset block.

Otherwise upstream files are unmodified.

Debug ROM offsets from `dm_pkg.sv` (must match the Ibex `Dm*Addr` parameters
in `agriasic_rv32i_control_shell.sv`):

| | Offset from DmBaseAddress |
|---|---|
| `HaltAddress` (entry) | `0x800` |
| `ResumeAddress` | `0x808` |
| `ExceptionAddress` | `0x810` |

ASIC note: `tech_cells_generic/tc_clk.sv` provides the behavioural
`tc_clk_inverter` / `tc_clk_mux2` used by `dmi_jtag_tap` to launch TDO on the
falling edge of TCK. For tapeout these should be mapped to real clock-tree
cells (inverter and glitch-free clock mux) from the TSMC 180 nm library, the
same way `prim_clock_gating` is for Ibex.

# AgriASIC Digital Subsystem

Digital control for the single-die impedance sensing node. See the
[repository README](../README.md) for architecture and reading order; this file
covers the directory itself.

## Scope

- Measurement sequencing FSM — the real-time timing engine
- Excitation digital control (divider, polarity, settle timer)
- SAR conversion sequencing and sample capture
- SPI slave + register map for host control and debug
- RV32IM control core with program ROM, scratch RAM, and MMIO bridge
- Control firmware and a verification suite spanning all of the above

## Structure

```text
rtl/
  agriasic_digital_rv32i_top.sv        RV32I chip top
  agriasic_rv32i_control_shell.sv      core + ROM + MMIO bridge
  agriasic_digital_spi_top.sv          SPI host interface + register file
  agriasic_digital_top.sv              measurement engine integration
  agriasic_digital_programming_top.sv  compact programming wrapper
  ctrl/
    measurement_fsm.sv                 settle / sample / accumulate sequencer
    excitation_ctrl.sv                 polarity and settle qualification
    sar_controller.sv                  conversion trigger and capture
    spi_slave.sv                       SPI mode-0 byte serializer with CDC
    regfile.sv                         register file for the SPI map
  ibex/                                vendored lowRISC Ibex RV32IMC core (see VENDOR.md)
    ibex.f                             flat compile list, lint-proven order
    rtl/, prim/, prim_generic/         core, lowRISC primitives, generic cells
  riscv-dbg/                           vendored pulp riscv-dbg debug module + JTAG DTM (see VENDOR.md)
    riscv_dbg.f                        flat compile list
    src/, debug_rom/, common_cells/    dm_top, dmi_jtag, their pulp dependencies
  rv32i/
    agriasic_rv32i_bus.sv              interconnect: core instr/data + debug SBA -> IMEM / RAM+MMIO / DM
    agriasic_imem.sv                   program memory (loadable), synchronous-SRAM contract
    agriasic_dmem.sv                   scratch RAM, synchronous-SRAM contract
    agriasic_rv32i_mmio.sv             RAM + peripheral registers behind the bus (Ibex/OBI)
    agriasic_rv32i_mmio.sv.penn        previous bridge for the Penn core
    agriasic_rv32i_core.sv             RETIRED: Penn CIS 5710 5-stage RV32IM datapath
    agriasic_rv32i_cla.sv              RETIRED: carry-lookahead adder (Penn core)
    agriasic_rv32i_divider.sv          RETIRED: pipelined divider (Penn core)
fw/                                    firmware: fw.c, start.S, link.ld, build.sh, openocd_agriasic.cfg
tb/
  smoke/                               measurement and SPI smoke tests
  tb_agriasic_rv32i_e2e.sv             end-to-end: firmware drives the FSM
  tb_agriasic_jtag.sv                  JTAG master -> DTM -> DM: halt/regs/SBA/resume/ndmreset
  rv32i_regression/                    lint, smoke, e2e and ISA regression scripts
docs/                                  MAS, interface contract, plans, diagrams
```

## Processor provenance

The control core is **lowRISC Ibex** (`rtl/ibex/`, vendored at the commit
recorded in `rtl/ibex/VENDOR.md`), configured RV32IMC + Zicsr with the
3-stage writeback pipeline, `RV32MFast` (single-cycle multiply, iterative
divide), no icache/PMP/lockstep, and the RISC-V Debug Module address window
reserved at `0x1A11_0000` for a later `riscv-dbg` integration.

It replaced the CIS 5710 5-stage pipelined RV32IM datapath (kept in
`rtl/rv32i/agriasic_rv32i_core.sv` and the `.penn` shell/bridge snapshots for
reference, not built). The reasons, in order:

- **Debug.** Ibex implements Debug Spec 0.13 (`debug_req_i`, `DmHaltAddr`,
  `dcsr`/`dpc`, single-step); the Penn core had no CSRs, traps or debug hooks,
  so a JTAG debug module would have meant building the M-mode privileged
  subset from scratch on a custom pipeline.
- **Faults are visible.** An out-of-map load/store or a fetch past the ROM now
  returns a bus error and traps (`CTRL.TRAP_SEEN`); the Penn bridge decoded
  only `addr[31]` and `addr[4:2]`, so such accesses aliased silently.
- **Standard sleep.** Firmware executes `wfi` after `CTRL.START`; the bridge's
  sticky DONE latch drives `irq_fast[0]` and wakes the core with no trap
  taken (`mie.fast0` set, `mstatus.MIE` clear). This replaces the Penn core's
  custom `clk_en_i`. `core_sleep_o` is exported for a future clock gate; the
  clock is not gated yet (MAS section 8.1 policy unchanged).
- **Verification collateral.** riscv-dv/Spike co-simulation and a silicon
  track record come with the core; the previous 77-test cocotb ISA regression
  (`tb/rv32i_regression/{run,notrace,poll,rerun,runner_timing,timing_check}.sh`)
  targets the retired core and is no longer part of the flow.

Integration points that changed: the shell (`agriasic_rv32i_control_shell.sv`),
the MMIO bridge (OBI handshake, full decode, CTRL bits 8/9 and STATUS bits 5/6),
`start.S` (32-entry vector table at 0x0, reset at 0x80, `mie` setup, `FW_DONE`
instead of `ecall`), `link.ld`, and `-march=rv32imc_zicsr` in `build.sh`. The
two SRAM wrappers keep their 1-cycle contract: Ibex's `req/gnt/rvalid` maps
onto it as `gnt = req`, `rvalid = registered req`.

## Debug (Phase 2)

The shell also instantiates pulp-platform **riscv-dbg** (`rtl/riscv-dbg/`,
Debug Spec 0.13): `dmi_jtag` (5-wire IEEE 1149.1 TAP + DTM, IDCODE
`0x14341001`) and `dm_top`. The chip top gained `jtag_tck_i / tms_i /
trst_ni / tdi_i / tdo_o`. A new interconnect, `agriasic_rv32i_bus.sv`,
replaces the point-to-point memory wiring so that the debugger sees one flat
address space:

| Region | Address | Who reaches it |
|---|---|---|
| IMEM (4 KiB, **loadable**) | `0x0000_0000` | core fetch; core data port; debug SBA (`load`) |
| DMEM (2 KiB) | `0x0001_0000` | core data port; debug SBA |
| Debug module | `0x1A11_0000` | core fetch (debug ROM / program buffer); core data port (data0/1, flags) |
| MMIO | `0x8000_0000` | core data port; debug SBA |
| anything else | | bus error: access-fault trap on the core, `sberror` on SBA |

Fixed-priority arbitration (core data > SBA > core fetch) with OBI grant
back-pressure; every slave answers in one cycle. **DMEM moved from `0x0` to
`0x0001_0000`** so the two memories no longer overlap in the debugger's view;
`SP`, the `OUT_*` result addresses and `link.ld`'s `RAM` region moved with it.
`dmcontrol.ndmreset` resets the core and the peripheral bridge only (IMEM
contents, the DM and the TAP survive), and is acknowledged back to the DM.
While `start_i` is low the hart is in reset and reported `unavailable`.

`fw/openocd_agriasic.cfg` is a ready OpenOCD target file (`progbuf` first,
`sysbus` fallback). `tb/tb_agriasic_jtag.sv` drives the pins with a
behavioural JTAG master through the real DTM/DM protocol: IDCODE/DTMCS, DM
activation, halt while the core is asleep in `wfi`, `dpc`/`sp` via abstract
commands, SBA read/write of RAM, IMEM and MMIO plus `sberror` on an unmapped
address, resume with the sweep then finishing correctly (results read back
through the SBA), and the `ndmreset`/`havereset` handshake. It is stage 13 of
`verify_all.sh`.

The Ibex `DmExceptionAddr` is `DmBaseAddr + 0x810` — riscv-dbg's debug ROM
puts the exception entry 16 bytes past the halt entry, not 8 as Ibex's
default parameter assumes; both come from `dm_pkg` in the shell so they cannot
drift apart.

Generic Yosys synthesis of the whole `agriasic_digital_rv32i_top` (memories
blackboxed, FF register file for hierarchy parity with the power testbench,
`-nofsm` so enum state encodings match the simulation): 33,535 combinational
primitives + 2,800 flops with the Penn core; 16,919 + 2,138 with Ibex;
**25,043 + 3,254 with Ibex + bus + debug module** (the DM alone is 1,076
register bits: abstract data, 8-word program buffer, SBA, DTM CDC). Add
`-D AGRIASIC_LATCH_REGFILE` for the ASIC run to use Ibex's latch register
file.

Verilator note: Ibex gates its own core clock while idle, so its async-reset
flops are only reset by a real `negedge`. Testbenches therefore drive
`rst_n`/`start_i` high for a few clocks before asserting reset (a 1->0->1
sequence, as lowRISC's own harness does). Silicon is unaffected.

## Bring-up order

1. `ctrl/measurement_fsm.sv` — the sequencer everything else serves
2. `ctrl/excitation_ctrl.sv` + `ctrl/sar_controller.sv` — its timing shims
3. `agriasic_digital_top.sv` — measurement engine integration
4. `ctrl/spi_slave.sv` + `agriasic_digital_spi_top.sv` — host path
5. `rv32i/agriasic_imem.sv` + `agriasic_dmem.sv` — SRAM timing contract
6. `rv32i/agriasic_rv32i_mmio.sv` — hardware/software boundary
7. `agriasic_rv32i_control_shell.sv` + `agriasic_digital_rv32i_top.sv`
8. `tb/rv32i_regression/verify_all.sh`

## Build and test

```bash
bash fw/build.sh                          # regenerate fw/agriasic_fw.hex
bash tb/rv32i_regression/verify_all.sh    # lint + smoke + SPI smoke + e2e
```

Requires Verilator 5.x and `riscv64-unknown-elf-gcc` (with `rv32imc_zicsr`
support; GCC 13 is known good). Every script that compiles the chip top sources
`tb/rv32i_regression/ibex_sources.sh` for the vendored Ibex file list. The old
cocotb ISA regression scripts target the retired Penn core.

Files ending in `.orig` are pre-fix snapshots. The smoke comparison scripts build
against them deliberately, to show the failure each fix removes.

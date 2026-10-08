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
    agriasic_rv32i_bus.sv              interconnect: core instr/data + debug SBA + boot -> IMEM / RAM+MMIO / DM
    agriasic_spi_boot.sv               boot loader: golden ROM or SPI flash -> IMEM; post-boot SPI peripheral
    agriasic_boot_rom.sv               GENERATED golden image as a constant table (fw/gen_boot_rom.py)
    agriasic_imem.sv                   program memory (loadable), synchronous-SRAM contract
    agriasic_dmem.sv                   scratch RAM, synchronous-SRAM contract
    agriasic_rv32i_mmio.sv             RAM + peripheral registers behind the bus (Ibex/OBI)
    agriasic_rv32i_mmio.sv.penn        previous bridge for the Penn core
    agriasic_rv32i_core.sv             RETIRED: Penn CIS 5710 5-stage RV32IM datapath
    agriasic_rv32i_cla.sv              RETIRED: carry-lookahead adder (Penn core)
    agriasic_rv32i_divider.sv          RETIRED: pipelined divider (Penn core)
fw/                                    firmware: fw.c, start.S, link.ld, build.sh (also emits the flash image), openocd_agriasic.cfg
  gen_boot_rom.py                      promote a build to golden and regenerate the boot-ROM RTL
  golden/                              the pinned golden image + GOLDEN.md provenance
tb/
  smoke/                               measurement and SPI smoke tests
  tb_agriasic_rv32i_e2e.sv             end-to-end: firmware drives the FSM
  tb_agriasic_jtag.sv                  JTAG master -> DTM -> DM: halt/regs/SBA/resume/ndmreset/boot control
  tb_agriasic_flash_boot.sv            boot from a behavioural SPI NOR (tb_spi_flash_model.sv): good/CRC-bad/blank/restored
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

## Tetrapolar analog interface (Rev 5)

The measurement engine now drives and senses the four-electrode probe:

| | Before | Now |
|---|---|---|
| Excitation | `exc_drive_p_o` / `exc_drive_n_o`, 1-bit square, 7-state halves + dead time | `afe_sine_code_o[7:0]`, 16-point **cosine** table to the sine DAC, `cfg_amplitude` attenuation |
| Channels | one ADC input | two: `dV` (diff PGA on E2/E3) and `I` (TIA on E4), through `afe_mux_sel_o[1:0]` |
| Sampling | one `afe_sample_o` per conversion | one strobe freezes **both** S/H at the phase point; two conversions follow |
| Results | `result_i_o`, `result_q_o` | `result_dv_i/q_o`, `result_cur_i/q_o` — a host computes Z(f) = dV(f) / I(f) |

**Cosine, not sine.** The FSM samples at phase indices 0/4/8/12; the table
puts the drive peaks at 0/8 (the I terms) and mid-code at 4/12 (the Q terms),
which is what makes synchronous demodulation separate in-phase from
quadrature. A sine table would put a zero crossing at index 0 and the I
channel would measure nothing. `code[k] + code[k+8] == 256` exactly, so the
+/- chop still cancels offset and drift — the square wave got that from two
equal drive halves, the table gets it from its own values.

**16 phase states kept**, so `f_exc = f_clk/(16·N)` and the N = 1/100/10000
presets are unchanged. `PHASE_STEPS` is a parameter for raising the point
count later; doing so also changes the frequency contract and the firmware
presets, so it is deliberately not a silent knob. There is no dead time any
more (no complementary drive transistors) — **MAS GAP-6 is retired**.

**Simultaneous sample-and-hold.** At each phase point the FSM issues one
strobe (`take_sample_o = 1` on the first conversion), then converts dV and
then current with `take_sample_o = 0`. Both channels are frozen at the same
instant, so the voltage/current phase relationship is set by the strobe and
not by conversion order. The alternative — dV on one excitation period, I on
the next — needs one fewer S/H but assumes the soil and drive are stationary
across adjacent periods, a weak claim at the 1 kHz point where a period is a
millisecond. Cost: eight conversions per pair instead of four, negligible
against settle time. `cfg_mux_settle` (new register) gates the mux + S/H
settling before each conversion's first bit trial, the same runtime-register
pattern as `cfg_conv_cycles`.

New MMIO: `RESULT_CUR_I` `0x8000_0034`, `RESULT_CUR_Q` `0x8000_0038`,
`AFE_CTRL` `0x8000_003C` (`[1:0]` pga_gain, `[3:2]` tia_rf, `[5:4]` amplitude,
`[15:8]` mux_settle). `RESULT_I`/`RESULT_Q` keep their addresses and now carry
the dV channel. On the SPI host map, the indexed result vector gains
indices 4-7 for the current channel. Firmware stores four values per sweep
point (`OUT_DV_I/Q`, `OUT_CUR_I/Q`); the result block grew from 48 B to 88 B.

New analog-control pins on the RV32I top: `afe_sine_code_o[7:0]`,
`afe_mux_sel_o[1:0]`, `afe_pga_gain_o[1:0]`, `afe_tia_rf_o[1:0]` (the last two
are analog control, not pads if the AFE takes them internally).

**Port naming.** Every port on a boundary module carries a prefix saying where
the signal goes: `afe_` into the analog front end, `gpio_` off the die (bond
these), `dbg_` observability only (do **not** bond). Unprefixed means die-internal
block-to-block wiring (plus `clk` and `rst_n`, the only unprefixed pins). Leaf modules (`sar_controller`, `excitation_ctrl`,
`measurement_fsm`, `spi_slave`, ...) deliberately keep unprefixed names — the
prefix marks a chip boundary. See `docs/interface_contract.md`.

## Debug (Phase 2)

The shell also instantiates pulp-platform **riscv-dbg** (`rtl/riscv-dbg/`,
Debug Spec 0.13): `dmi_jtag` (5-wire IEEE 1149.1 TAP + DTM, IDCODE
`0x14341001`) and `dm_top`. The chip top gained `gpio_jtag_tck_i / _tms_i /
_trst_ni / _tdi_i / _tdo_o`. A new interconnect, `agriasic_rv32i_bus.sv`,
replaces the point-to-point memory wiring so that the debugger sees one flat
address space:

| Region | Address | Who reaches it |
|---|---|---|
| IMEM (1 KiB, **loadable**) | `0x0000_0000` | core fetch; core data port; debug SBA (`load`) |
| DMEM (512 B) | `0x0001_0000` | core data port; debug SBA |
| Debug module | `0x1A11_0000` | core fetch (debug ROM / program buffer); core data port (data0/1, flags) |
| MMIO | `0x8000_0000` | core data port; debug SBA |
| anything else | | bus error: access-fault trap on the core, `sberror` on SBA |

Fixed-priority arbitration (core data > SBA > core fetch) with OBI grant
back-pressure; every slave answers in one cycle. **DMEM moved from `0x0` to
`0x0001_0000`** so the two memories no longer overlap in the debugger's view;
`SP`, the `OUT_*` result addresses and `link.ld`'s `RAM` region moved with it.
`dmcontrol.ndmreset` resets the core and the peripheral bridge only (IMEM
contents, the DM and the TAP survive), and is acknowledged back to the DM.
While `gpio_start_i` is low the hart is in reset and reported `unavailable`.

`fw/openocd_agriasic.cfg` is a ready OpenOCD target file (`progbuf` first,
`sysbus` fallback). `tb/tb_agriasic_jtag.sv` drives the pins with a
behavioural JTAG master through the real DTM/DM protocol: IDCODE/DTMCS, DM
activation, halt while the core is asleep in `wfi`, `dpc`/`sp` via abstract
commands, SBA read/write of RAM, IMEM and MMIO plus `sberror` on an unmapped
address, resume with the sweep then finishing correctly (results read back
through the SBA), and the `ndmreset`/`havereset` handshake. It is stage 13 of
`verify_all.sh`.

## Boot: golden ROM by default, SPI flash when strapped

The IMEM SRAM is **shadow-loaded** at reset from one of two sources, chosen by
the `gpio_boot_sel_i` strap (sampled once on the first cycle out of reset, then
ignored):

| `gpio_boot_sel_i` | Source | Time | Use |
|---|---|---|---|
| **0** (default) | on-die synthesized **golden boot ROM** | ~150 cycles (0.9 µs) | a bare chip with no flash and no host starts and runs on its own |
| 1 | external SPI flash, header + CRC-32 checked | ~80k cycles (0.5 ms) | the patchable path: build, program the flash, strap high |

**The core always fetches from the SRAM, never from the ROM.** That is the
point of shadow-loading rather than muxing the ROM onto the fetch path:

- nothing is added to the fetch path's timing at 160 MHz;
- firmware is linked once, at one address, for both sources;
- **IMEM stays writable after a ROM boot** — halt over JTAG, patch a constant,
  resume. Changing a config parameter during testing needs neither a rebuild
  nor the flash. A fetch-from-ROM arrangement could not do this.

The ROM holds the **golden (known-good) image**, frozen at tapeout. It is
deliberately not regenerated by `build.sh`; promoting a new build is explicit:

```bash
python3 fw/gen_boot_rom.py --promote   # current build -> golden/, regenerate the ROM RTL
python3 fw/gen_boot_rom.py             # regenerate the RTL from golden/ only
```

`fw/golden/GOLDEN.md` records the date, word count and SHA-256 of the promoted
image, so what is in silicon is reviewable in version control. Only promote an
image that has passed the full regression.

`BOOT_CTRL` overrides the strap in both directions, so neither source is
reachable only by re-strapping a board: bit 1 re-boots from flash, bit 2
re-boots from the golden ROM, bit 0 releases the core without either.
`BOOT_STATUS[13:12]` reports which source the running image actually came from
(0 = none/skip, 1 = golden ROM, 2 = flash).

Cost: the ROM is a constant table, so synthesis maps it into gates —
**+1,027 combinational primitives and +6 flops** for the 148-word image,
against the 4,736 storage bits a writable array of the same depth would need.

## Boot from SPI flash (details)

`agriasic_spi_boot.sv` is the fourth bus master. With the `gpio_boot_sel_i` strap
high it waits `BOOT_DELAY_CYCLES` after reset (flash power-up), issues
`READ 0x03` from flash address 0, checks a 16-byte header — `magic "AGRA"`,
payload length, version, CRC-32 (zlib) of the payload — streams the payload
into program memory as 32-bit words, and on a matching CRC raises `fw_valid`,
which (together with `gpio_start_i`) releases the core. A bad magic, length, CRC or
bus error leaves the core in reset with `gpio_boot_fail_o` high and an error code
in `BOOT_STATUS`. With the strap low nothing touches the flash and the core
waits for `BOOT_CTRL.release` — the bench flow: OpenOCD loads IMEM over the
SBA, then `mww 0x80000024 1`. `BOOT_CTRL.retry` re-runs the flash boot (used
by firmware after it has rewritten the flash). Once the boot FSM is idle the
same SPI engine is a firmware peripheral (`SPI_CTRL`, `SPI_DATA`,
`SPI_STATUS` at `0x8000_0028..30`), so the chip can reflash itself when a
host hands it a new image.

`fw/build.sh` produces the image (`agriasic_fw_flash.bin` for the flash,
`.hex` for simulation). Boot takes ~65.7k core cycles for the 484 B image at
## Host SPI port (bus master M4, closes GAP-11)

Four pads let an external host read results and write config: `gpio_spi_sclk_i`,
`gpio_spi_cs_n_i`, `gpio_spi_mosi_i`, `gpio_spi_miso_o` (+ `_miso_oe_o`). The
chip is the **slave**. These are deliberately **not** shared with the flash port
— the two have opposite roles, so every wire runs the opposite direction.

The host gets its own **bus master port**, shaped like the debug module's system
bus access, rather than a mailbox. It therefore reads a finished sweep straight
out of DMEM **while the core is parked in `wfi`**, with no firmware cooperation
and no handshake to get wrong.

| Phase | Bytes | Content |
|---|---|---|
| command | 1 | `0x03` READ, `0x02` WRITE, `0x05` status |
| address | 4 | 32-bit, big endian |
| data | n x 4 | little endian per word, auto-incrementing |

**Reach: DMEM and the peripheral window only.** IMEM is refused so a field host
cannot overwrite firmware (that stays JTAG's job), and the debug module is
refused so it cannot take debug control. Both refusals are enforced in the
interconnect decode and surface as a sticky error bit, not as silent garbage.

Cost: **+218 flops, +1,242 combinational primitives**. Verified by
`tb_agriasic_spi_host.sv` (regression stage 15).

## Boot from SPI flash (details, continued)

SCK = clk/16 (0.41 ms at 160 MHz). New chip pins: `gpio_boot_sel_i`,
`gpio_flash_sck_o / _cs_n_o / _mosi_o / _miso_i`, `gpio_boot_fail_o`. The boot loader resets
only with the chip, never with `ndmreset`, so a debugger reset cannot restart
a flash boot underneath an image it just loaded.

Simulation note: `IMEM_PRELOADED=1` (testbenches that rely on `$readmemh`)
makes the skip path release the core immediately; `IMEM_INIT_FILE=""` starts
with an empty program memory (the flash-boot test). `rst_sync` and the shell's
`core_rst` carry `ifndef SYNTHESIS` initial values so Ibex's async-reset flops
see a genuine reset edge under Verilator regardless of when `fw_valid` comes.

The Ibex `DmExceptionAddr` is `DmBaseAddr + 0x810` — riscv-dbg's debug ROM
puts the exception entry 16 bytes past the halt entry, not 8 as Ibex's
default parameter assumes; both come from `dm_pkg` in the shell so they cannot
drift apart.

Generic Yosys synthesis of the whole `agriasic_digital_rv32i_top` (memories
blackboxed, FF register file for hierarchy parity with the power testbench,
`-nofsm` so enum state encodings match the simulation): 33,535 combinational
primitives + 2,800 flops with the Penn core; 16,919 + 2,138 with Ibex;
**25,043 + 3,254 with Ibex + bus + debug module** (the DM alone is 1,076
register bits: abstract data, 8-word program buffer, SBA, DTM CDC);
**27,094 + 3,615 with the SPI-flash boot loader** (342 register bits);
**27,538 + 3,720 with the Rev 5 tetrapolar front end** (the measurement engine
grew from 144 to 235 register bits: four accumulators and their shadows
instead of two, plus the sample-code holds); **28,565 + 3,726 with the golden
boot ROM** (the ROM is combinational, so it costs gates, not flops; the 6 new
flops are the strap latch, the two override bits and the source field). Add
`-D AGRIASIC_LATCH_REGFILE` for the ASIC run to use Ibex's latch register
file.

Verilator note: Ibex gates its own core clock while idle, so its async-reset
flops are only reset by a real `negedge`. The reset synchroniser and the
shell's `core_rst` therefore start *released* in simulation (`ifndef
SYNTHESIS` initial values) so the first clock with reset asserted is a real
edge; the testbenches' 1->0->1 preamble is belt and braces. Silicon is
unaffected.

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

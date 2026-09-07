# AgriASIC

Digital design for the AgriASIC single-die impedance sensing node — an
agricultural sensor ASIC that measures soil impedance and reports results over
SPI to a host.

All digital collateral lives under [`agriasic_digital_v2/`](agriasic_digital_v2/).

---

## Architecture

The subsystem uses a **two-layer control partition**:

```text
              SPI host
                 |
        agriasic_digital_spi_top          <- host control / debug ingress
                 |
   +-------------+--------------------------------+
   |                                              |
   |   RV32IM core  +  ROM  +  MMIO bridge        |   POLICY  (software)
   |   agriasic_rv32i_control_shell               |   when to measure, with
   |                                              |   what config, what to do
   +----------------------+-----------------------+   with the result
                          | cfg / start / status
   +----------------------+-----------------------+
   |   measurement_fsm                            |   MECHANISM (hardware)
   |     excitation_ctrl   sar_controller         |   cycle-accurate timing
   +----------------------------------------------+
                          |
                  excitation / SAR ADC
```

**Software decides policy; hardware keeps time.** Nothing cycle-accurate lives
in firmware. As of Phase 4, excitation is **free-running** — `excitation_ctrl`
never waits on the FSM — and the FSM only watches the phase counter and
strobes a sample the instant it matches the phase it wants; settle
qualification, conversion trigger and accumulation stay in the measurement
FSM. This matters for two reasons:

- **Jitter is measurement noise.** The conversion fires the instant the
  free-running phase counter reaches the target phase, always the same point
  on the analog settling curve. If that instant moved with instruction
  timing, the ADC code would move with it — noise indistinguishable from
  signal.
- **The ± chop needs time symmetry.** `(D+ − D−)/2` cancels offset and drift only
  if both phases are timed identically. The free-running phase generator gives
  that structurally: the two halves are 7 phase states each, exactly equal.

The core is clock-enabled off (not reset, not clock-gated) whenever no
measurement is in flight — see Phase 2 below — which is also the low-power
state for a solar/battery node.

---

## Where to start

| Order | File | Why |
| --- | --- | --- |
| 1 | [`docs/agriasic_high_level_design_rev4_integrated_node.md`](agriasic_digital_v2/docs/agriasic_high_level_design_rev4_integrated_node.md) | System context |
| 2 | [`rtl/agriasic_digital_rv32i_top.sv`](agriasic_digital_v2/rtl/agriasic_digital_rv32i_top.sv) | The whole partition in ~70 lines |
| 3 | [`fw/fw.c`](agriasic_digital_v2/fw/fw.c) | Clearest statement of software's job |
| 4 | [`rtl/rv32i/agriasic_rv32i_mmio.sv`](agriasic_digital_v2/rtl/rv32i/agriasic_rv32i_mmio.sv) | The hardware/software boundary |

Items 3 and 4 together are the fastest route to understanding the design.

Then, by task:

- **Measurement path** — `rtl/ctrl/measurement_fsm.sv`, then `excitation_ctrl.sv`
  and `sar_controller.sv`
- **Host interface** — `docs/interface_contract.md`, then
  `rtl/agriasic_digital_spi_top.sv`
- **Processor** — `rtl/rv32i/agriasic_imem.sv` and `agriasic_dmem.sv` **first**
  (they define the SRAM timing contract everything else depends on), then
  `agriasic_rv32i_core.sv`
- **Verification** — `tb/rv32i_regression/verify_all.sh`, then
  `tb/tb_agriasic_rv32i_e2e.sv`
- **Full spec** — `docs/agriasic_digital_MAS.md`

---

## Layout

```text
agriasic_digital_v2/
  rtl/
    agriasic_digital_rv32i_top.sv     RV32I chip top
    agriasic_rv32i_control_shell.sv   core + ROM + MMIO
    agriasic_digital_spi_top.sv       SPI host interface
    agriasic_digital_top.sv           measurement engine
    ctrl/                             measurement FSM, excitation, SAR, SPI slave
    rv32i/                            processor, SRAM wrappers, MMIO bridge
  fw/                                 control firmware (C + startup + linker)
  tb/                                 testbenches and regression scripts
  docs/                               specs, interface contract, diagrams
```

Files ending in `.orig` are pre-fix snapshots, kept because the smoke comparison
scripts build against them to demonstrate the bugs they fix.

One caveat after the Rev 4.3 settle fix: the smoke comparison no longer
distinguishes `sar_controller.sv.orig` from the fixed version. Both legs report
480 at the smoke test's `settle=2, conv=1` configuration. The pre-fix controller
is still broken — at `settle=0` it returns 60 instead of 480 — but that specific
config happens to close the window in which its missing `!sample_done_o` guard
launches a spurious second conversion.

`tb/tb_settle_timing.sv` does catch it, at `settle=0`. Treat the settle
regression, not the smoke comparison, as the test that covers this bug.

---

## Toolchain

| Tool | Used for |
| --- | --- |
| Verilator 5.x | lint and simulation |
| `riscv64-unknown-elf-gcc` | firmware |
| cocotb 1.9.x + riscv-tests | processor ISA regression only |

On Windows, run these under WSL. To set WSL up (elevated PowerShell, once):

```powershell
wsl --install -d Ubuntu-24.04
```

Then, inside Ubuntu 24.04:

```bash
sudo apt install -y verilator gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
                    build-essential python3.12-venv python3-pip
```

`fw/agriasic_fw.hex` is committed, so Verilator alone is enough for lint, both
smoke tests and the end-to-end run. The RISC-V toolchain is only needed to
rebuild the firmware image.

---

## Build and verify

Firmware (regenerates `fw/agriasic_fw.hex`, the ROM image):

```bash
bash agriasic_digital_v2/fw/build.sh
```

Full verification sweep — lint, both smoke tests, and end-to-end:

```bash
bash agriasic_digital_v2/tb/rv32i_regression/verify_all.sh
```

The 77-test processor ISA regression (rv32ui + dhrystone) is **not** covered by
that script: it needs the CIS 5710 cocotb harness and a built `riscv-tests`,
neither of which lives in this repo. See `tb/rv32i_regression/` for those scripts.

---

## Status

| Check | Result |
| --- | --- |
| Processor — rv32ui ISA suite + dhrystone | 77/77 as of the last run; **not re-run since Phase 2.2 touched the core** (needs the external cocotb harness, not present here) |
| Measurement smoke (`tb_agriasic_digital_top`) | pass, I=480 Q=320, every sample (16 of them) phase-matched exactly (0 errors) |
| SPI smoke (`tb_agriasic_digital_spi_top`) | pass, I=480 Q=320 read back via the indexed `REG_RESULT_IDX`/`REG_RESULT_DATA` (Phase 6); auto-increment, reserved-zero, `REG_ID`, and overrange bit all checked |
| SAR bit-trial unit test (`tb_sar_bit_trial`) | pass, exact convergence over 0–255 |
| Excitation free-running phase generator (`tb_excitation_drive`, rewritten Phase 4) | pass, exact 16/80/208-cycle periods at N=1/5/13 |
| Reset synchronizer (`tb_rst_sync`) | pass, 4 clk-unaligned phase offsets |
| SPI clk-domain rework (`tb_spi_domain_crossing`) | pass, correct at `f_clk/16`, corrupted below Nyquist |
| Settle timing regression (`tb_settle_timing`) | pass |
| End-to-end firmware + measurement (Phase 7: 3-point sweep, N=1/100/10000) | pass, I=400 Q=280 at all 3 points, 3,152,965 cycles total |
| Full chip lint | clean |
| Control shell descope fallback lint (`.orig`) | clean -- was checked only by hand before, now a regular sweep stage |
| Accumulator edge cases (Phase 8, closes V-2) | pass: odd (55), +1, -1, and true M=64 saturating (16320) all exact |
| Settle x conv grid sweep (Phase 8, closes V-1) | pass: 54/54 practical grid points, no hangs, correct results |

Results are 480 (was 240) and the end-to-end average is 400 (was 200) because the
measurement FSM now accumulates the **raw** signed difference. See the Rev 4.3
note below.

---

## Rev 4.3 defect fixes

The three defects called out in the Rev 4.3 write-up
([`docs/agriasic_rev43_phase_locked_design.md`](agriasic_digital_v2/docs/agriasic_rev43_phase_locked_design.md))
are fixed and covered by regression tests.

| # | Defect | Fix |
| --- | --- | --- |
| 1 | Settle interval never applied — `settle=0` and `settle=2` gave identical 49-cycle runs | Phase command is edge-triggered in `excitation_ctrl`, and the FSM issues it from a dedicated one-cycle state |
| 2 | Deadlock whenever the settle countdown outlived the settle state (`settle>=5, conv=1` hung) | Same change: the held command no longer pins `settled_o` low |
| 3 | `pair_delta` right-shifted each pair, destroying averaging gain and adding sign-dependent bias | Accumulate the raw signed difference; scale on the host. M clamped to 64 |

Settle now scales exactly linearly — 57 cycles at `settle=0`, +8 cycles per settle
count (8 settle intervals per 4-pair run). `tb/tb_settle_timing.sv` locks this in
without hardcoding cycle counts.

**Host contract change.** `REG_RESULT` is now `sum(D+ - D-)` over M pairs, not
`sum((D+ - D-)/2)`. Hosts must divide by M themselves. This doubles every
previously observed value. Worst case is `64 * 255 = 16320`, inside signed 16-bit.

## Rev 4.3 progress

**Phase 1 (analog boundary) is done.** `exc_drive_p_o`/`exc_drive_n_o` replace
the single `exc_pol_o` with break-before-make drive (`{p,n}=2'b11` is
structurally unreachable, not just unasserted — see `excitation_ctrl.sv`).
`sar_controller` now runs the 8-bit successive-approximation search itself
against `adc_dac_o`/`adc_comp_i`; `adc_code_i` is gone from every module.
`miso_oe_o` puts MISO in high-Z when `cs_n` is inactive. All three are covered
by dedicated regression tests (`tb_sar_bit_trial.sv`, `tb_excitation_drive.sv`,
and a `miso_oe_o` assertion in the SPI smoke test).

Two placeholder timing values from this phase still need real numbers from the
analog team before tapeout: the break-before-make dead time (`DEAD_CYCLES`
parameter, default 1 cycle) and the SAR comparator regeneration time
(`REG_CONV`, now runtime-tunable so no respin is needed once known — see MAS
GAP-2 and GAP-6).

**Phase 2 (clock and reset discipline) is also done.** A 2FF reset
synchronizer (`rst_sync.sv`, async assert / sync deassert) sits in each
chip-boundary top. The RV32I core (`DatapathPipelined`/`RegFile`) gained a
`clk_en_i` input — the control shell drives it automatically off the real
`start_pulse_o`/`measurement_done_i` handshake, no firmware changes needed.
Verified against the actual trigger path, not synthetically: across one
firmware run (4 real measurements), the core sat frozen for **93% of total
cycles**, an assertion that the Fetch PC never moves while frozen held with
zero violations, and results stayed bit-exact.

**Phase 3 (SPI domain rework) is also done.** `spi_slave.sv` no longer has a
second clock domain: `sclk_i`/`cs_n_i`/`mosi_i` are 2FF-oversampled into
`clk`, every bit/byte event is a detected edge on the synchronized signal, and
the old toggle synchronizer for `rx_valid_o` is gone entirely — byte
completion is native to the `clk` domain now, so there is nothing left to
cross. `grep -rn "always_ff @(" rtl/` finds zero matches outside `posedge clk`
anywhere in the synthesizable tree — SPI was the one documented exception to
the single-clock-domain rule, and it no longer is one.

Max SCLK = `f_clk/16` is now load-bearing, not a suggestion: `tb_spi_domain_crossing.sv`
verifies correct transfer at exactly that rate and demonstrates real data
corruption at a rate below the sampling clock's own Nyquist rate. The old
"leave an inter-byte gap" host requirement is retired — checked directly, the
response byte is ready one `clk` cycle after the command byte completes, so
the `f_clk/16` rate limit already covers it with margin to spare.
[`docs/interface_contract.md`](agriasic_digital_v2/docs/interface_contract.md)
is fully refreshed against the current RTL.

**Phase 4 (phase-locked excitation) is also done.** `excitation_ctrl.sv` is
rewritten as a free-running divider plus 4-bit phase counter
(`phase_index_o[3:0]`, `period_tick_o`) — it no longer takes any command from
the FSM at all. Phase encoding is 0-6 drive positive, 7 dead, 8-14 drive
negative, 15 dead: 7 states per half, exactly equal, one dead state between
transitions. `measurement_fsm.sv` no longer commands a polarity flip; it
watches `phase_index_i` and strobes a sample the instant it matches (0 for
D+, 8 for D-). The divider is widened to **14 bits** end-to-end
(`excitation_ctrl`, `agriasic_digital_top`, both control shells, and the
RV32I MMIO path, which is fully 14-bit with no windowing) so the excitation
floor reaches the 1 kHz point that an 8-bit divider couldn't (39.2 kHz was
the old floor). SPI and the parallel programming interface keep an 8-bit
write/read window onto that 14-bit register for now — extending it is Phase
6's job.

`f_exc = f_clk / (16 x N)` now holds **exactly**: `tb_excitation_drive.sv`
(rewritten for the free-running interface) measures 16/80/208 clk
cycles/period at N=1/5/13 with zero drift — this also fixes a real
off-by-one bug inherited from Rev 4.2, where the old tick comparison produced
`divider_i + 1`-cycle periods instead of exactly `divider_i`.

Building this surfaced a real, non-obvious testbench bug: every behavioral
ADC comparator model in the tree read `exc_drive_p_o` *live* every cycle to
pick a target code, which was fine while excitation only changed on an FSM
command, but broke silently once excitation became free-running (a SAR
conversion takes 24+ cycles; a single phase state can last as little as 1
clock cycle at N=1). First symptom was the smoke test failing outright
(`expected=480 got=204`). Fixed by making all six affected testbenches
track-and-hold: latch the ADC target on `adc_sample_o` and hold it for the
whole conversion, like a real T&H would, instead of re-deriving it from a
drive signal that may have already moved on. A phase-match assertion was also
added to the measurement smoke test to prove samples land on the *exact*
documented phase index (0 and 8), not just "somewhere in the right
half-cycle" — a gap a numerically-correct result alone couldn't have caught.

One open question flagged, not resolved: the sample points (phase 0 and 8)
sit on the very first cycle after each polarity transition, with no settle
margin inside the sampled half itself — see MAS GAP-7 for what analog/systems
review needs to confirm before trusting the fastest excitation points.

**Phase 5 (I/Q accumulation) is also done.** `measurement_fsm.sv` now samples
all four phase offsets per pair — 0/90/180/270 degrees, not just 0/180 — into
**two** independent signed 16-bit accumulators (I and Q). `sar_controller`'s
D+/D- capture slots are reused unmodified for all four samples; the FSM's own
sequencing (`S_ACCUM_I` reads before either slot is overwritten for the Q
samples) is what keeps the channels from cross-contaminating, not new
hardware. A shadow-register snapshot (`i_shadow_q`/`q_shadow_q`, latched only
on the `S_LOOP -> S_DONE` transition) means a host reading mid-run always sees
the previous run's complete result, never a partial sum — this is the first
time that long-specified contract has actually been implemented, not just
described.

Both channels are exposed today as **four direct registers**
(`REG_RESULT_I_LO/HI` at 0x6/0x7, `REG_RESULT_Q_LO/HI` at 0x8/0x9) on every
host interface — SPI, the parallel programming interface, and RV32I MMIO
(`REG_RESULT_Q` newly added at 0x8000_001C) — deliberately ahead of the
indexed, multi-frequency-point readout scheme Phase 6 will build once there's
an actual 13-byte result set that needs it. `fw/fw.c` was updated to match:
it now reads `REG_RESULT_I`/`REG_RESULT_Q` and writes `OUT_AVERAGE`/
`OUT_AVERAGE_Q` and `OUT_SAMPLES`/`OUT_SAMPLES_Q` to scratch RAM.

Two testbench-modeling issues were found and fixed while building this. First,
every behavioral ADC model's track-and-hold logic (added in Phase 4) was
keyed on `exc_phase_index` at the moment `adc_sample_o` fired — that broke
silently for Phase 5 because `sar_controller` registers `adc_sample_o` one
cycle after the phase match that triggered it, so at N=1 the phase counter
has already ticked past 0/4/8/12 to 1/5/9/13 by the time the model reads it.
First symptom: `SMOKE_FAIL: expected I=480 got=0`. Fixed by keying every
model on `measurement_fsm`'s own state instead, which is unambiguous
regardless of that one-cycle lag. Second, a real pre-existing port-identity
drift was found in `agriasic_rv32i_control_shell.sv.orig` (the microsequencer
descope fallback): its `cfg_exc_divider_o` port was still `[7:0]`, three
phases after the real shell widened the same port to `[13:0]` — nothing
caught it because `.orig` isn't referenced by any lint or build script. Fixed
by hand and lint-checked directly; see MAS GAP-8 for why this can silently
recur.

**Phase 6 (register map and readout) is also done.** The SPI register map is
now the Rev 4.3 target layout, not an interim one: `REG_FREQ_SEL` replaces
`REG_DIVIDER` with a 2-bit selector (0/1/2 -> N=1/100/10000, i.e. 10 MHz/
100 kHz/1 kHz) instead of raw N — the only way to reach the 1 kHz point
(which needs 14 bits) through a single SPI byte without widening the 2-byte
protocol. `REG_RESULT_IDX`/`REG_RESULT_DATA` implement the indexed,
auto-incrementing byte readout the design doc specifies: indices 0-3 serve
real I/Q data, indices 4-15 read as an honest zero (frequency points 1/2 and
temperature don't exist yet — that's Phase 7). `REG_ID` (fixed `0x43`) and a
`REG_STATUS` overrange bit (set when `REG_PAIR_LOG2 > 6` gets silently
clamped to M=64) were added alongside. The parallel programming interface got
the same `REG_FREQ_SEL` selector treatment (`CFG_FREQ_SEL`), for the same
byte-width reason. RV32I MMIO's divider register keeps its original name and
raw-N behavior unchanged — it has no byte-width constraint forcing a
selector, and giving it the same name as SPI's selector-based register would
wrongly imply matching semantics.

Two items in the baseline register map were found to have no coherent
implementation given how the rest of the design was actually built, and were
left as documented, inert placeholders rather than guessed at: `REG_PHASE_IDX`
("phase index into the 16-state counter") doesn't reconcile with I/Q sampling
needing four *fixed* 90-degree-spaced points, not one selectable one; and
`REG_CTRL`'s core-enable bit presumes a unified chip with a toggleable on-die
core, which doesn't exist — the RV32I and SPI control paths are two separate,
mutually exclusive top-level modules today. Both addresses accept writes and
read them back so host software probing the map doesn't get an unexpected
error, but neither does anything yet. See MAS GAP-10.

**Phase 7 (sweep policy in firmware) is also done.** `fw/fw.c` is rewritten to
run the real 3-frequency-point sweep the design targets — N=1 (10 MHz),
N=100 (100 kHz), N=10000 (1 kHz) via `REG_FREQ_SEL`'s selector encoding —
averaging 2 measurements per point and writing divider/I/Q results for all
three points to scratch RAM (`OUT_DIV`/`OUT_I`/`OUT_Q`, replacing the old
single-point `OUT_AVERAGE`/`OUT_SAMPLES` layout). The real N=10000 timing was
verified, not assumed: the full 6-measurement sweep takes 3,152,965 simulated
cycles and 4.3 seconds of wall-clock time in Verilator — well within
practical regression budget. Temperature sensing (`OUT_TEMP`) stays an
explicit `-1` sentinel; no temperature sensor interface exists anywhere in
the digital RTL to wire it to (Phase 7.3, tracked as an open item below).

Building this surfaced a real architectural gap, not a bug: **`agriasic_digital_rv32i_top`
has zero SPI or other host-facing pins** (confirmed by grep — no matches at
all). The firmware now genuinely computes a 3-point sweep, but there is no
path for a real external host to read those results out of the RV32I chip
top; only the SPI-controlled top (`agriasic_digital_spi_top`, which has no
RV32I core) can talk to a host. See MAS GAP-11 for the three architectural
options to reconcile this before Rev 4.3 is called integration-ready.

**Phase 8 (verification and signoff) is also done.** All open items from the
Rev 4.3 baseline's verification plan are now closed or confirmed moot:

- **V-1** (settle x conv grid, was the single highest-value item left): closed
  with `tb_settle_conv_sweep.sv`, a 54-point practical grid (9 settle values x
  6 conv values) rather than the literal 65,536-point exhaustive grid, which
  is impractical for a fast-running regression — the grid still covers every
  settle/conv value class pairing that D-1/D-2's actual hang would have
  triggered.
- **V-2** (odd/±1/saturating rounding checks): closed with
  `tb_accum_edge_cases.sv`, covering all three cases including the true
  M=64 saturating value (16320) exactly. The rounding defect this was
  originally written for (D-3) is now structurally impossible — there is no
  shift or rounding left anywhere in the arithmetic path — so this is
  regression coverage, not open defect-hunting.
- **V-3**: confirmed still superseded by Phase 4 (no phase command left to
  bound).
- **V-4** and **V-5** (shadow-register stability and phase-match strobe
  correctness): both closed with new formal `assert property` statements in
  `tb/smoke/tb_agriasic_digital_top.sv` — `p_shadow_stable_while_busy` and
  `p_sample_req_exact_phase_match` — replacing the earlier trace-inspection-only
  evidence with a real structural restatement.

An accumulator-range assertion (`i_acc_q`/`q_acc_q` bounded to +/-16320) and
an explicit half-cycle-symmetry check (7 P-cycles == 7 N-cycles per period,
every N tested) were also added as regression coverage during this pass. See
[`docs/agriasic_digital_MAS.md`](agriasic_digital_v2/docs/agriasic_digital_MAS.md)
sections 10 and 12 for full detail, including the reasoning behind the
practical-vs-exhaustive V-1 grid and V-2's regression-not-defect-hunting
framing.

**A full synthesizability/lint audit was done across every file in `rtl/`**,
not just the files the regression scripts already touched, and every
diagram in `docs/diagrams/` was checked against the current RTL and redrawn
where it had drifted. Findings:

- Two genuinely dead signals were removed: `sar_busy` in
  `agriasic_digital_top.sv` (driven, never read — `measurement_fsm` tracks
  its own busy state and never polls `sar_controller`'s) and
  `pending_is_read_q` in `agriasic_digital_spi_top.sv` (write-only since
  before this session's changes, confirmed by checking the last commit).
- Two files were missing a trailing newline (`agriasic_digital_rv32i_top.sv`,
  `agriasic_digital_programming_top.sv`) — fixed.
- `agriasic_digital_spi_top.sv.orig` turned out to have an actual syntax
  error (`case`/`endcase` mismatch) on top of being dead code — fixed the
  syntax so the file at least parses, but it's still unbuildable against the
  current `agriasic_digital_top` (three `PINNOTFOUND` errors: it wants
  `adc_code_i`/`exc_pol_o`/`result_o`, none of which exist anymore).
- Two more previously-undocumented dead `.orig` snapshots were found:
  `ctrl/spi_slave.sv.orig` (pre-Phase-3) and confirmation that
  `ctrl/sar_controller.sv.orig` (pre-Phase-1, already referenced in the MAS's
  defect register) is in the same unbuildable state. None of the three are
  part of any documented descope story or referenced by any script — all
  three are recommended for deletion pending team confirmation (MAS GAP-9).
- `agriasic_rv32i_control_shell.sv.orig` (the *actual*, documented descope
  fallback) is real and correctly maintained, but was checked only by hand —
  added `lint_shell_orig.sh` as a proper regression stage so this can't drift
  silently again (closes MAS GAP-8).
- The remaining warnings under a strict `-Wall` pass are either the
  already-documented GAP-4 (dangling shell status outputs) or pre-existing
  characteristics of the third-party RV32I processor core (multi-module
  source files, internal disassembly/debug signals) that predate this
  project and are out of scope to rewrite. No `#` delays, implicit-sensitivity
  `always @(*)` blocks, or synthesizable-path `initial` blocks (other than
  standard `$readmemh` ROM init) exist anywhere in the real chip hierarchy.

## Known open items

- **GAP-11: `agriasic_digital_rv32i_top` has no host-facing pins at all.**
  The Phase 7 sweep firmware genuinely computes 3-frequency-point I/Q results,
  but there is no SPI (or other) path out of the RV32I chip top for a real
  external host to read them — only the separate, RV32I-free
  `agriasic_digital_spi_top` talks to a host. This needs an explicit
  architectural decision (see MAS section 10.3 GAP-11 for three options)
  before Rev 4.3 is integration-ready, not just simulation-clean.
- **Cocotb ISA regression needs an external checkout.** The scripts under
  `tb/rv32i_regression/` that drive the 77-test suite (`setup.sh`, `rerun.sh`,
  `build_riscv_tests.sh`) expect the CIS 5710 class repo and a `riscv-tests`
  checkout alongside this one. Point them elsewhere with `AGRIASIC_SRC_ROOT` or
  `RISCV_TESTS_SRC`. The lint, smoke and e2e scripts have no such dependency.
- **Shell status outputs are unconnected** in `agriasic_digital_rv32i_top.sv`
  (`shell_busy`, `shell_done`, `shell_result`, `shell_clear_errors`). Open
  question which is authoritative for an external host.
- **No foundry SRAM macro yet.** `agriasic_imem` / `agriasic_dmem` are behavioral
  models carrying the correct timing contract, with an
  `AGRIASIC_USE_SRAM_MACRO` ifdef for dropping in memory-compiler output.
- **Reference traces not regenerated** for the synchronous-SRAM core, so
  cycle-level trace comparison is unavailable.

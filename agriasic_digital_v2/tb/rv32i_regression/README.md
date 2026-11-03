# Running the simulations

Every simulation in this project is built and run with **Verilator**. This file
is the operational guide: what to install, what to type, and which failures are
real.

## Environment

**Run everything from WSL, not Git Bash and not PowerShell.** Verilator is
installed inside WSL only; the Windows shells have no `verilator` on `PATH`, and
the scripts are bash.

```bash
wsl
cd "/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agrasic/agriasic_digital_v2"
```

| Tool | Version here | Needed for |
|---|---|---|
| Verilator | 5.020 | every simulation and lint |
| `riscv64-unknown-elf-gcc` | 13.2 | rebuilding firmware (only if you edit `fw/`) |
| `python3` | — | firmware image generation, timing scripts |

Check your setup with `verilator --version`.

### Why the scripts build in `$HOME`, not in the repo

The repository path contains spaces (`UPENN SR FALL/SR DESIGN`). Verilator
generates a Makefile and hands it to `make`, and **make cannot handle spaces in
paths** — the build fails with confusing missing-target errors.

So every stage script copies the sources it needs into a space-free scratch
directory under `$HOME` (`~/agriasic_e2e`, `~/agriasic_smoke`, and so on), builds
there, and runs there. The directory is deleted and recreated on every run, so
nothing stale survives. This is why you will not find `obj_dir/` anywhere in the
repo, and why editing a file in `~/agriasic_*` accomplishes nothing — the next
run overwrites it.

## Run the whole suite

```bash
bash tb/rv32i_regression/verify_all.sh
```

Sixteen stages, roughly ten minutes. The last line is the one that matters:

```
VERIFY_ALL_PASS -- 16/16 stages passed all gates
```

Anything other than `VERIFY_ALL_PASS` is a failure, and the script exits
non-zero. Each failed stage prints the last eight lines of its own log under a
`### STAGE FAILED:` banner.

**Do not judge the run by grepping for `FAIL`.** Every stage script ends in a
pipeline (`<sim> 2>&1 | tail -30`), so its exit status is the status of `tail`,
which is almost always 0 — even when the simulation never built. That is why
each stage is gated three ways: it must produce output at all, exit 0, *and*
emit its expected pass token. The token is the load-bearing gate. A stage that
is killed outright produces no output, no `FAIL`, and a zero exit status, and
has in the past been misread as green. The header comment in
[`verify_all.sh`](verify_all.sh) documents the incident.

## Run one test

Each stage is a standalone script. Run any of them directly:

```bash
bash tb/rv32i_regression/e2e.sh
```

| # | Script | What it covers | Pass token |
|---|---|---|---|
| 1 | `lint_top.sh` | Full-chip lint, RV32I top | `=== top lint done ===` |
| 2 | `smoke.sh` | Measurement engine smoke test | `SMOKE_PASS` |
| 3 | `spi_smoke.sh` | SPI top smoke test | `SPI_TOP_SMOKE_PASS` |
| 4 | `sar_bit_trial.sh` | SAR bit-trial sequencing | `SAR_BIT_TRIAL_PASS` |
| 5 | `excitation_drive.sh` | Free-running phase generator | `EXCITATION_DRIVE_PASS` |
| 6 | `rst_sync_check.sh` | Reset synchronizer | `RST_SYNC_PASS` |
| 7 | `spi_domain_crossing.sh` | SPI clock-domain crossing | `SPI_DOMAIN_CROSSING_PASS` |
| 8 | `settle_check.sh` | Settle-path timing regression | `SETTLE_TIMING_PASS` |
| 9 | `e2e.sh` | **End-to-end: firmware drives the engine on Ibex** | `PASS -- all checks passed` |
| 10 | `lint_shell_orig.sh` | Descope fallback shell lint | `=== shell .orig lint done ===` |
| 11 | `accum_edge_cases.sh` | I/Q accumulator edge cases | `ACCUM_EDGE_PASS` |
| 12 | `settle_conv_sweep.sh` | settle × conv grid sweep | `SETTLE_CONV_SWEEP_PASS` |
| 13 | `jtag.sh` | JTAG → DTM → debug module | `JTAG_DEBUG_PASS` |
| 14 | `flash_boot.sh` | Golden ROM + SPI flash boot | `FLASH_BOOT_PASS` |
| 15 | `spi_host.sh` | Host SPI port, reads while the core runs | `SPI_HOST_PASS` |
| 16 | `abort_wake.sh` | Abort must wake firmware out of `wfi` | `ABORT_WAKE_PASS` |
| 17 | `boot_rom_e2e.sh` | **Power-up end to end, golden ROM boot: one reset → empty IMEM → sweep → park** | `ROM_BOOT_E2E_PASS` |
| 18 | `boot_flash_e2e.sh` | **Power-up end to end, SPI flash boot: one reset → empty IMEM → sweep → park** | `FLASH_BOOT_E2E_PASS` |

`e2e.sh` is the one to run if you only run one — it exercises the real firmware
against the real engine through the real bus. It preloads IMEM, though, so it
never boots. `boot_rom_e2e.sh` and `boot_flash_e2e.sh` are the same sweep
reached the way the chip reaches it -- one reset release, IMEM filled by the
boot FSM from the golden ROM or from SPI flash -- and are the two to show in a
demo (`tb/surfer/open_waves.ps1 rom` / `flash`).

Not part of the sweep, but useful:

| Script | Purpose |
|---|---|
| `flop_mem_e2e.sh` | Same end-to-end test built with `-DAGRIASIC_FLOP_MEM`, the flop-memory fallback instead of the default latch arrays |
| `lint_shell.sh`, `lint_baseline.sh` | Narrower lint targets |
| `build_riscv_tests.sh` | Builds the RISC-V ISA test programs |

## Compile, elaborate, run

Verilator does not separate these the way a commercial simulator does. A single
invocation with `--binary` elaborates the SystemVerilog, generates C++, compiles
it, and links a native executable. Running the simulation is then just running
that binary.

```
verilator --binary ...   # elaborate + generate C++ + compile + link
./obj_dir/sim_<name>     # run
```

- `--lint-only` stops after elaboration and checking — no C++, no binary. This
  is what the lint stages use.
- `-j 4` parallelises the **C++** compile, not the simulation.
- `-o sim_<name>` names the output binary, which always lands in `obj_dir/`.

### Building one by hand

The smallest self-contained example, matching [`smoke.sh`](smoke.sh). Sources
must be copied out of the repo first, for the spaces reason above:

```bash
BASE="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agrasic/agriasic_digital_v2"
W=~/my_smoke && rm -rf $W && mkdir -p $W && cd $W

cp "$BASE/tb/smoke/tb_agriasic_digital_top.sv" .
cp "$BASE/rtl/agriasic_digital_top.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" \
   "$BASE/rtl/ctrl/excitation_ctrl.sv" \
   "$BASE/rtl/ctrl/sar_controller.sv" .

# compile + elaborate + link
verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_agriasic_digital_top -o sim_smoke \
  tb_agriasic_digital_top.sv agriasic_digital_top.sv \
  measurement_fsm.sv excitation_ctrl.sv sar_controller.sv

# run
./obj_dir/sim_smoke
```

`--timing` is required: the testbenches use delays and event controls that
Verilator will not accept otherwise.

Full-chip builds (`e2e`, `jtag`, `flash_boot`, `spi_host`, `boot_rom_e2e`, `boot_flash_e2e`) additionally need the
vendored Ibex core and RISC-V debug module staged with their include paths and
lint waivers. That is what [`ibex_sources.sh`](ibex_sources.sh) does — source it
and use `$IBEX_ARGS` and `$AGRIASIC_RV32I_SOURCES` rather than assembling the
file list yourself. The order in `ibex.f` and `riscv_dbg.f` is lint-proven; do
not reorder it.

## Waveforms

Off by default, because tracing costs real time on the longer stages. Opt in per
run:

```bash
WAVES=1 bash tb/rv32i_regression/e2e.sh
```

The file lands in `waves/<stage>.fst`. Knobs, all optional:

| Variable | Default | Effect |
|---|---|---|
| `WAVE_FORMAT` | `fst` | `vcd` if you need to read it as text; several times larger |
| `WAVE_START` | 0 | Start dumping at this sim time in ns — use it to skip boot |
| `WAVE_DEPTH` | all | Hierarchy levels below the top to trace |
| `WAVE_DIR` | `<repo>/waves` | Where files land |

Two Verilator 5.020 limitations, both measured rather than assumed, are why the
knobs look like this: `$dumpvars`' scope and level arguments are **ignored**
(`$dumpvars(0, top.dut)` dumps the whole design), so narrowing is done with
`WAVE_DEPTH` instead; and `$dumpoff`/`$dumpon` are **ignored**, so a dump window
can be opened but not closed — hence `WAVE_START` works by delaying the dump and
there is deliberately no `WAVE_STOP`.

To view, from PowerShell on the Windows side:

```powershell
tb\surfer\open_waves.ps1
```

Surfer is not installed inside WSL; open FST files from Windows.

## Lint only

```bash
bash tb/rv32i_regression/lint_top.sh
```

Lint passes on silence. The only expected output is the `=== top lint done ===`
marker — that marker exists precisely so "no output" cannot be confused with
"script never ran."

## Rebuilding firmware

Only needed if you edit `fw/fw.c`, `fw/start.S` or `fw/link.ld`. The checked-in
`fw/agriasic_fw.hex` is what the simulations load.

```bash
bash fw/build.sh
```

This emits `agriasic_fw.hex`, the linker map, stack-usage reports and the flash
image, and runs the ELF address report. If you change memory sizes, `link.ld`'s
`LENGTH` values and `IMEM_WORDS`/`DMEM_WORDS` in
`rtl/agriasic_rv32i_control_shell.sv` must move together — the linker has
`ASSERT`s that will catch most mismatches at build time.

## Known failures

**`%Error: Internal Error: attempted to destroy locked Thread Pool`**

A bug in Verilator 5.020's own `-j 4` thread pool, not a problem with the
design. It fires before anything is compiled, is intermittent, and the same
stage passes on a re-run. If a single stage fails this way inside
`verify_all.sh`, re-run that stage alone to confirm:

```bash
bash tb/rv32i_regression/settle_check.sh
```

**`BUILD FAILED` with make errors about missing targets** — you are almost
certainly building somewhere with a space in the path. Build under `$HOME`.

**A stage produces no output at all** — the process was killed rather than
failing. WSL does this occasionally with `Wsl/Service/0x80072746`. Re-run it.

**Empty or missing waveform** — `wave_report` warns when `WAVES=1` produced no
file. Usually the build failed before the simulation ran; check the stage's own
output first.

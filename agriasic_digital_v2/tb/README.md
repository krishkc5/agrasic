# Running a testbench: compile, elaborate, run, open waves

This walks through the power-up end-to-end demo, which comes in two boot types
built from one testbench, [`tb_agriasic_boot_e2e.sv`](tb_agriasic_boot_e2e.sv):

| Boot type | Script | Waveform | Pass line |
|---|---|---|---|
| Golden ROM | `tb/rv32i_regression/boot_rom_e2e.sh` | `waves/boot_rom_e2e.fst` | `[TB] ROM_BOOT_E2E_PASS` |
| SPI flash | `tb/rv32i_regression/boot_flash_e2e.sh` | `waves/boot_flash_e2e.fst` | `[TB] FLASH_BOOT_E2E_PASS` |

Each one is a single reset release with IMEM starting **empty**. The boot FSM
fills IMEM (from the on-die ROM, or from a behavioural SPI NOR over SPI), the
core is released, and the firmware runs the full 8-point sweep to FW_DONE and
parks in `wfi`. The bench checks every IMEM write, the IMEM contents, the
results in DMEM and the sleep behaviour; see its header for the full list.

The same steps work for every other stage; the table at the end lists the
ones with Surfer views. For the whole regression, the knobs and the known
failures, see [`rv32i_regression/README.md`](rv32i_regression/README.md).

## Prerequisites

| Tool | Where | Version here |
|---|---|---|
| Verilator | WSL (Ubuntu) only | 5.020 |
| Surfer | Windows, `%LOCALAPPDATA%\Programs\Surfer\surfer.exe` | 0.7.0 |

Build and run in **WSL**; open waveforms from **Windows** (Surfer is not
installed in WSL). The repo is the same folder from both sides:

```bash
cd "/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agrasic/agriasic_digital_v2"
```

## The short way: one command per boot type

From the repo root in WSL:

```bash
WAVES=1 bash tb/rv32i_regression/boot_rom_e2e.sh
WAVES=1 bash tb/rv32i_regression/boot_flash_e2e.sh
```

Each takes about 2.5 minutes and does all four steps below: stages the sources,
elaborates and compiles with Verilator, runs the simulation, and writes the
waveform. A good run ends like this (ROM shown):

```
[TB] BOOT: finished in 153 cycles, state=7 err=0
[TB] BOOT: 148 words written to IMEM, cycles 4..151 after reset
[TB] RUN: firmware reached FW_DONE after 4568202 cycles (16 measurements)
[TB] RUN: core asleep in wfi for 4566218 cycles during the sweep
[TB] PARK: core_sleep high 2000 of 2000 cycles after FW_DONE
[TB] ROM_BOOT_E2E_PASS -- all checks passed
[waves] 66M -> .../waves/boot_rom_e2e.fst
```

Leave out `WAVES=1` to run the checks without writing a waveform. Every check
prints its own `... OK` line above these; any failure prints `%Error` and the
last line becomes `ROM_BOOT_E2E_FAIL -- N error(s)`.

## The long way: each step by hand

Verilator does not split compile and elaborate into separate tools the way a
commercial simulator does (`xvlog` / `xelab` / `xsim`, or `vlog` / `vsim`).
One `verilator --binary` call parses and elaborates the SystemVerilog,
generates C++, compiles it and links an executable; running the simulation is
running that executable. `--lint-only` stops after elaboration, which is the
closest thing to an elaborate-only step.

Measured for the ROM boot: staging ~15 s, elaboration ~10 s, compile ~1 min,
run ~1.5 min with waves on.

### 1. Stage the sources

The repo path has spaces, and Verilator's generated Makefile cannot handle
them, so everything is copied into a space-free work directory first:

```bash
BASE="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agrasic/agriasic_digital_v2"
W=~/boot_demo && rm -rf $W && mkdir -p $W && cd $W

source "$BASE/tb/rv32i_regression/ibex_sources.sh"   # sets AGRIASIC_RV32I_SOURCES
source "$BASE/tb/rv32i_regression/waves.sh"          # defines wave_setup

cp "$BASE/tb/tb_agriasic_boot_e2e.sv" "$BASE/tb/tb_spi_flash_model.sv" .
cp "$BASE/fw/golden/agriasic_fw_golden.hex" "$BASE/fw/agriasic_fw_flash.hex" .
cp "$BASE/rtl/"*.sv "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/"{agriasic_imem,agriasic_dmem,agriasic_rv32i_mmio,agriasic_rv32i_bus,agriasic_spi_boot,agriasic_boot_rom,agriasic_spi_host}.sv .
stage_ibex                                            # copies Ibex + debug module, sets IBEX_ARGS
```

`fw/golden/agriasic_fw_golden.hex` is the image the ROM was generated from
(the bench compares IMEM against it); `fw/agriasic_fw_flash.hex` is what the
flash model holds.

### 2. Elaborate (check only, no binary)

```bash
verilator --lint-only --timing -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY \
  --top-module tb_agriasic_boot_e2e -GBOOT_FROM_FLASH=0 \
  $IBEX_ARGS tb_agriasic_boot_e2e.sv tb_spi_flash_model.sv $AGRIASIC_RV32I_SOURCES
```

`-GBOOT_FROM_FLASH=0` picks the boot type: `0` for the golden ROM, `1` for SPI
flash. It is a top-level parameter, so it is fixed at elaboration -- each boot
type is its own build. A clean elaboration prints nothing; both boot types
currently do.

### 3. Compile

```bash
export WAVES=1
wave_setup tb_agriasic_boot_e2e boot_rom_e2e          # sets WAVE_ARGS; writes wave_dump.sv

verilator $WAVE_ARGS --binary --timing --assert -j 4 -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_agriasic_boot_e2e -GBOOT_FROM_FLASH=0 -o sim_boot_rom \
  $IBEX_ARGS tb_agriasic_boot_e2e.sv tb_spi_flash_model.sv $AGRIASIC_RV32I_SOURCES
```

`wave_setup` is what `WAVES=1` turns on in the scripts: it generates a small
`wave_dump` module that is `bind`ed into the testbench top, so the testbench
itself has no `$dumpfile` in it. Skip the two `wave_setup` lines (and leave
`$WAVE_ARGS` empty) to build without tracing. `-j 4` parallelises the C++
compile, not the simulation. The binary lands in `obj_dir/`.

### 4. Run

```bash
./obj_dir/sim_boot_rom
```

The waveform is written to `$BASE/waves/boot_rom_e2e.fst` as the sim runs.

**For the SPI flash boot**, repeat steps 3 and 4 with `boot_flash_e2e`,
`-GBOOT_FROM_FLASH=1` and `-o sim_boot_flash`. Use a fresh work directory (or
rerun `wave_setup` first), because `wave_dump.sv` holds the output file name.

## Open the waves

From **PowerShell** on Windows, in the repo root.

### Saved views (signals, markers and zoom)

`tb/surfer` holds a Surfer state file for each boot type. It loads the
waveform, the 51 signals in 8 sections, named markers on the milestones, and a
zoom on the boot:

```powershell
& "$env:LOCALAPPDATA\Programs\Surfer\surfer.exe" -s "tb\surfer\boot_rom_e2e.surf.ron"
& "$env:LOCALAPPDATA\Programs\Surfer\surfer.exe" -s "tb\surfer\boot_flash_e2e.surf.ron"
```

Or, inside Surfer: **File → Load state…**, then paste
`C:\Users\taara\UPENN SR FALL\SR DESIGN\agrasic\agriasic_digital_v2\tb\surfer`
into the dialog's address bar and pick the `.surf.ron` file. Load state lists
only `.surf.ron` files.

A state file points at its waveform by full path, so it keeps working after you
rerun the sim. Only the marker times would move, and only if the firmware
changes.

### Signal list only

```powershell
.\tb\surfer\open_waves.ps1 rom
.\tb\surfer\open_waves.ps1 flash
```

This opens the trace with [`surfer/boot_e2e.surfer`](surfer/boot_e2e.surfer),
the same 51 signals, at full zoom and without markers. One list serves both
traces because the hierarchy is identical. Inside a Surfer window that is
already open, **File → Run command file…** loads a `.surfer` list onto
whatever trace is showing.

### Moving around

Press **Space** in Surfer to open its command prompt, then for example:

```
goto_marker boot_done
cursor_set 125
zoom_fit
```

To keep a view you have arranged, use **File → Save state as…**.

### What to look for

Times in ns; the clock is 10 ns.

| Milestone | ROM boot | Flash boot | Signals |
|---|---|---|---|
| Reset released | 95 | 95 | `rst_n` |
| Boot starts | 125: `state_q` = 10 (ROM) | 755: `state_q` = 1 (CMD), flash `cs_n` low | `u_boot.state_q`, `2_flash_spi` |
| Header read | -- | 5,955 – 26,755 | `state_q` = 2 |
| Image into IMEM | 125 – 1,605, one word per cycle | 26,755 – 797,845, one word per 4 SPI bytes | `3_image_to_imem` |
| Boot done, `fw_valid` | 1,615 | 797,855 (after the CRC check) | `fw_valid`, `boot_status` |
| Core out of reset | 1,625 | 797,865 | `core_rst_n`, `instr_addr` |
| FW_DONE, park | 45,683,665 | 46,479,905 | `fw_done`, `core_sleep` |

`boot_status[13:12]` reads 1 for a ROM boot and 2 for a flash boot. Both
traces start with `core_rst_n` high for the first 5 ns; that is the control
shell giving Ibex a real reset edge in simulation (see
`agriasic_rv32i_control_shell.sv`), not a second reset.

## Other stages with Surfer views

| Stage | Waveform | Open with | Notes |
|---|---|---|---|
| `e2e.sh` | `waves/e2e.fst` | `open_waves.ps1 e2e` | IMEM preloaded with `$readmemh`, so no boot copy |
| `flash_boot.sh` | `waves/flash_boot.fst` | `open_waves.ps1 boot` | Seven boot scenarios (good image, CRC fail, blank flash, ROM, strap override) with five resets |
| `smoke.sh` | `waves/smoke.fst` | `open_waves.ps1 detail` | Measurement engine alone, no core |
| `jtag.sh` | `waves/jtag.fst` | `open_waves.ps1 jtag` | Debug module: halt, registers, SBA, resume |

Each is generated the same way: `WAVES=1 bash tb/rv32i_regression/<stage>.sh`.

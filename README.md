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
in firmware. Excitation polarity, settle qualification, conversion trigger and
accumulation stay in the measurement FSM, which matters for two reasons:

- **Jitter is measurement noise.** The conversion fires a fixed number of cycles
  after the polarity flip, partway up the analog settling curve. If that instant
  moved with instruction timing, the ADC code would move with it — noise
  indistinguishable from signal.
- **The ± chop needs time symmetry.** `(D+ − D−)/2` cancels offset and drift only
  if both phases are timed identically. The FSM gives that structurally.

An entire measurement is ~46 clock cycles, so software could not keep up anyway.
The core is held in reset between measurements, which is also the low-power state
for a solar/battery node.

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

---

## Toolchain

| Tool | Used for |
| --- | --- |
| Verilator 5.x | lint and simulation |
| `riscv64-unknown-elf-gcc` | firmware |
| cocotb 1.9.x + riscv-tests | processor ISA regression only |

On Windows, run these under WSL. On Ubuntu 24.04:

```bash
sudo apt install -y verilator gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
                    build-essential python3.12-venv python3-pip
```

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
| Processor — rv32ui ISA suite + dhrystone | 77/77 |
| Measurement smoke (`tb_agriasic_digital_top`) | pass, result = 240 |
| SPI smoke (`tb_agriasic_digital_spi_top`) | pass, result = 240 |
| End-to-end firmware + measurement | pass |
| Full chip lint | clean except pre-existing width warnings in `measurement_fsm.sv` |

---

## Known open items

- **`docs/interface_contract.md` is out of date.** It predates three SPI changes:
  `STATUS[1]` (done) is now sticky rather than a one-cycle pulse; a read
  transaction now consumes its dummy byte; MISO now changes on the falling SCLK
  edge per mode 0. Do not write host firmware from that document until it is
  refreshed.
- **Regression scripts contain absolute paths** under `tb/rv32i_regression/`.
  They need parameterizing before they will run on another machine.
- **Shell status outputs are unconnected** in `agriasic_digital_rv32i_top.sv`
  (`shell_busy`, `shell_done`, `shell_result`, `shell_clear_errors`). Open
  question which is authoritative for an external host.
- **No foundry SRAM macro yet.** `agriasic_imem` / `agriasic_dmem` are behavioral
  models carrying the correct timing contract, with an
  `AGRIASIC_USE_SRAM_MACRO` ifdef for dropping in memory-compiler output.
- **Reference traces not regenerated** for the synchronous-SRAM core, so
  cycle-level trace comparison is unavailable.

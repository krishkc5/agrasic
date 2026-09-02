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
  rv32i/
    agriasic_rv32i_core.sv             5-stage pipelined RV32IM datapath
    agriasic_imem.sv                   instruction ROM, synchronous-SRAM contract
    agriasic_dmem.sv                   scratch RAM, synchronous-SRAM contract
    agriasic_rv32i_mmio.sv             bus decode + peripheral registers
    agriasic_rv32i_cla.sv              carry-lookahead adder
    agriasic_rv32i_divider.sv          pipelined divider
fw/                                    firmware: fw.c, start.S, link.ld, build.sh
tb/
  smoke/                               measurement and SPI smoke tests
  tb_agriasic_rv32i_e2e.sv             end-to-end: firmware drives the FSM
  rv32i_regression/                    lint, smoke, e2e and ISA regression scripts
docs/                                  MAS, interface contract, plans, diagrams
```

## Processor provenance

The core is the 5-stage pipelined RV32IM datapath from CIS 5710 (hw5), with the
carry-lookahead adder from hw2b and the pipelined divider from hw4. The M
extension was kept deliberately: the verified implementation was worth more than
the area saved, and the firmware's averaging step emits a `div`.

It was retargeted from FPGA-style memory to synchronous SRAM, which is the only
substantive change to the datapath:

- the instruction SRAM's output register now serves as the fetch/decode pipeline
  register, so `stage_decode_t` carries a validity flag instead of the instruction
- load byte-extraction moved from Memory to Writeback, where the SRAM returns data
- M→X forwarding of load data was removed, and the load-use stall widened to cover
  a load in Memory (2 stall cycles at distance 1, 1 at distance 2)
- a WM bypass was added so a load in Writeback can feed a store in Memory

## Memory map (data side)

| Address | Register | Access |
| --- | --- | --- |
| `0x0000_0000`–`0x0000_07FF` | scratch RAM (stack grows down from `0x800`) | RW |
| `0x8000_0000` | CTRL — bit0 start, bit7 clear sticky errors | W |
| `0x8000_0004` | PAIR_LOG2 | RW |
| `0x8000_0008` | SETTLE | RW |
| `0x8000_000C` | DIVIDER | RW |
| `0x8000_0010` | CONV | RW |
| `0x8000_0014` | STATUS — bit0 busy, bit1 done | R |
| `0x8000_0018` | RESULT (sign-extended) | R |

Instruction and data are **separate address spaces** (Harvard). Anything the
linker places in ROM is unreachable by a load, so firmware carries no `.rodata`,
`.data` or `.bss` — `fw/link.ld` enforces this with build-time asserts.

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

Requires Verilator 5.x and `riscv64-unknown-elf-gcc`. The 77-test processor ISA
regression additionally needs the CIS 5710 cocotb harness and a built
`riscv-tests`; those scripts are in `tb/rv32i_regression/`.

Files ending in `.orig` are pre-fix snapshots. The smoke comparison scripts build
against them deliberately, to show the failure each fix removes.

# AgriASIC Digital RTL Skeleton

This directory contains the digital-design implementation skeleton for the single-die impedance sensing node.

## Scope
- Excitation digital control (frequency divider, polarity, settle timer)
- SAR control sequencing
- Measurement sequencing FSM (fallback path)
- SPI slave + register map
- Optional controller integration hook (RISC-V/SERV)
- Optional programming wrapper for an RV32I controller variant with ROM

## Structure
- `rtl/`: synthesizable RTL modules
- `tb/smoke/`: basic smoke testbench
- `docs/`: digital interfaces and implementation notes

## Bring-up order
1. `measurement_fsm.sv`
2. `spi_slave.sv` + `regfile.sv`
3. `excitation_ctrl.sv` + `sar_controller.sv`
4. `agriasic_digital_top.sv` integration
5. `agriasic_digital_programming_top.sv` for the firmware-driven programming path
6. `agriasic_rv32i_control_shell.sv` + `agriasic_digital_rv32i_top.sv` for the RV32I reference path
7. smoke regression in `tb/smoke`

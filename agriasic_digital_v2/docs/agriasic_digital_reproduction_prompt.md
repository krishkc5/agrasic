# Reproduction Prompt: AgriASIC Digital Design (Current State)

Use this prompt with an engineering assistant to reproduce the digital-design work completed so far.

---

## Prompt To Reuse

You are continuing a mixed-signal digital-integration effort for the AgriASIC single-die impedance sensing node.
Your task is to recreate the current digital implementation, documentation, and diagram set exactly as described below.

### 1) Objective
Reproduce a functional digital control subsystem with:
- Autonomous measurement sequencing
- Excitation/SAR handshake orchestration
- SPI-controlled register interface
- Deterministic SPI protocol with explicit ACK/NACK/error codes
- Sticky protocol-error observability and software clear path
- Smoke-level testbenches (nominal + error-path checks)
- MAS and implementation documentation with chapter-aligned diagrams
- Phase-locked measurement FSM with RV32I + ROM policy control over the inner loop

### 2) Workspace and location requirements
Assume Linux workspace root:
- /nfs/site/disks/refsoc_00015/jammula/hac-srvrgen4.vscode2

All AgriASIC digital collateral must be under:
- src/rtl/agriasic_digital/

Documentation root (current location):
- src/rtl/agriasic_digital/docs/

Important: older references may still mention doc/TJ_SD or src/rtl/docs/TJ_SD. Normalize to src/rtl/agriasic_digital/docs.

### 3) Required RTL files and responsibilities
Recreate and/or verify these files and behaviors:

1. src/rtl/agriasic_digital/rtl/agriasic_digital_top.sv
- Integrates measurement_fsm + excitation_ctrl + sar_controller.
- Wires handshake signals for phase-settle-sample loop.

2. src/rtl/agriasic_digital/rtl/ctrl/measurement_fsm.sv
- Implements sequencer states:
  - IDLE, SETTLE_P, SAMPLE_P, SETTLE_N, SAMPLE_N, ACCUM, LOOP, DONE
- Executes paired sampling and accumulation:
  - contribution = (D+ - D-) / 2
- Iterates for M pairs where M = 2^pair_log2.

3. src/rtl/agriasic_digital/rtl/ctrl/excitation_ctrl.sv
- Polarity update path via set_phase and phase_value.
- Divider tick generation via cfg_divider.
- Settle counter and settled indication via cfg_settle.

4. src/rtl/agriasic_digital/rtl/ctrl/sar_controller.sv
- Accepts sample request when idle.
- Generates one-cycle conv_start.
- Waits conversion latency cfg_conv.
- Captures ADC data into D+ or D- by sample phase.
- Emits sample_done pulse.

5. src/rtl/agriasic_digital/rtl/ctrl/spi_slave.sv
- SPI mode-0 (CPOL=0, CPHA=0).
- Byte completion in SCLK domain.
- CDC into core clock with toggle synchronizer.
- One rx_valid pulse per completed byte.

6. src/rtl/agriasic_digital/rtl/ctrl/regfile.sv
- Parameterized register file with sync write and async read.

7. src/rtl/agriasic_digital/rtl/agriasic_digital_spi_top.sv
- Integrates spi_slave + regfile + agriasic_digital_top.
- Implements fixed 2-byte SPI command protocol.
- Implements strict command checks and responses:
  - ACK = 0xA5
  - NACK = 0x5A (e.g., write to read-only)
  - ERR_INV_CMD = 0xE1 (reserved bits non-zero)
  - ERR_BAD_ADDR = 0xE2 (invalid address)
- Includes byte-alignment recovery:
  - If Byte0 illegal, consume/discard Byte1 before next command decode.
- Maintains sticky protocol flags in STATUS bits [7:5].
- Clears sticky flags when CTRL bit7 is written as 1.

8. Phase-locked RV32I controller architecture collateral
- The final architecture promotes the measurement FSM to a permanent timing block and makes the excitation generator free-running.
- Reference RTL entrypoints: `agriasic_rv32i_control_shell.sv` and `agriasic_digital_rv32i_top.sv`.
- The measurement FSM remains the real-time timing engine for excitation, settle, sample, and accumulation.
- The core acts as a policy layer: sweep program, settle intervals, M and frequency selection, temperature read, result packing, and SPI service.
- Use a small ROM for program memory and keep the core clock-enabled off during accumulation bursts.
- Keep the SPI wrapper as the host control/debug ingress.

### 4) Register map and protocol expectations
Implement/verify these registers in SPI wrapper:
- 0x0 REG_CTRL (RW):
  - bit0 = start pulse
  - bit7 = clear sticky protocol flags
- 0x1 REG_PAIR_LOG2 (RW)
- 0x2 REG_SETTLE (RW)
- 0x3 REG_DIVIDER (RW)
- 0x4 REG_CONV (RW)
- 0x5 REG_STATUS (RO):
  - bit7 protocol_err
  - bit6 bad_addr
  - bit5 illegal_write_to_ro
  - bit1 done
  - bit0 busy
- 0x6 REG_RESULT_LO (RO)
- 0x7 REG_RESULT_HI (RO)

SPI command format:
- bit7 = RW (1=read, 0=write)
- bit6:3 = register address
- bit2:0 = reserved (must be 000)

### 5) Testbench requirements
Recreate/verify these smoke tests:

1. src/rtl/agriasic_digital/tb/smoke/tb_agriasic_digital_top.sv
- Basic start-to-done smoke flow.
- Self-check expected deterministic result path.

2. src/rtl/agriasic_digital/tb/smoke/tb_agriasic_digital_spi_top.sv
- SPI write/read tasks.
- Nominal config programming and run trigger.
- Status/result readback checks.
- Negative-path checks:
  - Invalid command reserved bits -> protocol flag set
  - Invalid address -> bad_addr flag set
  - Illegal write to RO register -> illegal_write flag set
  - Clear sticky flags through CTRL[7]
- Include basic assertions:
  - conv_start_o is single-cycle pulse
  - done_o and busy_o not simultaneously high

### 6) Documentation required
Recreate/verify these docs under src/rtl/agriasic_digital/docs:

1. agriasic_digital_implementation_plan.md
- Digital goals
- Scope and phases
- Risks/controls
- Deliverables

2. agriasic_digital_timing_checklist.md
- Sequencer timing steps
- Excitation and SAR timing contracts
- SPI protocol timing and framing
- Pass criteria for quick and nominal profiles

3. interface_contract.md
- External and internal interface definitions
- SPI mode/command protocol/response semantics
- Register map and status bits

4. agriasic_digital_MAS.md
- Detailed introduction chapter
- Requirement trace matrix
- Module-level micro-architecture
- Register/protocol specification
- Reset/error policy
- Verification and acceptance criteria
- Diagram placement in relevant chapters (not one bulk section)
- RV32I controller architecture subsection and diagram, linked to the RV32I control shell and RV32I top entrypoints

### 7) Diagram assets required
Ensure these SVG files exist and are linked from MAS in relevant chapters:

System/flow diagrams:
- src/rtl/agriasic_digital/docs/diagrams/agriasic_digital_dataflow_hl.svg
- src/rtl/agriasic_digital/docs/diagrams/agriasic_digital_verilog_orchestration_flow.svg
- src/rtl/agriasic_digital/docs/diagrams/agriasic_measurement_fsm_cycle_flow.svg

Controller architecture diagram:
- src/rtl/agriasic_digital/docs/diagrams/modules/agriasic_rv32i_control_architecture.svg

Module diagrams:
- src/rtl/agriasic_digital/docs/diagrams/modules/agriasic_digital_top_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/measurement_fsm_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/excitation_ctrl_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/sar_controller_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/spi_slave_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/regfile_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/agriasic_digital_spi_top_block_diagram.svg
- src/rtl/agriasic_digital/docs/diagrams/modules/agriasic_digital_spi_protocol_flow.svg

Slide set:
- src/rtl/agriasic_digital/docs/slides_svg/01_title_and_objective.svg
- src/rtl/agriasic_digital/docs/slides_svg/02_requirements_and_scope.svg
- src/rtl/agriasic_digital/docs/slides_svg/03_system_architecture.svg
- src/rtl/agriasic_digital/docs/slides_svg/04_measurement_sequence_timing.svg
- src/rtl/agriasic_digital/docs/slides_svg/05_spi_protocol_and_register_map.svg
- src/rtl/agriasic_digital/docs/slides_svg/06_rtl_module_decomposition.svg
- src/rtl/agriasic_digital/docs/slides_svg/07_verification_and_risk.svg
- src/rtl/agriasic_digital/docs/slides_svg/08_schedule_and_descope.svg
- src/rtl/agriasic_digital/docs/slides_svg/README.md

### 8) Acceptance checklist
A reproduction is complete only if:
- RTL files compile cleanly with no editor diagnostics.
- SPI wrapper contains strict ACK/NACK/error behavior and Byte1 discard recovery.
- Negative-path SPI smoke TB checks pass (or are ready with deterministic checks if simulator unavailable).
- MAS includes detailed intro chapter and chapter-wise diagram placement.
- MAS includes the phase-locked control partition, its diagram, and the explicit RV32I RTL entrypoints.
- All paths in docs point to current location under src/rtl/agriasic_digital/docs.

### 9) Constraints
- Keep edits minimal and scoped.
- Do not remove existing functional behavior.
- Preserve fallback FSM-centric flow.
- Prefer deterministic protocol behavior over permissive handling.
- Keep the RV32I core small and policy-oriented; do not move hard real-time timing into software.

### 10) Deliverables summary
At the end, provide:
1. List of files created/updated.
2. Validation status (diagnostics and, if available, smoke simulation summary).
3. Any residual risks/gaps (for example simulator not available in PATH).

---

## Notes for human handoff
- This prompt is intentionally explicit so a new engineer can continue with low ambiguity.
- If project structure changes, update all path references first before logic changes.

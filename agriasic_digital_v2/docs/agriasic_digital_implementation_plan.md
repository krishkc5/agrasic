# AgriASIC Digital Design Implementation Plan

## Purpose
This document defines the digital implementation track for the single-die impedance sensing node described in the high-level design.

## Digital goals
1. Deliver autonomous on-die measurement sequencing so the host is optional.
2. Harden a digital macro through the automated RTL-to-GDS flow within the schedule.
3. Keep the measurement FSM as the permanent inner-loop timing engine while the core handles sweep policy.
4. Ensure clean digital/analog contracts for excitation timing, SAR conversion control, raw accumulation, and result handoff.

## In-scope digital blocks
- Measurement FSM (mandatory permanent timing engine)
- Excitation digital controller (free-running divider, phase counter, settle controls)
- SAR conversion controller
- SPI slave interface
- Register map, status/control plane, and indexed result readout
- RV32I + ROM policy/control shell for sweep and host management

## Out-of-scope for first implementation
- New CPU architectural features beyond stripped control needs
- Additional sensor channels/muxing
- Higher-resolution ADC control paths beyond current 8-bit assumptions
- Non-essential debug fabric that risks schedule

## Repository skeleton
- src/rtl/agriasic_digital/rtl/agriasic_digital_top.sv
- src/rtl/agriasic_digital/rtl/ctrl/measurement_fsm.sv
- src/rtl/agriasic_digital/rtl/ctrl/excitation_ctrl.sv
- src/rtl/agriasic_digital/rtl/ctrl/sar_controller.sv
- src/rtl/agriasic_digital/rtl/ctrl/spi_slave.sv
- src/rtl/agriasic_digital/rtl/ctrl/regfile.sv
- src/rtl/agriasic_digital/tb/smoke/tb_agriasic_digital_top.sv
- src/rtl/agriasic_digital/docs/interface_contract.md

## Execution phases

### Phase 0 (Week 1): Feasibility lock
- Confirm memory strategy constraints (ROM/data memory assumptions for digital control path).
- Run area estimate checkpoint for controller path and freeze go/no-go criteria.
- Freeze digital interface contract:
  - SPI transaction format and mode
  - start/busy/done behavior
  - excitation/SAR timing handshake
  - reset behavior across all blocks

Exit criteria:
- Interface contract reviewed and signed across digital and analog owners.
- Controller strategy selected with explicit fallback trigger.

### Phase 1 (Weeks 2-3): Functional baseline
- Finish measurement FSM end-to-end sequence.
- Implement control registers required for one complete measurement cycle.
- Wire excitation and SAR stubs to top-level behavior.
- Build and run smoke simulation for reset/start/result path.

Exit criteria:
- Smoke test passes with deterministic result behavior.
- Register writes influence measurement flow in simulation.

### Phase 2 (Week 4): Scope gate
- Freeze feature set; do not add optional functionality after gate.
- Decide controller path:
  - keep stripped core integration track, or
  - lock FSM-only track for tapeout schedule safety.

Exit criteria:
- Feature freeze documented.
- Fallback plan validated and runnable.

### Phase 3 (Weeks 5-8): Integration hardening
- Add assertions and error-path tests:
  - illegal command handling
  - reset during busy
  - start pulse filtering/re-entrance policy
- Refine SPI/regfile protocol behavior.
- Expand mixed-signal interaction checks at digital boundaries.

Exit criteria:
- Regression passes for protocol and reset-safety tests.
- No unresolved contract ambiguity at analog interfaces.

### Phase 4 (Weeks 9-11): Closure and release
- Finalize timing constraints and integration artifacts for flow handoff.
- Run final regression set and archive logs/waves/reports.
- Prepare digital release package for trial GDS deliverables.

Exit criteria:
- Hardened digital macro evidence package complete.
- FSM-only fallback build also passes and is archived.

## Immediate task backlog
1. Define register bitfield spec in interface_contract.md.
2. Add explicit measurement sequence counters/timers in measurement_fsm.sv.
3. Replace placeholder SAR data path behavior with conversion-complete handshake.
4. Define SPI framing and map read/write commands to regfile accesses.
5. Add a self-checking smoke test with pass/fail assertions.

## Risks and controls
- Risk: schedule overrun due to optional core work.
  - Control: FSM-first completion and Week 4 hard gate.
- Risk: interface churn between analog and digital.
  - Control: signed interface contract in Week 1 and change control afterward.
- Risk: reset/handshake corner-case escapes.
  - Control: mandatory reset-stress and illegal-sequence regressions.

## Deliverables
- Synthesizable RTL skeleton and iterative implementation
- Smoke and regression testbench collateral
- Interface contract and register specification
- Digital integration checklist for top-level bring-up

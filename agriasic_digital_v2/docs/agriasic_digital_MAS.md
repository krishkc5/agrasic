# AgriASIC Digital MAS (Micro-Architecture Specification)

## 1. Document Control
- Project: Single-Die Impedance Sensing Node
- Subsystem: Digital control, sequencing, and SPI control plane
- Basis documents:
  - agriasic_high_level_design_rev4_integrated_node.md
  - agriasic_digital_implementation_plan.md
  - agriasic_digital_timing_checklist.md
  - interface_contract.md
- MAS version: v0.1 (initial requirements-based draft)
- Date: 2026-09-01

## 2. Purpose and Scope
This MAS defines the digital micro-architecture for measurement sequencing, excitation/SAR handshake control, result accumulation, and SPI-visible status/control behavior. It captures both implemented behavior and requirement-driven acceptance criteria.

In scope:
- measurement_fsm, excitation_ctrl, sar_controller
- SPI slave and SPI protocol wrapper behavior
- register map, status/error semantics, and protocol framing
- reset, busy/done, and result observability contracts

Out of scope for this MAS revision:
- analog circuit implementation details
- multi-channel muxing
- on-die excitation amplitude DAC
- post-silicon calibration algorithm optimization

## 3. Introduction: Detailed Design Functionality
This design implements a complete digital measurement-control subsystem for a single-die impedance sensing node. It allows software (or a host over SPI) to configure timing parameters, trigger an autonomous measurement run, and read back status and result data with deterministic protocol behavior.

### 3.1 End-to-end functional flow
1. Host writes configuration registers through SPI:
- Pair count (`REG_PAIR_LOG2`)
- Excitation settle timing (`REG_SETTLE`)
- Excitation divider (`REG_DIVIDER`)
- SAR conversion latency (`REG_CONV`)
2. Host issues start via `REG_CTRL[0]`.
3. Sequencer enters autonomous run:
- Set positive excitation phase and wait for settle
- Request SAR conversion and capture D+
- Set negative excitation phase and wait for settle
- Request SAR conversion and capture D-
- Compute signed contribution and accumulate result
4. Sequence repeats for `M = 2^pair_log2` pairs.
5. Result is finalized and exposed through `REG_RESULT_HI/LO`; `done` indication is visible in `REG_STATUS`.

### 3.2 Internal block cooperation
- `measurement_fsm` controls the phase/sample/accumulation loop.
- `excitation_ctrl` guarantees polarity updates and settle completion indication.
- `sar_controller` translates sample requests into conversion start and completion/capture events.
- `agriasic_digital_spi_top` manages software-facing protocol decode, legality checks, and response generation.
- `regfile` holds configuration state and mirrors status/result bytes for host visibility.

### 3.3 SPI-facing functionality
The SPI wrapper implements fixed 2-byte transactions:
- Byte0 carries command (`RW`, address, reserved bits).
- Byte1 carries payload (write) or dummy clocks (read).

For robust debug and deterministic recovery:
- Valid writes return ACK (`0xA5`).
- Rejected writes (for example to read-only registers) return NACK (`0x5A`).
- Invalid command and address conditions return explicit error codes (`0xE1`, `0xE2`).
- Illegal command framing still consumes Byte1 to maintain parser alignment.
- Sticky protocol flags in `REG_STATUS[7:5]` preserve error context until software clears them using `REG_CTRL[7]`.

### 3.4 Operating model and intent
The design is intended to run measurements autonomously after start, with host interaction limited to:
- Setup/configuration
- Monitoring (`busy`/`done` and error flags)
- Reading accumulated result

This minimizes control overhead per sample and keeps a clear fallback path (`measurement_fsm`-centered operation) even if optional future controller paths are deferred.

### 3.5 Optional RV32I controller variant
If programming flexibility is needed, the architecture can be extended with a small RV32I controller that sits above the existing measurement engine.

Reference RTL entrypoints for this variant:
- [src/rtl/agriasic_digital/rtl/agriasic_rv32i_control_shell.sv](../rtl/agriasic_rv32i_control_shell.sv)
- [src/rtl/agriasic_digital/rtl/agriasic_digital_rv32i_top.sv](../rtl/agriasic_digital_rv32i_top.sv)

In this variant:
- The RV32I core owns program flow, setup policy, retries, and optional calibration logic.
- The measurement FSM remains the cycle-accurate real-time engine for excitation, settle, sample, and accumulation.
- The SPI wrapper continues to provide host access, but it mainly feeds configuration, program loading, status readback, and debug transactions.
- The register file becomes the memory-mapped control/status window between the core and the measurement engine.
- Program memory can stay tiny: ROM for fixed measurement policy or a very small RAM if the program needs patching.

Recommended functional split:
1. RV32I core
- Initializes configuration registers
- Starts and polls measurement runs
- Clears sticky errors
- Implements simple decision logic or re-try policy
2. Measurement FSM
- Executes the hard real-time timing sequence
- Keeps excitation/sample cadence deterministic
- Aggregates pair result contributions
3. Peripheral register set
- Exposes config, status, and result
- Serves as the interface between core and measurement hardware

Diagram: [src/rtl/agriasic_digital/docs/diagrams/modules/agriasic_rv32i_control_architecture.svg](diagrams/modules/agriasic_rv32i_control_architecture.svg)

![agriasic_rv32i_control_architecture](diagrams/modules/agriasic_rv32i_control_architecture.svg)

## 4. Top-Level Digital Architecture
### 4.1 Core partition
- Measurement sequencer: hardwired finite-state machine
- Excitation control: divider, phase control, settle counter
- SAR control: conversion request/latency/capture path
- SPI control plane: mode-0 slave + byte CDC + protocol decode
- Register interface: configuration writes and status/result mirrors

### 4.2 External interface assumptions
- External references remain off-die (VREFH, VREFL, VCM, V_EXC)
- External master clock source
- Host is optional for measurement execution, used for setup/readback

### 4.3 Architecture diagrams
- High-level dataflow: [src/rtl/docs/TJ_SD/diagrams/agriasic_digital_dataflow_hl.svg](diagrams/agriasic_digital_dataflow_hl.svg)

![agriasic_digital_dataflow_hl](diagrams/agriasic_digital_dataflow_hl.svg)

- Top integration block: [src/rtl/docs/TJ_SD/diagrams/modules/agriasic_digital_top_block_diagram.svg](diagrams/modules/agriasic_digital_top_block_diagram.svg)

![agriasic_digital_top_block_diagram](diagrams/modules/agriasic_digital_top_block_diagram.svg)

- Verilog orchestration flow: [src/rtl/docs/TJ_SD/diagrams/agriasic_digital_verilog_orchestration_flow.svg](diagrams/agriasic_digital_verilog_orchestration_flow.svg)

![agriasic_digital_verilog_orchestration_flow](diagrams/agriasic_digital_verilog_orchestration_flow.svg)

-- RV32I control architecture: [src/rtl/agriasic_digital/docs/diagrams/modules/agriasic_rv32i_control_architecture.svg](diagrams/modules/agriasic_rv32i_control_architecture.svg)

![agriasic_rv32i_control_architecture](diagrams/modules/agriasic_rv32i_control_architecture.svg)

## 5. Requirement Trace Matrix
| Req ID | Requirement | Implementation Mechanism | Verification Intent | Status |
|---|---|---|---|---|
| DR-001 | Start shall trigger autonomous measurement sequence | REG_CTRL bit0 -> start pulse -> measurement_fsm state entry | Smoke TB start-to-done and result check | Implemented |
| DR-002 | Excitation polarity and settle timing shall be programmable | cfg_divider/cfg_settle + excitation_ctrl | Waveform check of phase/settled timing | Implemented |
| DR-003 | SAR conversion latency shall be programmable | cfg_conv + sar_controller counter | conv_start and sample_done pulse timing checks | Implemented |
| DR-004 | Sequencer shall process positive and negative samples per pair | FSM states SAMPLE_P and SAMPLE_N with phase tag | D+ and D- update checks in TB/waveform | Implemented |
| DR-005 | Result shall accumulate signed pair contribution | S_ACCUM computes per-pair contribution and increments loop count | Deterministic result check on known input profile | Implemented |
| DR-006 | SPI command framing shall be deterministic 2-byte protocol | Byte0 decode + Byte1 payload/dummy always consumed | SPI protocol tests for command alignment | Implemented |
| DR-007 | Illegal SPI commands shall be detectable and observable | reserved-bit and bad-address checks -> sticky status bits | Negative-path SPI tests and STATUS readback | Implemented |
| DR-008 | Illegal writes to read-only registers shall be rejected | write target legality checks and NACK response | write-to-RO test + sticky error flag check | Implemented |
| DR-009 | Status shall expose busy/done and protocol errors | REG_STATUS packed bits [7:5],[1:0] | status mirror checks | Implemented |
| DR-010 | Sticky protocol errors shall be clearable by software | REG_CTRL bit7 write-one clear behavior | clear-after-error test sequence | Implemented |
| DR-011 | SPI byte crossing to core clock shall avoid duplicate byte-valid pulses | spi_slave toggle synchronizer | CDC-focused waveform/structural checks | Implemented (functional) |
| DR-012 | Fallback sequencing path shall remain viable independent of optional CPU path | measurement_fsm-centered top-level sequencing | FSM-only simulation path and regression target | In progress across flow closure |

## 6. Micro-Architecture by Module
### 6.1 measurement_fsm
Responsibilities:
- Accept start command in idle
- Drive settle/sample phases in polarity order P then N
- Wait on settled and sar_done handshakes
- Accumulate signed per-pair result contribution
- Repeat until pair_target reached, then assert done behavior

Key states:
- IDLE, SETTLE_P, SAMPLE_P, SETTLE_N, SAMPLE_N, ACCUM, LOOP, DONE

Configuration dependencies:
- pair_log2 selects number of sample pairs M=2^pair_log2

Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/measurement_fsm_block_diagram.svg](diagrams/modules/measurement_fsm_block_diagram.svg)

![measurement_fsm_block_diagram](diagrams/modules/measurement_fsm_block_diagram.svg)

### 6.2 excitation_ctrl
Responsibilities:
- Update polarity on set_phase request
- Generate settle window based on settle_cycles
- Generate divider tick timing from cfg_divider

Expected behavior:
- enable=0 drives neutral/reset-like local behavior
- set_phase clears settled and starts countdown when settle_cycles>0

Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/excitation_ctrl_block_diagram.svg](diagrams/modules/excitation_ctrl_block_diagram.svg)

![excitation_ctrl_block_diagram](diagrams/modules/excitation_ctrl_block_diagram.svg)

### 6.3 sar_controller
Responsibilities:
- Accept sample request when not busy
- Generate single-cycle conv_start pulse
- Count conversion latency cycles
- Capture adc_code into D+ or D- storage by phase
- Pulse sample_done when capture completes

Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/sar_controller_block_diagram.svg](diagrams/modules/sar_controller_block_diagram.svg)

![sar_controller_block_diagram](diagrams/modules/sar_controller_block_diagram.svg)

### 6.4 spi_slave
Responsibilities:
- SPI mode-0 shift and transaction bit counting in SCLK domain
- Byte-complete toggle synchronization into core clock domain
- One rx_valid pulse per completed byte in clk domain

Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/spi_slave_block_diagram.svg](diagrams/modules/spi_slave_block_diagram.svg)

![spi_slave_block_diagram](diagrams/modules/spi_slave_block_diagram.svg)

### 6.5 agriasic_digital_spi_top
Responsibilities:
- Decode Byte0 command and track pending transaction context
- Enforce protocol legality checks before state mutation
- Generate response bytes for ACK/NACK/error conditions
- Keep parser alignment by consuming Byte1 for invalid Byte0
- Bridge config writes into core controls and mirror status/result

Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/agriasic_digital_spi_top_block_diagram.svg](diagrams/modules/agriasic_digital_spi_top_block_diagram.svg)

![agriasic_digital_spi_top_block_diagram](diagrams/modules/agriasic_digital_spi_top_block_diagram.svg)

### 6.6 regfile
Responsibilities:
- Parameterized storage for software-visible config/status points
- Supports writes from host path and status/result mirror path

Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/regfile_block_diagram.svg](diagrams/modules/regfile_block_diagram.svg)

![regfile_block_diagram](diagrams/modules/regfile_block_diagram.svg)

## 7. Register and Protocol Specification
### 7.1 Register map
- 0x0 REG_CTRL (RW): bit0=start pulse, bit7=clear sticky protocol flags
- 0x1 REG_PAIR_LOG2 (RW)
- 0x2 REG_SETTLE (RW)
- 0x3 REG_DIVIDER (RW)
- 0x4 REG_CONV (RW)
- 0x5 REG_STATUS (RO): bit7 protocol_err, bit6 bad_addr, bit5 illegal_ro_write, bit1 done, bit0 busy
- 0x6 REG_RESULT_LO (RO)
- 0x7 REG_RESULT_HI (RO)

### 7.2 SPI command format
- bit7: RW (1=READ, 0=WRITE)
- bit6:3: register address
- bit2:0: reserved, shall be zero

### 7.3 SPI response byte codes
- 0xA5 write accepted (ACK)
- 0x5A write rejected (NACK)
- 0xE1 invalid command (reserved bits violation)
- 0xE2 invalid address

### 7.4 Framing rule
Every SPI transaction is exactly two bytes. If Byte0 is illegal, Byte1 is consumed and discarded before next command decode.

### 7.5 SPI protocol diagram
Diagram: [src/rtl/docs/TJ_SD/diagrams/modules/agriasic_digital_spi_protocol_flow.svg](diagrams/modules/agriasic_digital_spi_protocol_flow.svg)

![agriasic_digital_spi_protocol_flow](diagrams/modules/agriasic_digital_spi_protocol_flow.svg)

## 8. Reset and Error Handling
Reset expectations:
- State machines return to deterministic idle/reset states
- Configuration registers return to defaults
- Sticky protocol bits clear on reset

Error policy:
- Illegal command/address/RO write do not alter configuration payload targets
- Sticky status bits remain set until software clear via CTRL bit7

## 9. Timing and Control Contracts
- conv_start is one-cycle pulse per accepted sample request
- done and busy are mutually constrained by end-of-sequence semantics
- settled handshake gates both positive and negative sample phases
- sample_done handshake gates transitions out of sample states

Diagram: [src/rtl/docs/TJ_SD/diagrams/agriasic_measurement_fsm_cycle_flow.svg](diagrams/agriasic_measurement_fsm_cycle_flow.svg)

![agriasic_measurement_fsm_cycle_flow](diagrams/agriasic_measurement_fsm_cycle_flow.svg)

## 10. Verification Plan (MAS-oriented)
### 10.1 Test categories
- T1 Reset determinism and startup checks
- T2 Nominal sequence completion and result correctness
- T3 SPI legal transactions and readback integrity
- T4 SPI illegal command/address/RO write behavior
- T5 Sticky error clear and command-recovery behavior
- T6 CDC sanity on byte-valid pulse semantics

### 10.2 Existing collateral alignment
- Smoke TB exists for direct top and SPI wrapper paths
- Negative-path SPI checks and status-flag validation added

### 10.3 Remaining verification gaps
- Full simulator-backed regression evidence collection in this environment
- Broader random SPI traffic/error-recovery tests
- Formal or lint CDC signoff evidence for byte transport bridge

## 11. Acceptance Criteria for Digital Signoff Readiness
A1. All DR-001..DR-011 pass simulation-based checks with archived logs.
A2. Protocol negative paths are reproducible and deterministic.
A3. STATUS and RESULT mirrors remain software-coherent during and after run.
A4. Reset and restart behavior is stable under repeated runs.
A5. FSM-only fallback build remains regression-clean and archived.

## 12. Open Items and Assumptions
- OI-001: Confirm Week-1 memory/compiler assumptions if optional CPU path is reintroduced.
- OI-002: Tie this MAS to analog boundary signoff package for settle window and conversion latency assumptions.
- OI-003: Add requirement IDs from project-level requirement database if a formal requirement tool is used.

## 13. Artifact Map
- RTL top: src/rtl/agriasic_digital/rtl/agriasic_digital_spi_top.sv
- Core integration: src/rtl/agriasic_digital/rtl/agriasic_digital_top.sv
- Control modules: src/rtl/agriasic_digital/rtl/ctrl/
- Testbenches: src/rtl/agriasic_digital/tb/smoke/
- Supporting docs: src/rtl/docs/TJ_SD/agriasic_digital_implementation_plan.md, src/rtl/docs/TJ_SD/agriasic_digital_timing_checklist.md
- Diagram set: src/rtl/docs/TJ_SD/diagrams/
- Slide set: src/rtl/docs/TJ_SD/slides_svg/

---
This MAS draft is requirements-based and aligned to the current RTL implementation. It is intended as a living document for review, signoff preparation, and cross-discipline contract management.

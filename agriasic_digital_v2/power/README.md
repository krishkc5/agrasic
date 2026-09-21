# AgriASIC digital RTL power analysis

At **1.8 V and a target 160 MHz**, the present RV32IM + measurement-control
implementation has an **illustrative logic dynamic-power budget of about
36 mW**, with **15–73 mW** across the stated assumptions. Energy for the committed
three-frequency firmware sweep is approximately **0.72 mJ** in the central
scenario. **These are analytical estimates informed by simulation and generic
synthesis, not TSMC-characterized or signoff power results.** ROM/RAM macro power,
leakage, I/O pads and external clock generation are additional and uncharacterized.

The CPU's synchronous clock enable is low for **99.992%** of the observed sweep.
This suppresses most CPU data switching but **does not stop the clock**. It cannot
be presented as a 99.992% reduction in CPU power.

Only digital RTL is covered, as requested. No analog power is included.

## What was actually analyzed

- Repository `agrasic`, revision `b2f1309`, Rev 4.3 RTL, rather than the older
  sibling `agriasic_digital_v2` directory outside this repository.
- Top: [`agriasic_digital_rv32i_top`](../rtl/agriasic_digital_rv32i_top.sv).
  Includes the pipelined RV32IM core, register file, multiplier/divider logic,
  shell/MMIO/reset logic, excitation controller, measurement FSM, accumulators,
  and digital SAR controller.
- The 4 KiB instruction memory and 2 KiB data memory were modeled functionally
  in simulation and deliberately blackboxed for synthesis/counting. Their
  foundry implementations have not been selected.
- The separate `agriasic_digital_spi_top` has no instantiated CPU and is not part
  of this top. SPI circuitry must be added when the integrations are composed.
- Supply: **1.8 V assumed**, per the user's guidance. Clock: **160 MHz design
  target**, required for the documented 10 MHz excitation with 16 phase states.
  **No static timing analysis has established operation at 160 MHz.**

The testbench runs at **100 MHz** (`always #5`). Cycle counts and normalized
switching activity are rescaled to 160 MHz for the estimate. At 100 MHz the
physical excitation points in this test are 6.25 MHz, 62.5 kHz and 625 Hz;
their intended 10 MHz, 100 kHz and 1 kHz labels assume the 160 MHz target.

## Evidence from the RTL and simulation

The existing end-to-end functional test was copied into a build directory and
instrumented without modifying production RTL or firmware. The behavioral
comparator supplies the existing deterministic I/Q input pattern. All original
functional checks passed: six completed measurements, I=400 and Q=280 at all
three points, correct dividers and scratch-memory results, and the core-PC
freeze assertion. These samples represent this workload, not random data,
CoreMark, Dhrystone, or a worst-case arithmetic stress test.

| Observed quantity | Result |
|---|---:|
| Original end-to-end test cycle count | 3,152,965 |
| Instrumented sweep window | 3,152,964 cycles |
| CPU enabled within the instrumented window | 238 cycles |
| CPU frozen within the instrumented window | 3,152,726 cycles |
| Frozen fraction | 99.99245% |
| Sweep time at target 160 MHz | 19.706 ms |
| Measurements / ADC conversions | 6 / 96 |
| Instruction-memory enabled cycles during sweep | 184 |
| Scratch-memory enabled cycles during sweep | 30 |

The one-cycle difference comes from the original test counting rising edges
and the activity monitor delimiting the sweep on falling edges. All fractions,
power weights and energies consistently use the instrumented window.

| Divider N | CPU-enabled cycles | CPU-frozen cycles | Total | Time at 160 MHz |
|---|---:|---:|---:|---:|
| 1, including initial configuration | 96 | 1,378 | 1,474 | 9.213 us |
| 100 | 68 | 31,274 | 31,342 | 195.888 us |
| 10,000 | 74 | 3,120,074 | 3,120,148 | 19.501 ms |

The 1 kHz point occupies approximately 99% of this sweep. The present firmware
uses M=4 I/Q pairs, two measurements per frequency, settle=2 excitation periods
and conv=1. Different firmware or accumulation lengths change the duty cycle.

Three findings materially affect power:

1. **Clock enable is implemented as register hold behavior.**
   [`core_clk_en = !meas_inflight_q`](../rtl/agriasic_rv32i_control_shell.sv)
   controls the CPU state updates; every CPU register still receives `clk`.
   Input clock capacitance, internal flip-flop clock circuitry and clock
   distribution continue to consume dynamic power. A downstream synthesis
   flow might infer integrated clock gating, but that has not occurred in this
   generic flow and cannot be assumed.
2. **The divider does not follow the enable.** The CPU connects `.stall(1'b0)`
   to [`DividerUnsignedPipelined`](../rtl/rv32i/agriasic_rv32i_divider.sv), and
   the divider's sequential block does not use `stall` at all. Across the
   frozen windows, the surviving divider state produced **1,746 bit transitions**;
   the other surviving CPU pipeline and register-file state produced **zero**.
   Stable operands eventually make divider data settle. This is residual
   pipeline activity, not continuous random toggling throughout the pause.
3. **`ecall` is an observation signal, not a persistent sleep mechanism.**
   In the sampled post-`ecall` window, `imem_ce` was high on **4,102/4,102 cycles**
   and CPU pipeline state continued switching. With `start_i` subsequently low,
   the core is synchronously reset, but `imem_ce` was still high on
   **4,096/4,096 sampled cycles**. Holding reset does not turn off the clock or
   automatically suppress accesses to a real instruction-memory macro.

Logs and machine-readable measurements:
[`simulation.log`](results/simulation.log), [`activity.csv`](results/activity.csv),
[`epochs.csv`](results/epochs.csv),
[`register_activity.csv`](results/register_activity.csv).

## Generic synthesis result

YoWASP Yosys 0.69 with its slang frontend successfully elaborated and synthesized
the top. `check` reported zero problems. Memories were explicit blackboxes;
the rest was synthesized to generic bit-level primitives with `synth -noabc`.

| Block | Surviving generic register bits | Central clock estimate at 160 MHz |
|---|---:|---:|
| CPU pipeline / division metadata | 909 | 11.78 mW |
| Integer register file | 1,024 | 13.27 mW |
| Arithmetic divider pipeline | 665 | 8.62 mW |
| **CPU subtotal** | **2,598** | **33.67 mW** |
| Measurement engine, excitation and digital SAR | 144 | 1.87 mW |
| Shell, MMIO and reset | 58 | 0.75 mW |
| **Total outside memory macros** | **2,800** | **36.29 mW** |

There are also **33,535 generic combinational primitives**, including AND, OR,
XOR, NOT and mux cells. This is **not a NAND2-equivalent gate count, mapped
standard-cell area, or final register count**. Technology mapping, arithmetic
optimization and clock-gating inference can change it. For example, this
generic result still retains all 32 words of the integer register file;
further optimization may remove the hard-zero register storage.

The VCD analyzer matched **2,800/2,800** surviving register bits by their RTL net
names, removed constant/pruned bits and duplicate aliases, and counted rising
transitions separately from total bit transitions. This is state-output activity
coverage, **not gate-level power-annotation coverage**. Internal arithmetic gates,
physical glitches and clock-tree nodes are not present in the RTL trace.

See [`structure.json`](results/structure.json),
[`synthesis.log`](results/synthesis.log) and the source hashes in
[`provenance.json`](results/provenance.json).

## Model and explicit assumptions

For the clock-related term:

```text
P_clock = N_FF * C_clock,effective * V^2 * f
```

Here `C_clock,effective` includes clock-pin charging, equivalent internal
flip-flop clock energy and an allowance for clock distribution. It is not just
the capacitance of the external CLK pin. One full clock period contains one
charging edge; multiplying this equation by two for the two clock edges would
double-count the capacitive charging term.

A public **GF180MCU** reference DFF at TT, 25 C, 1.8 V has a 2.914 fF clock-pin
capacitance. At the 0.1027 ns characterized slew point, its held-data internal
clock energy averages 0.061075 pJ per complete cycle across D=0/1. Thus:

```text
C_equivalent = 2.914 fF + 0.061075 pJ / (1.8 V)^2
             = 21.76 fF per bit, before external clock distribution
```

This motivates a round **25 fF** central engineering assumption. **GF180MCU is
not TSMC 180 nm**, and the design was not mapped to GF cells. The reference is
only an order-of-magnitude check. Different cell families, enables, reset
implementations, clock slews, routing and PVT can move the result substantially.
The chosen 10/25/50 fF scenarios are **not characterized process corners or
guaranteed bounds**. Sources: the foundry-provided
[DFF characterization](https://github.com/google/globalfoundries-pdk-libs-gf180mcu_fd_sc_mcu7t5v0/blob/main/cells/dffq/gf180mcu_fd_sc_mcu7t5v0__dffq_1__tt_025C_1v80.lib.json)
and [library units and operating point](https://github.com/google/globalfoundries-pdk-libs-gf180mcu_fd_sc_mcu7t5v0/blob/main/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_1v80.lib).

The separate data-switching term is a deliberately coarse sensitivity model:

```text
E_proxy_per_state_rise = (N_generic_logic / N_FF) * C_logic * V^2 * k
P_data_proxy = (observed state-bit rises / observed clock cycles) * f
               * E_proxy_per_state_rise
P_logic_dynamic = P_clock + P_data_proxy
```

The average logic cone per register bit is approximated uniformly. `k` is an
assumed allowance for internal switching/glitches and model mismatch. This does
not reconstruct activity inside the multipliers or divider, and zero state
transitions do not generally prove zero combinational activity. Its usefulness
here is checking the relative scale for this very long, mostly static workload.
It must be replaced by characterized gate-level power for an absolute claim.

| Parameter | Low scenario | Central scenario | High scenario |
|---|---:|---:|---:|
| Effective clock capacitance per FF bit | 10 fF | 25 fF | 50 fF |
| Assumed logic load per generic primitive | 2 fF | 5 fF | 10 fF |
| Data activity multiplier `k` | 1 | 2 | 4 |
| Voltage | 1.8 V | 1.8 V | 1.8 V |
| Master clock | 160 MHz | 160 MHz | 160 MHz |

All coefficients are editable in [`assumptions.json`](assumptions.json).
The logic-load and activity-multiplier values are analyst-selected sensitivity
assumptions, not values extracted from the reference DFF or from a TSMC library.

## Estimated logic dynamic power

| Operating window | Low | Central | High |
|---|---:|---:|---:|
| Short CPU-enabled firmware windows | 15.11 mW | 39.25 mW | 84.42 mW |
| Measurement windows, CPU state frozen | 14.53 mW | 36.35 mW | 72.82 mW |
| **Whole three-frequency sweep** | **14.53 mW** | **36.35 mW** | **72.83 mW** |
| Post-`ecall`, clock and fetch continuing | 14.78 mW | 37.59 mW | 77.79 mW |
| `start_i=0`, core reset and clock continuing | 14.52 mW | 36.29 mW | 72.58 mW |

The central sweep consists of 36.288 mW estimated clock-related power and
0.062 mW data-activity proxy. The precision above makes the calculation
auditable; **quote approximately 36 mW, not 36.3504 mW, in a presentation**.
The range reflects assumptions and does not guarantee the actual design lies
inside it. CPU-only central sweep dynamic power is about **33.7 mW** under the
same model, excluding memories.

```text
T_sweep = 3,152,964 / 160 MHz = 19.706 ms
E_sweep = P_sweep * T_sweep
        = 0.286 / 0.716 / 1.435 mJ for low / central / high scenarios
```

At the same voltage and normalized activity, the estimate scales approximately
linearly with clock: **18.2 mW at 80 MHz**, **22.7 mW at 100 MHz**, and
**36.4 mW at 160 MHz** in the central scenario. Lowering the master clock also
lowers the excitation frequencies with the present divider settings. It does
not preserve the 10 MHz sensing point automatically. Dynamic energy for an
unchanged number of cycles remains approximately constant; leakage energy does
not obey that simplification.

For a repetition period `T`, use the actual between-sweep state:

```text
P_average = P_sweep * (19.706 ms / T)
            + P_between * (1 - 19.706 ms / T)
```

For example, one sweep per second with `start_i` low between sweeps still gives
about **36.29 mW logic dynamic power** in the central model because the clock is
running. Multiplying 36 mW by a 1.97% duty factor and claiming sub-mW average
power would assume a clock-off sleep state that this RTL does not implement.

## What must be added for total digital power

```text
P_total_digital = P_logic_dynamic + P_logic_leakage
                 + P_IMEM_macro + P_DMEM_macro + P_IO
```

These missing terms cannot be numerically characterized from the current RTL:

- **Memories:** a macro's CE behavior, internal clock power, access energy and
  leakage require its Liberty/SPICE characterization. The average access-energy
  contribution during this sweep can be computed as
  `(184*E_IMEM + 30*E_DMEM)/19.706 ms`. As an explicitly hypothetical example,
  10–100 pJ per access for both memories contributes about **0.11–1.09 uW**;
  this excludes macro clock/background/leakage power. After `ecall` and during
  reset, the observed instruction CE is continuously high, so the same
  hypothetical 10–100 pJ per enabled cycle would contribute **1.6–16 mW** at
  160 MHz. These access-energy values are sensitivity inputs, not published
  specifications for a selected memory.
- **Memory implementation:** if the full 2 KiB scratch RAM became ordinary,
  ungated FF storage, it would add up to 16,384 register bits. Applying the
  same clock assumptions adds approximately **85–425 mW** of clock-related
  dynamic power, central **212 mW**, before its data muxes. This is a hypothetical
  full-capacity FF implementation; optimization or banking can change it.
  A constant ROM is not automatically 32,768 clocked FFs. Selecting real memory
  macros is necessary before quoting total digital power or area.
- **Leakage:** no target TSMC library or temperature corner is available.
  Leakage is left as an unknown additive term, not set to zero or guessed from
  the GF reference cell. A future clock-off idle state would still have leakage.
- **Pads/loads:** the core top does not specify the pad ring or external loads.
  Add those from the actual interfaces and capacitances. The separate SPI
  integration is outside this report's synthesized top.

## Most useful implementation changes

1. **Use a real integrated clock gate for an eligible CPU domain**, or verify
   equivalent automatic clock-gating insertion in synthesis. The 2,598 CPU FF
   bits account for about **33.7 mW of central assumed clock power**. That is
   the main opportunity during a measurement pause. Gating requires a defined
   enable/reset/test/wakeup contract and new functional/timing checks; the
   quoted potential is not an implemented or verified saving.
2. **Add a persistent firmware-complete idle state and suppress memory CE**
   when the core should be asleep or held in reset. An `ecall` pulse alone
   does not accomplish this, and memory CE should not repeatedly activate
   a macro on an unchanged address unless required.
3. **Review divider enable and arithmetic scope.** The divider's unused stall
   input is worth fixing with appropriate pipeline verification. The current
   C build targets RV32IM, matching the hardware. Removing M-extension hardware
   or using a compact iterative divider is an architectural option only after
   auditing and, if needed, recompiling the firmware and confirming future
   firmware requirements. The committed 384-byte image contains two M-extension
   DIV instructions, so the current binary already needs division support.
4. **Choose and characterize the memory macros, then map to the target TSMC
   library.** Run STA at the proposed 6.25 ns clock period before treating
   160 MHz as an achievable operating point. Do not apply a blanket multicycle
   exception solely because a synchronous enable exists.

No RTL modifications were made as part of this analysis.

## Presentation wording and files

> At an assumed 1.8 V and a 160 MHz target clock, our RTL-informed budget is
> approximately 36 mW for the RISC-V core and digital control logic, excluding
> memory macros, leakage and pads. The assumption study spans roughly 15–73 mW.
> Simulation shows the CPU state is frozen for 99.992% of the measurement sweep,
> but the current clock enable leaves the clock running, making actual clock
> gating the main power-reduction opportunity. These are pre-silicon estimates,
> not measured or TSMC-characterized power results.

Presentation graphic: [PNG](results/power_summary.png),
[PDF](results/power_summary.pdf), [SVG](results/power_summary.svg).
Calculation outputs: [CSV](results/power_estimates.csv),
[summary JSON](results/summary.json).

## Reproduce or refine

1. Install Verilator and a C++ toolchain on Linux/WSL. This run used Verilator
   5.020. Install Python packages `yowasp-yosys` and `matplotlib`; this run used
   Yosys 0.69. The entry script also finds the workspace-local installation in
   `.tools/power-python` when present.
2. From the repository root, run the functional activity simulation:

   ```bash
   bash agriasic_digital_v2/power/run_sim.sh
   ```

   This builds in a fresh Linux `/tmp/agriasic-power.*` directory because
   Verilator's make flow does not support workspace paths containing spaces.
   The generated VCD is about 0.52 GB and is ignored by Git. The generated
   testbench retains the original functional checks. Only simulation code is
   instrumented; production RTL is copied unchanged. `SYNTHESIS` suppresses
   disassembler strings and memory-wrapper assertions; the original end-to-end
   testbench checks and its PC-stability assertion are enabled with `--assert`.
3. Run synthesis and analysis from a Python environment with those packages:

   ```text
   python agriasic_digital_v2/power/run_synthesis.py
   python agriasic_digital_v2/power/analyze_activity.py
   python agriasic_digital_v2/power/estimate_power.py
   ```

   Declaration-order compatibility is enabled for the existing core. No source
   declarations are reordered. The checked-in reference-cell JSON contains
   the numeric GF example; its source URLs are in `assumptions.json` and its
   license is included in `reference_LICENSE.txt`.
4. Change `assumptions.json` to explore voltage, frequency and coefficients.
   Re-run `estimate_power.py` to regenerate the CSV/JSON and plots. The prose
   tables in this README describe the committed assumptions and are not
   automatically rewritten.

To move from this budget to characterized pre-layout power, use the authorized
TSMC 180 nm standard-cell and memory libraries, map the actual RTL, specify
operating corner/input slew/output loads, validate timing, and annotate the
representative workload in the power tool. Report annotation coverage and
dynamic/internal/leakage terms separately. Include clock-tree/parasitic estimates
and repeat after physical implementation. Generic Yosys synthesis alone does
not supply power numbers, and this RTL VCD needs tool-supported RTL-to-netlist
mapping or a gate-level simulation before use on the mapped netlist.

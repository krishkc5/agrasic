# Single-Die Impedance Sensing Node

## High-Level Design Document — Revision 4.1

| | |
|---|---|
| **Project** | Senior Design: Low-Power Agricultural Impedance Sensing |
| **Architecture** | On-die excitation generation, fixed-gain TIA, 8-bit SAR ADC, tiny RISC-V core, SPI |
| **Team** | Krishna Chemudupati, Taarana Jammula, Vidhu Bulumulla |
| **Process** | TSMC 180nm MS/RF-G (Muse shared block) |
| **Implementation** | Automated RTL-to-GDS for digital; manual layout for analog |
| **Revision** | 4.1 — Integrated Node, Effort-Budgeted |
| **Date** | September 1, 2026 |
| **Trial GDS** | November 18, 2026 (11 weeks from this revision) |
| **Status** | Implementation specification; circuit values, area budget, and memory availability subject to Week 1 closure |

Revision 4.1 keeps both integration decisions from Rev 4.0 — **on-die excitation generation and an on-die controller** — and scopes each to what a three-person team can close by trial GDS. The chip is justified by cost per deployed node and energy per measurement, not by feature count.

The substantive change from Rev 4.0 is that excitation **amplitude** is now set by an external reference pin rather than an on-die DAC. Section 2.5 gives the cost and effort analysis behind that choice.

---

## 1. Executive Summary

An agricultural impedance-sensing node built from catalog parts needs a microcontroller, a waveform source, a precision analog front end, a data converter, a reference, and the passives and board area to connect them. This design collapses that parts list onto one die in TSMC 180nm.

The chip generates its own bipolar excitation, drives a two-electrode soil or plant sensor, converts the return current to a voltage with an on-die transimpedance amplifier, digitizes it with an 8-bit SAR ADC, sequences the measurement with a minimal on-die RISC-V core, and presents results over SPI. A host is optional: it configures and reads, but the die completes a measurement without it.

Two claims carry the project:

1. **Unit cost.** At deployment volume, one die is cheaper than the multi-chip BOM it replaces, and it eliminates the board area, assembly steps, and test points that go with it.
2. **Energy cost.** Integration removes inter-chip signaling, off-board reference distribution, and the standby current of several always-on parts. Lower energy per measurement extends node lifetime, which in a field deployment is a *service-visit* cost, not a battery cost.

Section 2 states both claims quantitatively, including where they are false.

**Table 1 — Revision 4.1 architecture at a glance**

| Decision | Rev 3.0 | Rev 4.1 | Rationale |
|---|---|---|---|
| Excitation timing | External MCU | On-die divider, polarity, and drive switching | Removes the external waveform source; the on-die core has no host to borrow a pin from. |
| Excitation amplitude | External | External V_EXC reference pin | Same post-silicon trimmability as an on-die DAC at ~40% of the effort. See §2.5. |
| Controller | External MCU only | On-die RV32I core from the team's reference design, FSM fallback | Removes the external MCU from the per-node BOM in the target product. |
| Analog front end | Fixed-gain TIA | Fixed-gain TIA (unchanged) | Already the lowest-cost option for the low-current interface. |
| Conversion | 8-bit SAR ADC | 8-bit SAR ADC (unchanged) | Adequate after TIA noise and sensor variability; more bits cost area and matching. |
| Demodulation | Off-chip subtraction | On-die paired-sample subtraction and accumulation | Removes host round-trips per sample; cuts active time by roughly 2M. |
| References | External | External VREFH, VREFL, VCM, **V_EXC** | Bandgap is a genuine cost saving but a first-silicon risk. See §7. |
| Clocking | External | External clock, on-die dividers | Divider chain is nearly free and enables on-die frequency selection. |
| Host interface | SPI slave | SPI slave plus autonomous mode | Host becomes optional rather than required. |

---

## 2. The Cost Argument

### 2.1 What the die replaces

**Table 2 — Discrete node BOM versus integrated node.** Prices are order-of-magnitude placeholders at roughly 1k quantity and **must be replaced with current distributor quotes before this document is presented.**

| Function | Discrete implementation | Indicative unit cost | Rev 4.1 |
|---|---|---|---|
| Excitation waveform | Integrated AFE or DDS/DAC + buffer | $4–8 | On die (amplitude referenced externally) |
| Transimpedance front end | Precision low-bias op-amp + RF/CF | $1–3 | On die |
| ADC | 8–12 bit SAR, or AFE-integrated | $1–3 | On die |
| Measurement sequencing | Low-power MCU (MSP430-class) | $1–2 | On die (host optional) |
| Voltage reference | Precision reference IC | $0.5–1.5 | External; on-die candidate for a product revision |
| Passives, connectors, board | ~15–25 parts, 4-layer board area | $1–3 | Reduced to references, decoupling, electrodes |
| **Total** | | **~$9–20** | **1 die + references + decoupling** |

The integrated node does not reach zero: it still needs a package or die-attach, external references, decoupling, an energy source, and electrodes. The saving is the middle of the table.

### 2.2 Unit-cost crossover

With `C_off` the discrete BOM per node, `C_die` the recurring cost per packaged die at volume, and `NRE` the non-recurring engineering and mask cost, the integrated node is cheaper once

```
N  >  NRE / (C_off - C_die)
```

**This inequality, not a per-unit price comparison, is the honest form of the cost claim.** The presentation should state the assumed NRE, show the crossover N*, and compare it against a plausible deployment size.

### 2.3 Energy cost is the larger lifetime cost

```
E_meas  =  E_excite + E_settle + E_convert + E_readout
E_day   =  f_meas * E_meas  +  I_sleep * V * 86400
```

Integration reduces these terms mainly through the **on-die controller**, not the excitation block:

- On-die paired-sample subtraction and accumulation wakes the host once per *reported measurement* rather than once per *sample* — roughly a factor of 2M reduction in host active time and SPI traffic for M averaged pairs.
- One die carries one sleep-leakage budget instead of the summed standby of four or five packaged parts.
- Excitation, TIA, and ADC share one supply domain and substrate; no off-board analog signal is driven through pads, traces, and connector capacitance.

A node that dies early costs a truck roll and a technician hour, which dominates the price of the node itself. **This is the strongest version of the cost argument and should lead the presentation, ahead of the BOM table.**

### 2.4 What the cost claim does not say

State these before a reviewer finds them:

- **At senior-design volume the chip is far more expensive than the discrete node.** A shuttle run, tooling, and three engineers for a semester will never be recovered across a handful of die. The claim is about the design at deployment volume and about demonstrating that path.
- **Yield and packaging are unbudgeted.** Bare-die area cost understates real per-unit cost.
- **Integrated AFEs are strong competitors.** A single catalog AFE already collapses much of the middle of Table 2. The differentiator is power at a fixed measurement rate plus elimination of the external MCU, not raw part count.
- **The power benefit belongs to the sequencer, not the excitation generator.** Excitation drive current is set by the electrode load, not by where the generator lives. Do not claim a power saving for on-die excitation on its own; it is checkable in thirty seconds and it is not there.

### 2.5 Is on-die excitation worth it?

Silicon area is not the constraint. The excitation block is roughly 0.03–0.05 mm² without an amplitude DAC, which at ~$0.03–0.05/mm² of 180nm wafer area is **under a cent per die** at volume, and a few hundred dollars of one-time shared-block area on the shuttle. The real currency is engineer-weeks.

**Table 3 — Excitation options, effort versus return**

| Option | Effort (FTE-wks) | BOM saving/node | Post-silicon trim |
|---|---|---|---|
| Off-chip entirely | ~0.2 | $0 | none |
| **On-die switching + timing, amplitude from external V_EXC pin** | **~2.8** | **~$1.80** | frequency, duty, phase |
| On-die switching + on-die amplitude DAC | ~5.0 | ~$1.80 | frequency, duty, phase, amplitude |

Two comparisons decide it:

- **Off-chip versus on-die (middle row):** 2.6 FTE-weeks buys the full ~$1.80/node, because with the controller on die there is no host in the node to generate the waveform. Breakeven lands near **4,300 deployed nodes**. On BOM alone this pays back for a product, not for a research plot — the same shape as the overall cost claim, and it should be said in the same breath.
- **Amplitude DAC versus external reference (rows two and three):** the extra 2.2 FTE-weeks buys *only* amplitude trimmability, and it lands on the TIA owner, whose block is the critical path for both other blocks. An external V_EXC pin gives the same trimmability from a board resistor divider, consistent with the decision already made to keep VREFH/VREFL/VCM external for first silicon.

**Conclusion: keep on-die excitation; defer the amplitude DAC** to a product revision alongside the bandgap. Note that ~1.0 of the 2.8 FTE-weeks is excitation-to-TIA coupling verification, and that cost is irreducible — it is the price of putting a switching driver on the same substrate as the summing node, DAC or no DAC.

The unquantified benefit is risk transfer. The highest-probability, highest-impact unknown in the project is the sensor current in real soil. On-die frequency selection plus an externally set amplitude converts "we guessed the excitation wrong" from a board respin into a register write and a trimpot turn, on a chip whose TIA gain is deliberately fixed and therefore cannot absorb the error itself.

---

## 3. Scope

### 3.1 On die

- excitation generator: divider chain from the master clock, polarity and duty control, and a drive stage switching the electrode between levels derived from V_EXC and VCM;
- excitation output pad and electrode return / current-sense input pad, with appropriate ESD;
- fixed-gain TIA with feedback network RF, CF;
- 8-bit SAR ADC: sampling CDAC, comparator, reference switch network;
- 8-bit SAR controller;
- RV32I core with program storage, running the measurement sequence, paired-sample subtraction, and accumulation (§5);
- result, accumulator, control, and status registers;
- SPI slave interface;
- reset, enable, data-ready, and bias-shutdown control;
- analog test access to the TIA output and ADC input path, subject to pad budget.

### 3.2 Still external

- VREFH, VREFL, VCM, **V_EXC**, and supply decoupling;
- master clock;
- energy source and power conditioning;
- electrodes and any board-side sensor conditioning;
- optional host for configuration, logging, and calibration-coefficient storage.

### 3.3 Still excluded

Multiple sensor channels and the analog MUX; programmable TIA gain and autoranging; analog demodulator or integrator; ADC resolution above 8 bits; on-die excitation amplitude DAC; on-die bandgap; PLL; SRAM beyond the small register, accumulator, and data set; any radio. Each adds an analog interface and verification scope without strengthening either cost claim.

---

## 4. On-Die Excitation Generation

### 4.1 Baseline: programmable square wave, externally referenced amplitude

- a divider chain from the external master clock sets excitation frequency, selectable over a programmed range;
- polarity and duty control logic alternates the drive around VCM;
- a drive stage switches the electrode node between levels derived from the external **V_EXC** pin and VCM, with defined current limiting and a defined high-Z state;
- amplitude is changed on the board — a resistor divider, a trimpot, or the host's DAC — without touching the die.

Square wave rather than sine is the correct choice on cost grounds and should be defended that way rather than apologized for. Synchronous sampling at the fundamental with paired-sample subtraction rejects the odd harmonics; the residual is a calibration term. A sine DAC would cost area, current, and a settling-accuracy verification burden that Table 2 does not reward.

**Neither a sine mode nor an on-die amplitude DAC is in scope for this tapeout.** Both are product-revision items.

### 4.2 Interface to the measurement path

The excitation output is a separate pad from the sense input; drive current returns through the sensor to the TIA summing node. Excitation polarity is exported to the SAR controller so conversions align to a settled half-cycle. The settle interval between polarity change and sampling stays programmable, since electrode settling is the parameter most likely to be wrong before real soil data exists.

### 4.3 Verification

Frequency accuracy across the divider range; drive level accuracy and linearity against V_EXC; rise/fall and overshoot into the expected electrode load; drive current under a shorted electrode; disconnected-electrode behavior; **charge balance across a polarity pair** (net DC into the electrode must be near zero to avoid polarization and drift); **coupling from excitation switching into the TIA summing node, extracted.**

Those last two are the failure modes on-die excitation introduces, and neither is fixable after fabrication. Each gets its own regression test and its own line in the floorplan review.

---

## 5. On-Die Controller

### 5.1 Core selection

**Baseline: the team's reference RISC-V core, stripped to the minimum ISA the measurement program needs.** *(Reference design to be named — fill in source, ISA, pipeline depth, and license here.)* Starting from a core the team already has costs about the same effort as adopting an unfamiliar third-party core and keeps the debug familiarity, which matters more than gate count on an eleven-week schedule.

**The decision is settled by area, not preference, and it is measurable in Week 1.** Synthesize the reference core against the 180nm standard cell library and compare the gate count to the block allocation before committing. The figures below are generic estimates for a 5-stage RV32I-class core and should be replaced with the synthesis result.

| Configuration | Est. gates | Est. area (~0.014 mm²/kGE) |
|---|---|---|
| RV32I 5-stage datapath + control | 12–20 kGE | 0.17–0.28 mm² |
| Register file, 32×32 in flops | ~6 kGE | ~0.08 mm² |
| M extension, single-cycle array multiplier | 15–25 kGE | 0.21–0.35 mm² |
| M extension, multicycle shift-add | 2–3 kGE | ~0.04 mm² |
| **Stripped target** | **18–26 kGE** | **0.25–0.36 mm²** |

**Likely strip-down before the core is flow-ready.** Cores written for simulation or FPGA need retargeting for standard-cell synthesis:

- **remove the M extension if present** — the measurement program accumulates (D+ - D-)/2 over M pairs with M a power of two, so every operation it needs is an add or a shift. A single-cycle multiplier could be the largest block on the die and would run nothing;
- replace behavioral or initial-block memory with a synthesizable ROM plus a small flop data RAM;
- remove caches if present — they are unusable without an SRAM compiler;
- audit for latches, async resets, multi-driven nets, and other constructs the flow will reject;
- confirm the register file synthesizes to flops at acceptable area, or restructure to RV32E (16 registers) to roughly halve it.

Estimated effort: **2.0–3.0 FTE-weeks** to strip, retarget, and re-verify.

**Fallback if the area does not fit:** SERV (bit-serial RV32I, ~1.5–2.5 kGE, extensive hardened-macro precedent) at roughly 2.5–3.5 FTE-weeks, or the microcoded sequencer, or the FSM. ISA fluency, assembler flow, and testbench methodology carry over to any of these.

### 5.2 Memory is the item that decides feasibility

Resolve in **Week 1**: does the Muse shared block provide an SRAM/ROM compiler? If not:

- program storage becomes synthesized logic ROM, workable for a few hundred instructions;
- data memory becomes flops at ~5–6 GE/bit — 256 bytes is ~11 kGE (~0.15 mm²), while 1 kB is ~0.6 mm² and likely exceeds the whole allocation.

Cap data memory at **128–256 bytes** and size the program to what a synthesized ROM holds. If the answer is bad, the core degrades to a microcoded sequencer, and the team takes that outcome without arguing with it.

### 5.3 Build order: FSM first

The hardwired measurement FSM (~1–2 kGE, parameters in registers) is built **before** the core, for three reasons: it is the descope fallback, it is the reference model against which the core's program is checked, and it is a subset of what the core would run anyway. It is not throwaway work.

### 5.4 Program responsibilities

1. wake the TIA bias and excitation generator; wait the programmed settle interval;
2. set excitation polarity, wait, trigger a conversion, read the code as D+;
3. reverse polarity, wait, trigger a conversion, read the code as D-;
4. accumulate (D+ - D-)/2 into the result accumulator;
5. repeat for M pairs, M a programmed power of two so the divide is a shift;
6. store the result, assert data-ready, shut down analog bias, sleep until the next interval or host command.

---

## 6. System Architecture

```
                          +---------------------------------------------+
   external refs -------->|                                             |
   VREFH/VREFL/VCM/V_EXC  |   +--------------+      +---------------+   |
   master clock --------->|   |  excitation  |      |  SERV RV32I   |   |
                          |   |  divider +   |<---->|  + ROM/RAM    |   |
                          |   |  drive sw.   |      |  (FSM below)  |   |
                          |   +------+-------+      +---+-------+---+   |
                          |          |                  |       |       |
   EXC pad <--------------+----------+                  |       |       |
        |                 |                             v       v       |
   +----v------+          |   +---------+   +------+ +------+ +-----+   |
   |  sensor   |          |   |  fixed  |   | 8-b  | | SAR  | | SPI |<--+--> optional
   | electrodes|          |   |gain TIA |-->| SAR  |-| ctrl | |slave|   |     host
   +----+------+          |   +----^----+   | ADC  | +------+ +-----+   |
        |                 |        |        +------+                    |
   SENSE pad -------------+--------+                                    |
                          +---------------------------------------------+
```

Excitation generation, measurement, and sequencing are all on die. The host path is the only external one, and it is optional during a measurement.

---

## 7. Requirements and Open Parameters

**Table 4 — Requirements and closure method**

| Item | Status | Direction | Closure method |
|---|---|---|---|
| Channel count | Fixed | One | Direct electrode-return input; no MUX. |
| ADC resolution | Fixed | 8 bits | Static/dynamic simulation, code-density test. |
| Excitation timing | **On die** | Bipolar square wave, programmable frequency | Divider simulation; charge-balance and coupling checks. |
| Excitation amplitude | **External** | V_EXC reference pin | Board divider; drive-level linearity vs V_EXC. |
| Controller | **On die** | Reference core stripped to RV32I; SERV or FSM fallback | **Week 1 synthesis against the 180nm library**; area vs allocation. |
| Program/data memory | **Open — Week 1** | ROM program, 128–256 B data | Confirm compiler availability on the shared block. |
| TIA gain | Open | One fixed RF | Bound sensor current; I_PK,max * RF <= 0.8 * V_swing. |
| Sensor load | Baseline | Two-electrode or interdigitated | Validate against precision R, C, RC networks first. |
| Active current | Target | Below 100 uA where feasible | Post-layout budget at a defined measurement rate. |
| Sleep current | Target | Below 1 uA where feasible | Leakage simulation including pads and always-on digital. |
| Energy per measurement | **Cost-critical** | Report E_meas at demo rate | Post-layout current x time, per §2.3. |
| Die area | **Hard constraint** | Within Muse block allocation | Weekly floorplan tracking from Week 2. |
| Interface | Fixed | SPI slave plus external clock | Timing simulation and board-level transaction test. |

**On the bandgap.** A precision reference IC is a real line item in Table 2, so an on-die bandgap is a genuine cost reduction and the top candidate for a follow-on revision. It stays off this die because startup, curvature, and trim failures are silent and would compromise every other measurement on first silicon. Making that reasoning explicit is stronger than omitting the topic.

---

## 8. Ownership

| Owner | Owned blocks | Definition of done |
|---|---|---|
| **Krishna** | TIA, sensor interface, excitation drive stage | Extracted TIA and excitation drive; PVT and mismatch plots; sensor/pad assumptions; output range and settling spec; drive linearity vs V_EXC; charge-balance and coupling evidence; current budget. |
| **Vidhu** | 8-bit SAR analog core | Extracted ADC core; characterization report; reference-loading limits; sampling and decision timing limits; test-input mode; digital control truth table; DNL/INL, missing codes, energy per conversion. |
| **Taarana** | SAR controller, excitation digital, core + program, SPI, top-level digital, RTL2GDS flow | Hardened digital macro from the automated flow with clean DRC/LVS; area report against allocation; regression-clean RTL and gate-level netlist; protocol and register documentation; timing constraints; full-measurement traces; reset-safety evidence; host transaction script; **working FSM-only fallback build**. |

**Cross-review.** Krishna reviews ADC input range and analog loading. Vidhu reviews the TIA-to-ADC interface and comparator-to-SAR timing. Taarana reviews every control, status, reset, and test connection at top level. Krishna and Taarana jointly own the excitation timing contract, which crosses the analog/digital boundary in both directions. Floorplan, pad ring, mixed-signal regression, DRC/LVS closure, and bring-up planning are reviewed by all three.

An interface change is accepted only when schematic or RTL, behavioral model, timing/range specification, and regression test are updated together.

---

## 9. Effort Budget

Estimated in FTE-weeks of 40 professional hours. Student capacity at ~20 hrs/week over 11 weeks is 5.5 FTE-weeks each; at 30 hrs/week, 8.25.

| Owner | Work | Est. |
|---|---|---|
| **Krishna** | TIA design + verification 3.0; TIA layout/extraction 2.0; excitation drive design + layout 1.3; coupling verification 1.0; top-level closure share 1.3 | **8.6** |
| **Vidhu** | SAR architecture/comparator/CDAC 3.0; characterization 2.0; manual matched CDAC layout 3.0; post-layout re-verification 1.5; top-level closure share 1.3 | **10.8** |
| **Taarana** | RTL2GDS flow bring-up 3.5; SAR ctrl + SPI + registers 2.0; core strip-down, retarget, re-verification 2.5; program + verification 1.0; excitation digital 0.5; top-level digital, GLS, STA, power 1.5; mixed-signal regression 1.5; top-level closure share 1.3 | **13.8** |

**This plan does not fit at 20 hrs/week and is ~30% over at 30 hrs/week.** The estimates could be 20% off in either direction, but not by a factor of two. Three responses, in order of preference:

1. **Rebalance.** Move mixed-signal regression (~1.5 wks) to Krishna or Vidhu once their layouts are underway around Week 6–7. Top-level verification does not have to sit with the person who owns top-level digital.
2. **Cut the core to the FSM** at the Week 4 gate — a planning decision now, an emergency in Week 8.
3. **Raise committed hours.** If the honest number is 20 hrs/week, take response 2 immediately.

The largest variance items, ranked: RTL2GDS flow bring-up (can be 2 weeks or 6, and hides because it shows no visible functional progress), core plus memory, CDAC matched layout.

---

## 10. Schedule to Trial GDS (11/18/2026)

| Wk | Gate | Krishna | Vidhu | Taarana |
|---|---|---|---|---|
| 1 | **Interfaces, area, memory frozen** | Bound current, capacitance, swing, settling; excitation drive requirements; V_EXC range | Freeze ADC input/reference range, sampling load, timing contract | **Confirm ROM/SRAM compiler and block area allocation; synthesize the reference core against the 180nm library for a gate count; start RTL2GDS flow bring-up in parallel with RTL**; freeze pins, clocks, SPI mode, register map, excitation control contract |
| 2 | Nominal schematics | Topology and bias; size RF, CF; drive stage architecture | CDAC, sampling network, comparator, reference switches | SPI/register RTL, SAR FSM, divider/polarity logic; **measurement FSM (fallback) complete** |
| 3 | **Flow checkpoint** | Transient, settling, noise, swing, overload; publish ADC-drive limits | Transfer, acquisition, settling, comparator, decision timing; publish truth table | **Hardened macro produced from trivial RTL, or escalate to Radway for Synopsys support**; stripped core integrated above the FSM |
| 4 | **Scope gate** | PVT and capacitance stability sweeps; begin layout | PVT, DNL/INL, noise, kickback, reference loading; begin matched layout | **Go/no-go on core versus FSM-only. Area report against allocation. No features added after this point.** |
| 5–6 | Block signoff | Layout, DRC/LVS, extracted loop, mismatch, current budget, charge balance | CDAC/comparator layout, DRC/LVS, extraction, mismatch, missing codes, energy | Freeze RTL; assertions, synthesis, STA, power, pad controls, hardened macro closed |
| 7–8 | Top-level assembly | Extracted blocks under top-level loading; excitation/TIA coupling in place | Extracted ADC with digital timing and reference models | Mixed-signal top level (**consider handing regression to Krishna or Vidhu here**), gate-level checks, host transaction script, power/reset tests |
| 9–10 | Closure | Resolve coupling, stability, leakage, physical issues | Resolve reference/coupling and timing issues; final characterization | Full regression, top-level timing, DRC/LVS/ERC/antenna coordination |
| 11 | **Trial GDS 11/18** | Archive TIA and excitation source, extracted results, plots, limits | Archive ADC source, extraction, characterization, timing | Archive RTL, netlist, reports, tests; checksums, pinout, register guide, release package |

**Decision gates**

- **End of Week 1:** no unresolved ownership, pin, voltage-domain, range, clock, or handshake questions. Memory availability and area allocation are known facts, not assumptions.
- **End of Week 3:** flow produces a hardened macro; every block meets nominal function with a written interface contract; the FSM-only path works end to end against models.
- **End of Week 4:** feature freeze. Fixed TIA gain, 8-bit resolution, square-wave excitation, external amplitude, and the controller choice are final.
- **End of Week 8:** extracted analog, hardened digital macro, pad controls, and top-level connectivity integrated.
- **End of Week 11:** physical checks, end-to-end known-load demonstration, archived evidence. Trial GDS is full physical closure, not a functional milestone.

Confirm the final GDS date with Muse and treat everything after 11/18 as fix-only.

---

## 11. Risk Register

| Risk | Prob. | Impact | Mitigation | Fallback |
|---|---|---|---|---|
| **Plan is oversubscribed at realistic hours** | High | High | §9 rebalance; FSM-first build order; Week 4 go/no-go | Ship the FSM-only build; present the core as verified RTL, not taped out. |
| **RTL2GDS flow does not close** | Medium | High | Start Week 1 in parallel with RTL; Week 3 checkpoint on trivial RTL | Escalate to Radway for Synopsys support; reduce digital to the smallest hardenable macro. |
| **No ROM/SRAM compiler on the shared block** | Medium | High | Confirm Week 1 | Synthesized ROM with a reduced program, or microcoded sequencer, or FSM-only. |
| **Die area exceeds allocation** | Medium | High | **Week 1 core synthesis before committing**; M extension removed; weekly area tracking from Week 2; ROM sized conservatively | Drop to SERV, then sequencer, then FSM; reduce program and data memory, or RV32E register file. |
| Excitation switching couples into the TIA summing node | High | High | Floorplan separation, quiet sampling phase, shielding, extracted transient checks | Lower excitation frequency; gate sampling further from switching edges. |
| Electrode polarization from DC imbalance | Medium | Medium | Charge-balance verification across polarity pairs; symmetric drive timing | Board-side series capacitor; report as a calibration term. |
| Unknown sensor current | High | High | Measure representative RC loads early; keep TIA test access and headroom | Adjust V_EXC on the board and excitation frequency by register — now both trimmable. |
| TIA instability | Medium | High | Worst-case pad/sensor capacitance; tune CF; verify phase margin | Lower excitation frequency; increase compensation. |
| ADC/TIA range mismatch | Medium | High | Freeze common-mode/reference plan and behavioral range model Week 1 | Adjust external references or V_EXC. |
| CDAC/reference kickback | Medium | Medium | Local decoupling, sampling isolation, extracted transients | Slow SAR clock; strengthen external reference drive. |
| Cost claim challenged in review | Medium | Medium | Present §2.2 crossover and §2.4 caveats up front | Lead with the energy/service-cost argument, which does not depend on volume. |
| Physical closure late | Medium | High | Begin layout Week 4; run DRC/LVS continuously | Remove optional test routing before touching the core path. |

---

## 12. Descope Ladder

Simplify in this order and stop as soon as the schedule recovers:

1. remove optional debug registers and reduce optional analog test routing, retaining one TIA observation point;
2. reduce program and data memory to the minimum the measurement loop needs;
3. replace the core with SERV, then with a microcoded sequencer;
4. replace the sequencer with the hardwired measurement FSM plus parameter registers;
5. reduce excitation frequency selection to two or three fixed divider ratios;
6. **retain in all cases:** on-die excitation switching and timing, the TIA, 8-bit SAR conversion, paired-sample subtraction, reset safety, and a readable result over SPI.

Item 6 is the minimum that supports the cost argument. Below that line the die stops being a node and returns to being a peripheral.

---

## 13. Calibration and First-Silicon Bring-Up

1. verify supplies, reset, SPI identity, quiescent current;
2. verify external references (including V_EXC) and internal bias points;
3. test the excitation generator standalone: frequency, drive level versus V_EXC, drive into known loads, charge balance;
4. test the ADC standalone through the test input with a known external voltage;
5. test TIA gain, bandwidth, noise, settling with precision resistors and current injection;
6. connect TIA to ADC, verify end-to-end codes under host-triggered single conversions;
7. run the on-die measurement program against known R and RC loads; **compare its accumulated result against host-side arithmetic on the same raw samples** — the only test that proves the controller is doing arithmetic correctly rather than plausibly;
8. calibrate: R_CAL = G * (D_SYNC - D_OFF), refined once real electrode data exists;
9. measure E_meas and sleep current at the demonstration duty cycle — the headline number for §2.3, so instrument for it deliberately rather than estimating afterward;
10. proceed to controlled soil and plant electrode experiments.

---

## 14. Pre-Tapeout Checklist

- [ ] Sensor current and capacitance range documented with conservative margin
- [ ] External reference, V_EXC, common-mode, supply, clock, pad, and ESD assumptions frozen
- [ ] Die area within the shared-block allocation, with margin, confirmed on the floorplan
- [ ] TIA passes stability, noise, settling, overload, power, leakage, PVT, mismatch, extracted checks
- [ ] Excitation generator passes frequency, drive-level, short/open, charge-balance, and coupling checks
- [ ] ADC passes DNL/INL, missing-code, noise, timing, reference-loading, PVT, mismatch, extracted checks
- [ ] Digital macro hardened through the automated flow with clean DRC/LVS and closed timing
- [ ] Digital passes SPI, reset, start/busy/done, binary-search, illegal-command tests
- [ ] Controller program verified against the FSM reference on identical stimulus
- [ ] FSM-only fallback build exists and passes regression
- [ ] End-to-end regression maps known sensor impedances to expected reported codes
- [ ] Host transaction script starts, configures, reads status/results, handles reset and error cases
- [ ] Autonomous mode completes M pairs and reports without host intervention
- [ ] E_meas and sleep current estimated post-layout and recorded against the §2.3 model
- [ ] Analog test paths observable and isolated during normal operation
- [ ] Power-up, power-down, abort, and reset states safe
- [ ] Pad ring, supply returns, floorplan, DRC, LVS, ERC/antenna, extracted critical paths closed
- [ ] Source, models, scripts, reports, plots, checksums, and bring-up documentation archived

---

## References

[1] Senior Design Team, *Mixed-Signal Impedance Sensing ASIC for Battery-Free Agricultural IoT Nodes*, Senior Design Project Proposal, 2026.

[2] Senior Design Team, *One-Channel Mixed-Signal Impedance Front End*, High-Level Design Document, Rev 3.0, September 2026.

[3] *Reference RISC-V core for the on-die controller — source, version, and license to be filled in.*

[4] O. Kindgren, *SERV — the SErial RISC-V CPU*, https://github.com/olofk/serv — fallback core if the area budget does not accommodate [3].

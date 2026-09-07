# AgriASIC Digital MAS (Micro-Architecture Specification)

## 1. Document Control
- Project: Single-Die Impedance Sensing Node — low-power agricultural impedance sensing (senior design)
- Subsystem: Digital control, sequencing, and SPI control plane
- Process: TSMC 180nm MS/RF-G, Muse shared block
- RTL: `github.com/krishkc5/agrasic`, `agriasic_digital_v2`
- Team:
  - Krishna Chemudupati — analog front end
  - Vidhu Bulumulla — SAR ADC
  - Taarana Jammula — digital, integration *(owner of this document)*
- **Architecture baseline: `agriasic_rev43_phase_locked_design.pdf` (Rev 4.3), which supersedes Rev 4.2 of September 2026.** Where this MAS and that document disagree, the Rev 4.3 document wins and this one is wrong.
- Other basis documents:
  - agriasic_high_level_design_rev4_integrated_node.md
  - agriasic_digital_implementation_plan.md
  - agriasic_digital_timing_checklist.md
  - interface_contract.md
- MAS version: v0.14 (Rev 4.3 Phases 7-8 complete, with two items honestly left open: firmware now sweeps the real 3 frequency points and stores per-point I/Q in scratch RAM (Phase 7.1/7.2), but temperature sensing has no digital or analog RTL to read yet (Phase 7.3, blocked) and there is no host-facing path for these swept results on any chip variant that exists in this tree (new **GAP-11**, found while implementing this). Verification plan items V-1, V-2, V-4, V-5 closed with real regression coverage (a practical, documented, non-exhaustive settle x conv grid; edge-case accumulator checks including the true M=64 saturating case; formal `assert property` for the shadow-register and phase-match contracts); V-3 confirmed superseded. Sections 7.1, 10, 11, 12, 13, 14 updated)
- Date: 2026-09-06
- Trial GDS: 2026-11-18

### 1.1 How to read this document

An earlier draft of this MAS described the Rev 4.3 target architecture and the
Rev 4.2 mechanisms in the same voice, with no way to tell which sentences
described silicon-bound RTL and which described intent. That ambiguity is what
made a parallel branch look like an upgrade when it was in fact a regression.

Every architectural statement in this revision therefore carries a status tag:

| Tag | Meaning |
|---|---|
| **[IMPL]** | Implemented in RTL and covered by a passing regression |
| **[SPEC]** | Specified for Rev 4.3, **not yet in RTL** |
| **[GAP]** | Known conflict or unresolved question — read before designing against it |

**Current RTL state in one line:** the design is Rev 4.2 plus the three Rev 4.3
defect fixes (section 5), plus **Phases 1 through 8 of the Rev 4.3
restructure**: the analog boundary is frozen — break-before-make excitation
drive (`exc_drive_p_o`/`exc_drive_n_o`), the SAR bit-trial interface
(`adc_dac_o`/`adc_comp_i`, replacing `adc_code_i` entirely), and `miso_oe_o` —
clock/reset discipline is in place — a 2FF reset synchronizer per
chip-boundary top, and a verified core clock enable idle 93% of the time
during a real measurement (section 6.12) — SPI lives **entirely** in
the clk domain, with zero remaining exceptions to the single-clock-domain rule
(section 6.7) — excitation is **free-running and phase-locked**:
`excitation_ctrl` runs off the master clock alone, exports a 16-state phase
counter, and `measurement_fsm` strobes a sample whenever that counter matches
the phase it wants (section 6.1-6.4) — the FSM accumulates **both I and Q**
(section 6.1): four phase-index watch points (0/90/180/270 degrees), two
signed accumulators, and shadow-register snapshotting so a host read mid-run
can never see a partial sum — and the **SPI register map is now the Rev 4.3
target layout** (section 7.1): `REG_FREQ_SEL` is a 2-bit selector (0/1/2 ->
10 MHz/100 kHz/1 kHz), closing GAP-1's remaining half on the SPI and
programming-interface paths; `REG_RESULT_IDX`/`REG_RESULT_DATA` implement the
indexed byte-vector readout the design doc specifies, serving real I/Q data
at indices 0-3 and honest zero placeholders at 4-15 pending Phase 7;
`REG_ID` and a `REG_STATUS` overrange bit are new. **One register in the
target map, `REG_PHASE_IDX`, is reserved but deliberately not wired to
anything** — its intended semantics don't reconcile cleanly with how Phase 5
actually built four fixed, 90-degree-spaced sample points, and building
speculative RTL against a guessed meaning for a silicon-bound register was
judged worse than leaving it honest (GAP-10). **Firmware now runs the real
3-point frequency sweep** (section 7.1, Phase 7): `fw.c` writes `REG_DIVIDER`
to N=1/100/10000 in turn (the exact same three presets `REG_FREQ_SEL`
exposes to SPI), averages measurements at each, and stores per-point I/Q
into scratch RAM — verified in simulation for the real 1 kHz point, not a
stand-in value (section 10, Phase 7). Two things are honestly still open,
not silently skipped: temperature sensing (Phase 7.3) has no RTL to read
from, digital or analog, anywhere in this tree; and there is no path for
these swept results to reach a real external host on any chip variant that
exists today — `agriasic_digital_rv32i_top` has no host-facing interface at
all, and `agriasic_digital_spi_top` has no RV32I core, so Phase 6's indexed
readout and Phase 7's sweep have never been connected to each other
(**GAP-11**). Verification (Phase 8) closed four of five outstanding plan
items with real, run regression coverage: a practical settle x conv grid
(V-1), edge-case accumulator checks up to the true M=64 saturating case
(V-2), and formal `assert property` statements for the shadow-register and
exact-phase-match contracts (V-4, V-5) — V-3 was already confirmed
superseded.

### 1.2 Plain-language overview

*Everything else in this document is written for engineers. This section isn't
— it's for anyone who wants to understand what the chip does without reading
circuit diagrams.*

**The problem.** A farmer wants to know two things about their soil: how much
water is in it, and how much fertilizer or nutrient is in it. A single quick
measurement can't tell those apart — both make soil conduct electricity better,
so a naive reading just says "more conductive" without saying why.

**The trick.** Water and dissolved nutrients respond differently depending on
*how fast* you wiggle an electrical signal at them. Nutrients (dissolved salts)
respond strongly to a slow wiggle but barely react to a fast one. Water responds
about the same either way. So instead of one reading, the chip takes three —
one slow, one medium, one fast — by pushing a tiny, harmless electrical current
back and forth through two probes stuck in the soil. Comparing how the readings
change across the three speeds is what separates "this is wet" from "this is
salty."

Think of it like knocking on a wall to find a stud: one knock tells you
"something's there," but knocking at different spots and listening to how the
*sound* changes tells you whether it's wood or drywall. Same idea — different
"knocking speeds" instead of different spots.

**Why forwards and backwards.** At each speed, the chip doesn't just push
current one way — it pushes it, measures, then reverses and measures again. Any
error that's baked into the chip's own electronics (a tiny built-in bias, like a
scale that's slightly off before you even put anything on it) shows up
identically in both directions and cancels out when the two readings are
subtracted. Only the part that actually came from the soil survives. It's the
same reason a photograph taken with the light source moved to the opposite side
can reveal a scratch a single photo would hide — comparing the two shots cancels
out whatever doesn't depend on which side the light came from, and what's left
is the real feature.

**What this document's part of the chip actually does.** This MAS covers the
*digital* half of the chip — not the part that senses the soil, but the part
that runs the show around it. Three jobs, and only three:

1. **Keep perfect time.** Push the current one way, wait exactly long enough for
   it to settle, take a reading, flip it, wait, read again — over and over,
   thousands of times, with no variation in timing from one repetition to the
   next. A person or a general-purpose computer program couldn't do this
   reliably; the timing has to be built into the hardware itself, like a
   metronome that can't skip a beat.
2. **Add the readings up cleanly.** Repeating the same measurement many times
   and averaging cancels random noise, the same way asking ten people to guess
   the weight of an object and averaging their guesses beats any single guess.
   This part just needs to add correctly, without accidentally throwing away
   precision along the way.
3. **Hand the results to the outside world.** Once the readings are collected,
   the chip talks over a simple four-wire connection to whatever is asking for
   the data — a small computer, a gateway, eventually an app. It does not decide
   what the numbers *mean*. Turning "these raw numbers" into "your soil is 30%
   water with moderate nutrient levels" happens outside the chip, in software,
   afterward.

**Two workers inside the digital half.** There's a fast, single-minded worker
that does nothing but the precise back-and-forth timing in job 1 — it has to
react in fractions of a millionth of a second and never gets to think or make
decisions, only follow the same fixed rhythm exactly. And there's a slower,
smarter worker — a tiny built-in computer — that decides *when* to run a
measurement, at *which* of the three speeds, *how many times* to repeat it, and
then packages the results neatly before handing them off. If the project ever
needs to cut scope under schedule pressure, the smart worker can be removed
entirely and replaced with a fixed, simpler set of instructions — the
measurement itself doesn't change, only the ability to reprogram *when and how
often* it runs.

**What comes out the other end.** A small set of numbers per measurement cycle,
readable over that four-wire connection: the strength of the "water-like"
response and the "nutrient-like" response, for each of the three speeds, plus
the chip's own temperature (temperature affects the readings and has to be
accounted for). That's it — everything past that point, including the actual
moisture and nutrient percentages a farmer would look at, is somebody else's
software running elsewhere.

![plain_language_overview](diagrams/plain_language_overview.svg)

#### 1.2.1 The analog/digital boundary, in detail

The rest of this section zooms into one specific thing: the handful of wires
where the digital half described above actually touches the analog sensing
circuitry, and exactly what the three digital components on this side of that
boundary do with them. This is more detailed than the rest of section 1.2 —
it names real signals — but still written for someone who wants to
understand the mechanism, not read Verilog.

**As of Rev 4.3 Phase 1, exactly six wires cross the boundary** — five
carrying digital's instructions out, one carrying analog's answer back. (A
seventh output, `conv_start_o`, is kept on the pin list for compatibility and
host-side monitoring, but it fires in the exact same instant as one of the
six below and carries no information of its own — more on that at the end of
this subsection.)

![analog_digital_signals](diagrams/analog_digital_signals.svg)

**1. The two drive wires (`exc_drive_p_o`, `exc_drive_n_o`) — pushing the
current.** Only one is ever switched on; the other is off. Think of a
two-way light switch, except this one has a deliberate, brief instant where
*both* sides are off every time it flips — never an instant where both are
on. That's not caution for its own sake: with a single wire carrying two
voltage levels instead, a switching glitch could momentarily connect both
directions together. Two separate wires, built so both-on is structurally
unreachable, make that a physical impossibility rather than something that's
merely unlikely. `excitation_ctrl` owns these two wires, and also runs the
timer that waits for the freshly-flipped current to settle before anything
downstream is allowed to read it.

**2. The enable wire (`adc_enable_o`) — waking the sensing circuit up.**
Held on for the entire duration of one reading, then switched off — the
low-power equivalent of a sensor that sleeps between uses instead of running
continuously. `sar_controller` owns this wire.

**3. The sample wire (`adc_sample_o`) — freezing the instant.** A single
short pulse telling analog "capture whatever you're seeing right now, and
hold that value steady." This matters because figuring out the exact value
takes the eight-round back-and-forth described next, and the input has to be
a still target throughout all eight rounds, not something that keeps
drifting while digital is still asking about it. `sar_controller` owns this
wire too.

**4. The guess wires (`adc_dac_o[7:0]`) and the answer wire (`adc_comp_i`) —
the guessing game.** This is the part worth the most explanation, because
it's the part that actually turns a held analog voltage into a digital
number. Digital doesn't ask analog "what's the value" and get a number back
directly — there's no wire that could carry that. Instead, it plays a
guessing game: digital proposes an 8-bit number on `adc_dac_o`, and analog
answers back on the single `adc_comp_i` wire with one bit — 1 meaning "the
true value is at least that," 0 meaning "it's less than that." Eight rounds
of this, each round refining one bit of the guess from most significant to
least, are enough to pin down the exact 8-bit answer out of all 256
possibilities — the same logic as a "guess my number between 0 and 255" game
where every answer eliminates half of what's left, so eight guesses always
finish it. The worked example in the illustration is a real one: a true
reading of 180 is found in exactly eight rounds — 128, then 192 (too high,
discarded), then 160, 176, 184 (too high, discarded), 180, 182 (too high,
discarded), 181 (too high, discarded) — landing on exactly 180.
`sar_controller` runs this whole exchange and owns both wires.

**Why the guess-and-check design instead of a wire that just reports the
number directly:** this is what a real analog-to-digital converter is
underneath, on any chip — there is no physical wire that carries an
arbitrary continuous voltage as a clean 8-bit digital number. Something has
to do the converting, one bit at a time, through exactly this kind of
back-and-forth. Which side runs that back-and-forth (a smart analog block
that does it internally, or the digital side driving it step by step through
`adc_dac_o`/`adc_comp_i`) is a design choice — Rev 4.3 moved the bit-trial
sequencing into digital, which is why `sar_controller` is more involved than
it used to be.

**The conductor: `measurement_fsm`.** It doesn't own any of the six wires
directly, and — unlike an earlier version of this design — it never tells
`excitation_ctrl` to flip anything either. `excitation_ctrl` pushes current
back and forth on its own, continuously, the moment it's turned on; the FSM's
job is to **watch** that back-and-forth and grab a reading at four specific
instants in each cycle, for one complete reading:

1. Watch the free-running current until it's at the point of the cycle
   labeled "0 degrees," then run the guessing game through `sar_controller` →
   get one 8-bit number, D(0)
2. Watch until the current has reversed to "180 degrees," then read again →
   get D(180)
3. Subtract (D(0) minus D(180)) and add the result into one running total —
   call it "I"
4. Watch for "90 degrees" (a quarter-cycle offset from step 1) → get D(90)
5. Watch for "270 degrees" → get D(270)
6. Subtract (D(90) minus D(270)) and add the result into a **second** running
   total — call it "Q"

Steps 1-6 repeat a few dozen times (the exact count is configurable), and the
two running totals — not each individual reading — are what eventually reach
the outside world over SPI. The subtraction in steps 3 and 6 is where the
"photograph from two sides" trick from earlier in this section actually
happens in wire terms: whatever bias the chip's own electronics contribute
shows up identically in both readings of a pair, so it cancels; only the part
that came from the soil survives into the running totals. Two totals, not
one, is what lets the chip tell water and salt apart (section 3.1) — I and Q
respond differently to the same soil, the way a wall sounds different when
you knock at different spots.

**The loose end: `conv_start_o`.** It's a real pin, and it's not one of the
six — analog doesn't need it. `sar_controller` asserts it in the exact same
clock cycle as `adc_sample_o`, from the exact same trigger, so it carries no
information `adc_sample_o` doesn't already carry. It's kept on the interface
for two reasons: it matches the pin layout of the pre-Phase-1 design, and an
external host or logic analyzer watching the chip from outside can use it as
a simple "a conversion just started" marker without needing to know about the
sample/hold semantics specifically.

For the RTL-level version of everything above — exact port names, timing
diagrams, and what's implemented versus still specified — see sections 4.6,
6.1, 6.3, 6.5–6.6, and the cycle-by-cycle trace in 6.11.

The rest of this document is the engineering detail behind those three jobs:
exactly how the timing is built (section 6), what the wires and registers look
like (sections 4.6, 7), and what's already working versus still being designed
(the **[IMPL]** / **[SPEC]** tags throughout).

---

## 2. Purpose and Scope
This MAS defines the digital micro-architecture for measurement sequencing,
excitation/SAR handshake control, result accumulation, and SPI-visible
status/control behavior. It captures both implemented behavior and
requirement-driven acceptance criteria.

In scope:
- measurement_fsm, excitation_ctrl, sar_controller
- SPI slave and SPI protocol wrapper behavior
- register map, status/error semantics, and protocol framing
- reset, busy/done, and result observability contracts
- the RV32I policy shell and its port-compatible microsequencer fallback

Out of scope for this MAS revision:
- analog circuit implementation details
- multi-channel muxing
- on-die excitation amplitude DAC
- post-silicon calibration algorithm optimization
- magnitude, phase and calibration math (computed on the host, not on die)

---

## 3. Measurement Method and Operating Model

### 3.1 What the chip measures **[IMPL]** four-phase sampling and both accumulators, Phase 5 — **[SPEC]** the 3-frequency sweep, Phase 7
Excitation is a bipolar square wave across two soil electrodes. Return current
passes through an on-die TIA into an 8-bit SAR ADC. Ionic conduction carries a
1/w factor and fades with frequency; water-driven permittivity does not. The
chip is meant to sweep three frequency points (Phase 7, not yet built) and, at
each point, samples four phase offsets to recover the in-phase and quadrature
components:

```text
I = (D(0deg)  - D(180deg)) / 2
Q = (D(90deg) - D(270deg)) / 2
```

Opposite-phase subtraction cancels static TIA and ADC offset. The `/2` and all
magnitude/phase/calibration math are **host-side**; the die accumulates raw
signed differences only (section 6.4). The four-phase sampling and the two
raw accumulators themselves are implemented and verified as of Phase 5
(section 6.1); what remains **[SPEC]** is sweeping the divider across three
frequency points automatically — today the host sets one divider value, runs
one measurement, and gets one (I, Q) pair back.

### 3.2 Equivalent-time sampling **[IMPL]** — Phase 4
Excitation is free-running and stationary: `excitation_ctrl` runs off the
master clock alone and never waits for the FSM. The ADC takes one phase point
per excitation cycle, and `measurement_fsm` samples that same point across many
cycles (once per pair), so a single SAR conversion (24+ clock cycles) does not
have to fit inside a half-cycle — the phase generator has already moved on to
later phases by the time a conversion finishes, and the next pair simply waits
for that phase to come back around. This is what makes a 10 MHz excitation
point tractable with an 8-bit SAR at 160 MHz. Verified by the phase-match
assertion in `tb/smoke/tb_agriasic_digital_top.sv` (section 6.11): every sample
lands on the exact phase index it was supposed to, not just "sometime during
the right half-cycle."

### 3.3 Two control loops
| Loop | Period | Nature | Owner |
|---|---|---|---|
| Inner | 100 ns at 10 MHz excitation | Hard real-time: phase strobe, 8 bit trials, signed accumulate | measurement_fsm (always hardware) |
| Outer | 10–100 ms | Soft: frequency selection, settle intervals, M, temperature, result packing, SPI | RV32I core |

**Software decides policy; hardware keeps time.** The FSM never gets a program
counter. Two reasons this partition is not negotiable:

- **Jitter is measurement noise.** The conversion fires a fixed number of cycles
  after the phase strobe, partway up the analog settling curve. If that instant
  moved with instruction timing, the ADC code would move with it — noise
  indistinguishable from signal.
- **The ± chop needs time symmetry.** `(D+ − D−)/2` cancels offset and drift only
  if both phases are timed identically. The FSM gives that structurally.

The core is clock-enabled off during accumulation bursts **[SPEC]**, which is
also the low-power state for a solar/battery node.

---

## 4. Top-Level Digital Architecture

### 4.1 Core partition **[IMPL]**
- Measurement sequencer: hardwired finite-state machine
- Excitation control: divider, phase control, settle counter
- SAR control: conversion request/latency/capture path
- SPI control plane: mode-0 slave + byte CDC + protocol decode
- Register interface: configuration writes and status/result mirrors

### 4.2 Control shell and descope path **[IMPL]**
Two shells exist behind an **identical 14-port interface**, verified port-for-port:

- `agriasic_rv32i_control_shell.sv` — RV32IM core + ROM + MMIO bridge
- `agriasic_rv32i_control_shell.sv.orig` — microsequencer stand-in

Either can be instantiated without touching `agriasic_digital_rv32i_top.sv`, so
the core can be dropped as a schedule descope without changing measurement
behavior. **This port identity is a standing constraint: any Rev 4.3 change to
one shell must be mirrored in the other.**

### 4.3 Phase-locked control partition **[IMPL]** (phase-lock, I/Q, and register map, Phases 4-6) / **[SPEC]** (frequency sweep, Phase 7)
Rev 4.3 inverts excitation control, and Phase 4 built the inversion. Under Rev
4.2, the FSM commanded each polarity flip, so excitation frequency was an
*emergent side effect* of the settle and conv register values — you could not
set a frequency, only discover one. As implemented now:

- The excitation generator (`excitation_ctrl`) is **free-running** from the
  master clock — it never waits on the FSM for anything.
- It exports a **16-state phase counter** (`phase_index_o[3:0]`) to the FSM,
  free-running 0-15 in lockstep with the divider.
- The FSM (`measurement_fsm`) strobes the sampler the cycle the counter
  matches the phase it wants — **four** phase indices now (0, 4, 8, 12 —
  0/90/180/270 degrees, Phase 5), not two — it no longer commands anything,
  it only watches.

```text
f_exc = f_clk / (16 * N),   f_clk = 160 MHz
```

verified exactly (not approximately) by `tb_excitation_drive.sv`: N=1 gives 16
clk cycles/period, N=5 gives 80, N=13 gives 208 — all exact, with no off-by-one
(see section 10, Phase 4 for the historical bug this fixes).

The measurement FSM is promoted from descope fallback to a permanent block
running in parallel with the core.

Functional split as implemented:

1. **RV32I core + ROM** — sweep program, frequency selection, settle
   intervals, M, temperature read, result packing, SPI service, sticky error
   and reset policy. The frequency **sweep** (three points) and temperature
   read are still `[SPEC]`, Phase 7 — today firmware sets one divider value
   and reads back one (I, Q) pair (section 3.1).
2. **Measurement FSM** — divider load (passthrough to `excitation_ctrl`), phase
   match detection at all four I/Q phase indices, sample strobe generation,
   ADC start and busy handshake, **two** raw accumulators (I and Q), shadow
   snapshotting on completion, cycle counting, done flag. All of this is
   `[IMPL]` as of Phase 5 (section 6.1) — nothing about the FSM itself remains
   `[SPEC]`.
3. **Peripheral register set** — the Rev 4.3 target register map itself is
   `[IMPL]` as of Phase 6 (section 7.1): `REG_FREQ_SEL` selector encoding,
   indexed `REG_RESULT_IDX`/`REG_RESULT_DATA` readout, `REG_ID`, and a
   `REG_STATUS` overrange bit. What's still `[SPEC]` is not the register
   *mechanism* but the *data* Phase 7 would put behind it — indices 4-15 of
   the result vector read as honest zero today because there is no second or
   third frequency point, and no temperature sensing, anywhere in the digital
   RTL yet. One register, `REG_PHASE_IDX`, is reserved in the map but not
   wired to anything — see GAP-10.

**Rev 4.3 target architecture** — the phase reference from the excitation
generator to the FSM is the key structural change, and it is now real RTL:

![agriasic_rev43_architecture](diagrams/agriasic_rev43_architecture.svg)

The control inversion itself, Rev 4.2 against Rev 4.3, with the phase-lock
strobe mechanism:

![rev43_excitation_phase_lock](diagrams/rev43_excitation_phase_lock.svg)

**Diagrams redrawn for this MAS revision.** Both diagrams above were
originally drawn against the Rev 4.3 *target* description before Phase 4
existed in RTL. They have been updated to reflect the implementation: the
architecture diagram now marks itself `[IMPL as of Phase 6]`, labels the
excitation generator as purely digital (Taarana's ownership, not joint with
analog), and notes that phase selection (unlike frequency selection) remains
unwired per GAP-10. The phase-lock diagram's strobe annotation now correctly
says the four watched phase indices (0/4/8/12) are fixed in RTL, not a
host-settable `REG_PHASE_IDX` value. Neither diagram attempts to show the
FSM's exact 14-state sequence
(`S_SETTLE -> S_WAIT_0 -> S_SAMPLE_0 -> S_WAIT_180 -> S_SAMPLE_180 ->
S_ACCUM_I -> S_WAIT_90 -> S_SAMPLE_90 -> S_WAIT_270 -> S_SAMPLE_270 ->
S_ACCUM_Q -> S_LOOP`) — that level of detail is what
`measurement_fsm_block_diagram.svg` (section 6.1) is for; these two stay at
the architecture level by design.

The **[IMPL]** control architecture as currently built is a separate diagram —
it predates Phase 4 and does not show the phase reference:

![agriasic_rv32i_control_architecture](diagrams/modules/agriasic_rv32i_control_architecture.svg)

### 4.4 External interface assumptions
- External references remain off-die (VREFH, VREFL, VCM, V_EXC)
- External master clock source, 160 MHz
- Host is optional for measurement execution, used for setup/readback

### 4.5 Architecture diagrams
- High-level dataflow: [diagrams/agriasic_digital_dataflow_hl.svg](diagrams/agriasic_digital_dataflow_hl.svg)

![agriasic_digital_dataflow_hl](diagrams/agriasic_digital_dataflow_hl.svg)

- Top integration block: [diagrams/modules/agriasic_digital_top_block_diagram.svg](diagrams/modules/agriasic_digital_top_block_diagram.svg)

![agriasic_digital_top_block_diagram](diagrams/modules/agriasic_digital_top_block_diagram.svg)

- Verilog orchestration flow: [diagrams/agriasic_digital_verilog_orchestration_flow.svg](diagrams/agriasic_digital_verilog_orchestration_flow.svg)

![agriasic_digital_verilog_orchestration_flow](diagrams/agriasic_digital_verilog_orchestration_flow.svg)

### 4.6 Data flow through the top-level wrappers **[IMPL]**

Four modules in the repository are named `*_top`. Only one of them contains the
measurement engine; the other three wrap it and differ only in **who supplies
the configuration**. This is the layering to keep straight when reading the RTL.

#### 4.6.1 `agriasic_digital_top` — the measurement engine itself

This is the innermost module — `excitation_ctrl` + `sar_controller` +
`measurement_fsm` wired together (section 6). Every other top instantiates this
one. Its full port list is the entire digital/analog contract as implemented
today:

```text
                  ┌─────────────────────────────────────────┐
      start   ──▶ │                                          │ ──▶ exc_drive_p_o
cfg_pair_log2 ──▶ │                                          │ ──▶ exc_drive_n_o
 cfg_settle   ──▶ │                                          │ ──▶ conv_start_o
 cfg_divider  ──▶ │           agriasic_digital_top           │ ──▶ adc_enable_o
 cfg_conv     ──▶ │                                          │ ──▶ adc_sample_o
                  │                                          │ ──▶ adc_dac_o[7:0]
  adc_comp_i  ──▶ │                                          │ ──▶ busy_o
                  │                                          │ ──▶ done_o
                  │                                          │ ──▶ result_i_o[15:0]  (Phase 5)
                  │                                          │ ──▶ result_q_o[15:0]  (Phase 5)
                  └─────────────────────────────────────────┘
```

**Six** signals cross the digital/analog boundary as of Rev 4.3 Phase 1 (up
from three pre-Phase-1): `exc_drive_p_o`, `exc_drive_n_o`, `adc_enable_o`,
`adc_sample_o` and `adc_dac_o[7:0]` go out to the analog front end;
`adc_comp_i` comes back in. `exc_pol_o` and `adc_code_i` no longer exist — see
section 6.3/6.6 for what replaced them, and section 1.2.1 for what each of
these six signals actually is and does, in plain language.

`conv_start_o` is **not** one of the six. It is still a real output pin, kept
for pin-compatibility with the pre-Phase-1 interface and for host-side
monitoring/debug, but it carries no information `adc_sample_o` doesn't
already carry — `sar_controller` asserts both in the exact same cycle, from
the exact same trigger (accepting a new sample request). Analog does not need
to consume it; a monitoring host or logic analyzer might.

Every other port on this module is either configuration coming in or
status/result going out, and all of it stays digital.

#### 4.6.2 The three wrappers

| Top | Adds | Who decides the recipe | Typical user |
|---|---|---|---|
| `agriasic_digital_top` | nothing — config ports are parallel inputs | whoever wires the pins | testbenches |
| `agriasic_digital_spi_top` | `sclk_i`, `cs_n_i`, `mosi_i`, `miso_o` | an external host, via SPI writes into `regfile` (section 6.10) | production host, bring-up |
| `agriasic_digital_programming_top` | `prog_cfg_we_i`, `prog_cfg_addr_i[1:0]`, `prog_cfg_data_i[7:0]`, `prog_start_i` | a firmware controller writing a compact register-poke interface | intermediate integration step |
| `agriasic_digital_rv32i_top` | the RV32IM core + ROM + `agriasic_rv32i_control_shell` (section 4.2) | on-chip firmware (`fw/fw.c`) | the chip as taped out |

In every case, the four config values — `cfg_pair_log2`, `cfg_settle_cycles`,
`cfg_exc_divider`, `cfg_conv_cycles` — and the `start` pulse are what actually
reach `agriasic_digital_top`. The wrappers only change **how those four values
get written**. `agriasic_digital_rv32i_top` additionally re-exposes them as
outputs (`cfg_*_o`), purely for debug and bring-up visibility — the core does not
read them back to make decisions.

Because `agriasic_digital_rv32i_top` and the microsequencer-backed shell
(section 4.2) are port-identical, swapping which controller drives these same
four wires is a file substitution, not a top-level rewire.

---

## 5. Defect Register

Three defects were reproduced in simulation and fixed before any restructuring.
All three were present in every branch of the design.

| # | Defect | Root cause | Fix | Status |
|---|---|---|---|---|
| D-1 | Settle interval never applied. `settle=0` and `settle=2` produced byte-identical 49-cycle runs | FSM held `exc_set_phase_o` for the whole settle state; `excitation_ctrl` reloaded on the level. `settled_o` is registered, so the FSM read the stale 1 from the previous phase and left before the countdown started | Phase command is rising-edge triggered in `excitation_ctrl`; FSM issues it from a dedicated one-cycle state | **Fixed [IMPL]** |
| D-2 | Deadlock whenever the settle countdown outlived the settle state. `settle>=5, conv=1` hung forever. Every settle value needed at 1 kHz sat in the hang region | The held command also pinned `settled_o` low, so the countdown branch never ran | Same change — the level no longer reloads the counter | **Fixed [IMPL]** |
| D-3 | `pair_delta` arithmetic-right-shifted each pair before accumulating, destroying averaging gain and adding sign-dependent bias. At M=8, a true difference of +1 accumulated to 0 (ideal +4) and −1 accumulated to −8 (ideal −4), because `>>>` rounds toward negative infinity | Per-pair scaling in hardware | Accumulate the raw signed difference; scale on the host. M clamped to 64 | **Fixed [IMPL]** |

### 5.1 Post-fix measured behavior **[IMPL]**
Settle now scales exactly linearly — 57 cycles at `settle=0`, +8 cycles per settle
count (8 settle intervals per 4-pair run):

| settle | conv | Before | After |
|---|---|---|---|
| 0 | 1 | 49 cycles | 57 |
| 2 | 1 | 49 cycles (no effect) | 73 |
| 5 | 1 | **hang** | 97 |
| 20 | 1 | **hang** | 217 |

Locked in by `tb/tb_settle_timing.sv`, which asserts monotonicity rather than
hardcoded cycle counts so it survives retiming.

### 5.2 Host contract change from D-3 **[IMPL]**
`REG_RESULT` is now `sum(D+ − D−)` over M pairs, **not** `sum((D+ − D−)/2)`.
Hosts must divide by M themselves. Every previously observed value doubles.
Worst case is `64 × 255 = 16320`, inside signed 16-bit.

### 5.3 Regression coverage caveat **[IMPL]**
After the D-1/D-2 fix, the smoke comparison against `sar_controller.sv.orig` no
longer distinguishes the pre-fix controller: both legs report 480 at the smoke
test's `settle=2, conv=1`. The pre-fix controller is still broken — at `settle=0`
it returns 60 instead of 480 — but that configuration happens to close the window
in which its missing `!sample_done_o` guard launches a spurious second
conversion. **Treat `tb_settle_timing.sv`, not the smoke comparison, as the test
covering that bug.**

---

## 6. Micro-Architecture by Module

### 6.1 measurement_fsm **[IMPL]** — I/Q accumulation added in Rev 4.3 Phase 5
Responsibilities:
- Accept start command in idle
- Wait out the settle interval, then watch the free-running phase counter for
  a match — **it never commands a polarity flip; it only watches**
- Sample D(0°) and D(180°) into the I accumulator, D(90°) and D(270°) into
  the Q accumulator — **four sample points per pair, not two**
- Wait on `sar_done_i` to know a bit-trial conversion has finished, once per
  sample point (four times per pair)
- Accumulate the raw signed per-pair difference into **two** independent
  accumulators
- Snapshot both accumulators into shadow registers the host actually reads,
  on the one cycle the run completes — never while `busy_o` is high
- Repeat until `pair_target` reached, then assert done

States (Phase 5 renames and extends the Phase 4 state list — every state
after `S_WAIT_180` is new or renamed to keep the I/Q split unambiguous):

```text
S_IDLE
S_SETTLE                        -- counts period_tick_i pulses, not raw cycles
S_WAIT_0   -> S_SAMPLE_0         -- I, positive term: phase 0   (0 deg)
S_WAIT_180 -> S_SAMPLE_180       -- I, negative term: phase 8   (180 deg)
S_ACCUM_I                        -- i_acc_q += D(0) - D(180)
S_WAIT_90  -> S_SAMPLE_90        -- Q, positive term: phase 4   (90 deg)
S_WAIT_270 -> S_SAMPLE_270       -- Q, negative term: phase 12  (270 deg)
S_ACCUM_Q                        -- q_acc_q += D(90) - D(270)
S_LOOP -> S_DONE
```

Each `S_WAIT_*` state is a combinational watch: the moment `phase_index_i`
equals the target, `sample_req_o`/`sample_phase_o` fire **that same cycle**
— including the case where the target already matches on the very cycle the
watch state is entered, correct for equivalent-time sampling (section 3.2).
The corresponding `S_SAMPLE_*` state then holds while the SAR conversion that
request triggered runs to completion (`sar_done_i`).

**One design choice worth stating plainly: `sar_controller`'s D+/D− capture
slots are reused as generic storage, not extended to four slots.**
`sample_phase_o=1` always means "capture into the d_plus slot," `=0` means
"capture into d_minus," regardless of which channel that slot is about to
feed — `sar_controller` has no notion of I or Q at all (section 6.6, unchanged
by Phase 5). D(0°) lands in d_plus, D(180°) overwrites d_minus, and
`S_ACCUM_I` reads both before either slot is reused for D(90°)/D(270°). This
means the FSM's own sequencing — not any new hardware in `sar_controller` — is
what keeps the two channels from ever using stale data.

**Shadow-register snapshotting (section 9.3's "accumulator snapshot"
contract, first actually implemented here):** the live accumulators
(`i_acc_q`, `q_acc_q`) update mid-run, one channel at a time, while `busy_o`
is high. What the host reads (`result_i_o`, `result_q_o`) is a **separate**
pair of shadow registers (`i_shadow_q`, `q_shadow_q`) that latch the live
accumulators' final values only on the `S_LOOP -> S_DONE` transition — the one
and only cycle `busy_o` drops from 1 to 0. A host reading mid-run therefore
always sees the *previous* run's complete result, never a partial sum from
the run in progress. This did not exist for the single-accumulator Phase
1-4 design — `result_o` there was wired straight to the live accumulator.

`settle_cycles_i` is unchanged from Phase 4: it counts **excitation periods**
(`period_tick_i` pulses), not raw cycles. `tb_settle_timing.sv` confirms the
unit is still monotonic and hang-free with the four-phase sequencing added
(section 10, Phase 5).

Configuration dependencies:
- `pair_log2` selects M = 2^pair_log2, **clamped to 64** — applies to both
  accumulators independently (section 9.3)

![measurement_fsm_block_diagram](diagrams/modules/measurement_fsm_block_diagram.svg)
*(redrawn for this MAS revision: shows all 14 states across both channels,
the sar_controller slot-reuse mechanism, the shadow-register timing, and the
real cycle numbers from the section 6.11 trace.)*

### 6.2 measurement_fsm, Rev 4.3 remaining target — nothing outstanding here
Section 6.1 now covers everything this section used to specify for the FSM
itself: four-phase watching, two accumulators, and shadow-register
snapshotting are all `[IMPL]` as of Phase 5. What remains **[SPEC]** at the
system level is not a measurement_fsm change at all — it's Phase 6's register
map (indexed multi-frequency-point readout, section 7.2) and Phase 7's
firmware sweep across three divider values (section 3.1). This section is
kept as a placeholder heading rather than renumbering everything after it;
future FSM-specific target notes belong here.

### 6.3 excitation_ctrl **[IMPL]** — rewritten in Rev 4.3 Phase 4
Responsibilities:
- Run a **free-running 14-bit divider** and **4-bit phase counter**, both
  driven only by `enable_i` and `divider_i` — there is no command input from
  the FSM at all any more, not even implicitly
- Export the phase counter as `phase_index_o[3:0]`, free-running 0-15 forever
  while enabled, and a `period_tick_o` pulse once per full 16-phase period
- Drive the excitation electrodes through **two break-before-make outputs**,
  `drive_p_o` / `drive_n_o` (unchanged from Phase 1) as a pure combinational
  function of the current phase value

Behavior:
- `enable_i=0` drives a deterministic idle state (both drive lines low, phase
  counter held at 0)
- Phase encoding: **0-6 drive positive**, **7 is dead time**, **8-14 drive
  negative**, **15 is dead time** — 7 phase states per polarity half, exactly
  equal, and exactly one dead state between each transition
- `{drive_p_o, drive_n_o} = 2'b11` remains **structurally unreachable**:
  `drive_p_o` and `drive_n_o` are two mutually exclusive combinational ranges
  of the same phase counter, so no phase value can satisfy both — this is a
  property of the circuit, not a simulation result. Re-verified for the
  free-running design by `tb_excitation_drive.sv`'s `assert property` (below)
- `divider_i` (14 bits) is compared against an *effective* divider that floors
  at 1, so `divider_i=0` cannot stall the counter
- The tick comparison is `div_cnt_q == divider_i - 1`, **not** `>=` as in the
  pre-Phase-4 design — see the off-by-one note below

**Off-by-one bug found and fixed, not carried forward.** The pre-Phase-4
`excitation_ctrl` used a `>=`-style tick comparison that actually produced a
tick every `divider_i + 1` cycles, not `divider_i` cycles — harmless when
`divider_i` only qualitatively gated a "has enough time passed" settle check,
but unacceptable once `divider_i` must be a precise, host-computable N in
`f_exc = f_clk / (16·N)` (section 4.3). The new design was verified to
produce **exactly** N cycles per phase state: `tb_excitation_drive.sv` checks
N=1 (16 cycles/period), N=5 (80 cycles/period), and N=13 (208 cycles/period),
all exact with zero drift.

Verified by `tb_excitation_drive.sv` (regression stage 5, rewritten for the
free-running interface): exact N-cycles-per-phase and 16·N-cycles-per-period
timing at three divider values, the phase-to-drive map (0-6 P, 7 dead, 8-14 N,
15 dead), an `assert property` that `drive_p_o && drive_n_o` is never true on
any cycle, and idle behavior when `enable_i=0`.

![excitation_ctrl_block_diagram](diagrams/modules/excitation_ctrl_block_diagram.svg)
*(redrawn for this MAS revision: shows the free-running divider and phase
counter with no command input at all, the phase-to-drive decode, and the
off-by-one fix.)*

### 6.4 excitation_ctrl, Rev 4.3 target **[IMPL]** — Phase 4 complete
- Free-running divider, no per-flip command from the FSM — **done**, see 6.3
- 4-bit phase counter exported as `phase_index_o[3:0]` — **done**
- Positive and negative half-cycles equal within one clock cycle for charge
  balance — **achieved exactly**: 7 phase states per half (0-6 and 8-14), each
  state lasting the same N cycles, so the two halves are equal to within a
  single clock cycle by construction, not by tuning

Nothing in this section is still `[SPEC]`; the free-running phase generator
Phase 4 set out to build is implemented and verified per section 6.3. The
half-cycle symmetry claim specifically was not measurable before Phase 4 (the
FSM-commanded flip had no fixed period to measure it against) and now is.

### 6.5 sar_controller **[IMPL]**
Responsibilities:
- Accept sample request when not busy (`S_IDLE`)
- Generate single-cycle `conv_start_o` pulse and a one-cycle `adc_sample_o`
  track-and-hold strobe when a request is accepted
- Assert `adc_enable_o` for the full conversion (accept through done)
- Run the **8-bit successive-approximation search itself** (Phase 1, Rev 4.3):
  drive `adc_dac_o[7:0]` with the current trial code, wait
  `conv_cycles_i` cycles for comparator regeneration, sample `adc_comp_i`, and
  decide the bit — MSB first, 8 trials per sample
- Capture the converged code into D+ or D− storage by phase
- Pulse `sample_done_o` when the last bit is decided

States: `S_IDLE → S_TRIAL_SET → S_TRIAL_WAIT → S_TRIAL_EVAL` (loops 8 times,
once per bit, then back to `S_IDLE`).

![sar_controller_block_diagram](diagrams/modules/sar_controller_block_diagram.svg)
*(redrawn for this MAS revision: shows the real `S_IDLE -> S_TRIAL_SET ->
S_TRIAL_WAIT -> S_TRIAL_EVAL` bit-trial loop against `adc_dac_o`/`adc_comp_i`,
the `adc_comp_i` convention, and the conv_cycles_i reinterpretation.)*

### 6.6 sar_controller — Rev 4.3 SAR bit-trial interface **[IMPL]**
The SAR bit trials now run **in digital**. The controller talks to the ADC
analog core, not to a self-contained converter returning a finished code.
`adc_code_i` is gone from every module in the hierarchy.

| Port | Direction | Purpose |
|---|---|---|
| `adc_enable_o` | out | Analog core enable, asserted for the full conversion |
| `adc_sample_o` | out | Track/hold strobe, one cycle at conversion start |
| `adc_dac_o[7:0]` | out | Bit-trial DAC code, MSB-first successive approximation |
| `adc_comp_i` | in | Comparator decision |

**`adc_comp_i` convention** (drive any analog model/testbench to this
contract): `1` = input ≥ current trial code (keep the bit, it's a valid lower
bound); `0` = input < current trial code (clear the bit, it overshot). Binary
search under this convention converges to the target exactly for any integer
input — verified for every code 0–255 including both endpoints, by
`tb_sar_bit_trial.sv` (regression stage 4).

`adc_comp_i` is **not synchronized** — it is a timed path, per the original
spec. The controller guarantees regeneration time by waiting `conv_cycles_i`
cycles between presenting a trial and sampling the decision.

**Design decision on `conv_cycles_i`:** the comparator regeneration time is not
yet characterized (GAP-2, unresolved — no number from analog as of this
writing). Rather than hardcode a guessed value as an RTL parameter,
`conv_cycles_i` — already a runtime register (`REG_CONV`) — was **reinterpreted**
as the regeneration wait *per bit trial* rather than *total latency before
reading one finished code*. This means the real regeneration time can be tuned
during bring-up by writing a register, with no respin required, once
characterized. Total conversion time is `8 × (3 + conv_cycles_i)` clock cycles;
verified empirically (24 cycles at `conv_cycles_i=0`, 40 at `conv_cycles_i=2`).

### 6.7 spi_slave **[IMPL]** — reworked in Rev 4.3 Phase 3
Responsibilities:
- SPI mode-0 shift and transaction bit counting, **entirely in the clk
  domain** — `sclk_i`, `cs_n_i` and `mosi_i` are 2FF-oversampled, and every
  bit/byte event is a detected edge on the synchronized signal, not a real
  clock edge
- One `rx_valid_o` pulse per completed byte, the **same clk cycle** the 8th
  bit is captured — there is no CDC left to cross for it

**What changed from the pre-Phase-3 design:** RX used to run on
`posedge sclk_i` and TX on `negedge sclk_i` — a real second clock domain
inside this module — with `rx_valid_o` crossing back into `clk` through a
toggle synchronizer. Both are gone. `grep -rn "always_ff @(" rtl/` finds zero
matches outside `posedge clk` anywhere in the synthesizable tree (the `.orig`
snapshot excepted) — this module was the last exception, and it no longer is
one. Removing the toggle synchronizer wasn't just a cleanup: it deleted the
entire class of "byte arrives a few cycles later than you'd think" bugs that
motivated the original TX workaround below.

TX timing is still the subtle part, now inside the clk domain: the first bit
of each byte is driven combinationally from `tx_data_i`, which has had the
whole inter-byte gap to settle; only the remaining seven bits come from the
shift register, loaded on the first *detected* falling edge of the byte. An
earlier version reloaded the shift register on the same edge that started the
old CDC crossing, so every read returned the prior transaction's byte — the
fix (drive bit 7 combinationally) carries forward unchanged in spirit, just
without a domain crossing to dodge anymore.

**Host requirement, tightened by Phase 3, not just carried forward:**
max SCLK = `f_clk/16`. This used to be soft (the old design had no
oversampling ratio to violate); now it's load-bearing — go faster and the 2FF
synchronizers cannot resolve edges reliably. `tb_spi_domain_crossing.sv`
verifies correct operation at exactly `f_clk/16` (not comfortably above it)
and demonstrates real data corruption at a rate below the sampling clock's
Nyquist rate, so this is a measured property, not an assumed one.

**cs_n and framing:** a synchronized `cs_n_i` rising edge resets only this
module's own bit counter and TX state — never anything outside it, which is
structurally guaranteed since this module has no access to measurement state
in the first place. `tb_spi_domain_crossing.sv` checks the practical
consequence: deselecting mid-byte and reselecting starts a clean new byte,
with no module reset needed.

![spi_slave_block_diagram](diagrams/modules/spi_slave_block_diagram.svg)
*(redrawn for this MAS revision: shows the 2FF oversampling and edge-detected
shift/frame logic entirely in the clk domain, with no toggle synchronizer or
second clock domain.)*

### 6.9 agriasic_digital_spi_top **[IMPL]** — register map reworked in Rev 4.3 Phase 6
- Decode Byte0 command and track pending transaction context
- Enforce protocol legality checks before state mutation
- Generate response bytes for ACK/NACK/error conditions
- Keep parser alignment by consuming Byte1 for invalid Byte0
- Bridge config writes into core controls (`REG_FREQ_SEL`'s selector-to-N
  lookup happens here, combinationally — see section 7.1)
- Serve the indexed result readout (`REG_RESULT_IDX`/`REG_RESULT_DATA`,
  auto-increment on data reads) and mirror status into the regfile

**Status/regfile mirror simplified in Phase 6.** Phases 4-5 rotated a 3- then
5-slot mirror writing STATUS and the (then-direct) result registers into
`u_regfile` every few cycles. That mirror was already non-load-bearing for
correctness — `read_byte_from_addr` handles every valid address directly and
never falls through to the regfile's `rd_data` — so Phase 6 reduced it to a
single always-on STATUS write and did not extend it to cover the new
`REG_FREQ_SEL`/`REG_PHASE_IDX`/`REG_RESULT_IDX`/`REG_RESULT_DATA`/`REG_ID`
registers. This is a deliberate simplification, not a missed spot: extending
genuinely dead code would have been backwards.

![agriasic_digital_spi_top_block_diagram](diagrams/modules/agriasic_digital_spi_top_block_diagram.svg)
*(redrawn for this MAS revision: shows the Phase 6 register map including the
`REG_FREQ_SEL` selector, the indexed `REG_RESULT_IDX`/`REG_RESULT_DATA`
readout, `REG_ID`, and the two GAP-10 reserved items, plus the current
analog-boundary pin names.)*

### 6.10 regfile **[IMPL]**
- Parameterized storage for software-visible config/status points
- Supports writes from the host path and the status/result mirror path

![regfile_block_diagram](diagrams/modules/regfile_block_diagram.svg)

### 6.11 Worked example: tracing one measurement cycle **[IMPL]** — rewritten for Rev 4.3 Phase 5

This replaces the Phase 4 trace, which covered only the I channel (two sample
points per pair). The trace below is a real Verilator run of
`agriasic_digital_top` with the Phase 5 dual-accumulator FSM: `pair_log2=2`
(M=4), `settle=2` (excitation periods), `divider=1` (N=1, fastest excitation
— 16 clk cycles/period), `conv=1`, and a four-target track-and-hold ADC model
keyed on `measurement_fsm`'s own state (the same model used in
`tb/smoke/tb_agriasic_digital_top.sv` — see that testbench's header comment
for why keying on state, not `phase_index_i` directly, is necessary at small
N): `D(0)=220`, `D(90)=170`, `D(180)=100`, `D(270)=90`. These are
deliberately different deltas (I delta = 120, Q delta = 80) so a channel-swap
bug would produce a numerically wrong, not coincidentally right, result.

As in the Phase 4 version, this logs a row every time `state_q` changes,
rather than every clock cycle. `phase_idx` is the phase counter's value at
the moment the **new** state is registered, one cycle after the actual phase
match happened (see the reading note in step 4 below).

#### First pair, state-change trace (N=1, so phase increments every clock)

| cyc | state entered | phase_idx | d_plus | d_minus | i_acc | q_acc |
|---|---|---|---|---|---|---|
| 0 | S_IDLE | 0 | 0 | 0 | 0 | 0 |
| 3 | S_SETTLE | 0 | 0 | 0 | 0 | 0 |
| 36 | S_WAIT_0 | 2 | 0 | 0 | 0 | 0 |
| 51 | S_SAMPLE_0 | 1 | 0 | 0 | 0 | 0 |
| 84 | S_WAIT_180 | 2 | 220 | 0 | 0 | 0 |
| 91 | S_SAMPLE_180 | 9 | 220 | 0 | 0 | 0 |
| 124 | S_ACCUM_I | 10 | 220 | 100 | 0 | 0 |
| 125 | S_WAIT_90 | 11 | 220 | 100 | **120** | 0 |
| 135 | S_SAMPLE_90 | 5 | 220 | 100 | 120 | 0 |
| 168 | S_WAIT_270 | 6 | 170 | 100 | 120 | 0 |
| 175 | S_SAMPLE_270 | 13 | 170 | 100 | 120 | 0 |
| 208 | S_ACCUM_Q | 14 | 170 | 90 | 120 | 0 |
| 209 | S_LOOP | 15 | 170 | 90 | 120 | **80** |

Reading it as a story:

1. **cyc 0-2 — reset, then start.** `S_IDLE` holds through reset; the start
   pulse is accepted and `S_SETTLE` is entered at cyc 3.
2. **cyc 3-35 — settle.** `S_SETTLE` waits for `period_tick_i` to reach
   `settle_cycles_i=2` (two full 16-cycle periods = 32 clock cycles); the
   trace shows 33 (36-3), the one extra cycle being state-entry overhead, not
   a settle-count error.
3. **cyc 36-50 — wait for phase 0.** `S_WAIT_0` is entered at `phase_idx=2`
   and watches `phase_index_i` combinationally until it equals 0. That match
   happens at cyc 50 (not its own row — the match and the `S_SAMPLE_0`
   transition register together at cyc 51).
4. **cyc 51 — S_SAMPLE_0 entered, phase_idx reads 1, not 0.** Same subtlety
   as the Phase 4 trace: `sample_req_o` fired combinationally at cyc 50
   (`phase_index_i==0`), but `state_q` only updates at cyc 51, by which time
   the free-running phase counter (N=1) has already advanced to 1. The sample
   itself is correctly captured at phase 0; only the state-transition
   snapshot's `phase_idx` reads one step stale. `phase_match` in the smoke
   test checks the *previous*-cycle phase value for exactly this reason.
5. **cyc 51-83 — the D(0) conversion runs.** 33 cycles (`8 x (3 + 1) = 32`,
   plus one cycle of entry overhead). `d_plus` shows 0 until it lands at cyc
   84 (`220`, the converged D(0) code) — the same cycle `S_WAIT_180` is
   entered, since `d_plus_o` and `sample_done_o` register together (section
   6.6).
6. **cyc 84-90 — wait for phase 8 (180 deg).** Same watch pattern; match at
   phase 8 (cyc 90), `S_SAMPLE_180` registers at cyc 91 showing `phase_idx=9`.
7. **cyc 91-123 — the D(180) conversion runs.** Another 33-cycle SAR search;
   `d_minus` lands at `100` when `S_ACCUM_I` is entered at cyc 124.
8. **cyc 124 — I subtract.** `S_ACCUM_I` computes
   `sample_delta = d_plus - d_minus = 220 - 100 = 120` and adds it into
   `i_acc_q` with no scaling (D-3 fix, section 5) — visible as `i_acc=120`
   the following cycle (125), once the register has updated.
9. **cyc 125-207 — the Q channel repeats the same four-state pattern** at
   phase 4 (90 deg) and phase 12 (270 deg) instead of 0/180: `S_WAIT_90 ->
   S_SAMPLE_90 -> S_WAIT_270 -> S_SAMPLE_270`. `d_plus`/`d_minus` are
   **overwritten** with D(90)=170 and D(270)=90 — the same two `sar_controller`
   slots used for the I channel, now carrying different values, exactly as
   section 6.1 describes.
10. **cyc 208 — Q subtract.** `S_ACCUM_Q` computes `170 - 90 = 80` into
    `q_acc_q`, plus increments `pair_count`.
11. **cyc 209 — loop check.** `q_acc=80` is now visible, `pair_count=1`. Since
    `pair_count (1) < pair_target (4)`, the FSM loops back to `S_WAIT_0`
    (cyc 210) for the next pair.

Notice `i_shadow_q`/`q_shadow_q` (the registers the host actually reads,
section 6.1) are **not shown changing anywhere in this table** — they stay 0
through the entire first pair and every subsequent one, only updating on the
final `S_LOOP -> S_DONE` transition (step 13 below). This is the shadow-
register contract working exactly as designed: `result_i_o`/`result_q_o`
hold the *previous* run's value (0, since this is the first run since reset)
throughout, never a partial sum from the run in progress.

#### The remaining three pairs

| Pair | S_WAIT_0 entered at cyc | S_LOOP entered at cyc | Pair duration | i_acc / q_acc after S_LOOP |
|---|---|---|---|---|
| 1 | 36 (settle-gated, not comparable) | 209 | — | 120 / 80 |
| 2 | 210 | 369 | 160 | 240 / 160 |
| 3 | 370 | 529 | 160 | 360 / 240 |
| 4 | 530 | 689 | **160** | **480 / 320** |

Pairs 2-4 are exactly 160 cycles apart — double the Phase 4 single-channel
figure (80 cycles), because each pair now runs four SAR conversions instead
of two. At cyc 689 (`S_LOOP`, `pair_count=4 >= pair_target=4`), the FSM goes
to `S_DONE` (cyc 690) instead of looping. **This is the one cycle the shadow
registers actually change:** `i_shadow_q`/`q_shadow_q` latch to 480/320 on
this exact transition, confirmed in the raw trace output
(`i_shadow=480 q_shadow=320` first appears at cyc 690, the same cycle
`state=13` (`S_DONE`) is entered) — not one cycle earlier, not one cycle
later.

**480/320 is exactly `M x (D+ - D-)` per channel: `4 x 120 = 480` for I,
`4 x 80 = 320` for Q** — the smoke-test expectation in
`tb/smoke/tb_agriasic_digital_top.sv`, and
`SMOKE_PASS: I=480 Q=320 (phase-match checked, 0 errors)` confirms both
numeric results *and* that every one of the 16 samples in this run (4 pairs x
4 phases) landed on the exact documented phase index (section 3.2).

**What the host still has to do:** neither `result_i_o=480` nor
`result_q_o=320` is the final answer — each is `M x (D_channel+ - D_channel-)`.
The host divides by M (here, 4) to recover the raw chop differences (120 and
80), and by 2 again for the true chop average, per section 3.1's
`I = (D(0deg) - D(180deg))/2` and `Q = (D(90deg) - D(270deg))/2`. None of that
scaling happens on die; see section 5.2.

### 6.12 Reset synchronizer and core clock enable **[IMPL]** (Rev 4.3 Phase 2)

**`rst_sync`** — new module, `rtl/rst_sync.sv`. 2FF, async assert / sync
deassert. Instantiated once inside each chip-boundary top
(`agriasic_digital_spi_top`, `agriasic_digital_programming_top`,
`agriasic_digital_rv32i_top`) — not inside `agriasic_digital_top` itself,
which always receives an already-synchronized reset from whichever top
instantiates it. The external `rst_n` pin name is unchanged; every internal
block now runs off `rst_n_sync`.

Verified by `tb_rst_sync.sv` (regression stage 6) at four different
clk-unaligned assert/deassert phase offsets: assertion is visible within 1 ns
regardless of phase (true async behavior), and deassertion consistently takes
exactly 2 clk edges and lands only on a posedge, independent of phase — proof
the synchronizer isn't accidentally working only for a lucky timing alignment.

**Core clock enable** — `DatapathPipelined` and `RegFile`
(`rtl/rv32i/agriasic_rv32i_core.sv`) gained a `clk_en_i` input. When low, every
pipeline stage register (F/D/X/M/W), the divider pipeline, the cycle counter,
and the register file hold — nothing in the core toggles. `clk` itself is
never gated (`clk_en_i` is an ordinary synchronous enable on each register,
not an AND on any clock net) — verified by grep across the whole `rtl/` tree:
every `.clk(...)` connection is the bare signal, none derived.

The generic `Processor`/`MemorySyncUnified` wrapper — used only by the
standalone cocotb ISA regression, not by this chip's own control shell — ties
`clk_en_i` permanently high, so its behavior (and the 77-test suite that
exercises it) is unchanged by this work.

`agriasic_rv32i_control_shell.sv` drives the gating automatically, with no
firmware cooperation needed: `core_clk_en` drops the cycle after
`start_pulse_o` (letting the triggering MMIO store complete normally) and
rises the cycle `measurement_done_i` asserts (exactly when a fresh result is
ready). Firmware does not poll during a measurement — it simply resumes.

**Verified, not just asserted:** `tb_agriasic_rv32i_e2e.sv` (regression stage
8) monitors the real trigger path directly. Across one run (4 real
measurements): `core_clk_en` was low for **1316 of 1412 total cycles (93%)**,
an `assert property` that the Fetch PC never changes while `core_clk_en` is
low held with zero violations, and the architectural results were bit-exact
with the pre-Phase-2 run (average 400, all 4 samples 400) — proof the
freeze/resume cycle doesn't corrupt state across four independent uses of it,
using the actual trigger signals, not a synthetic forced scenario.

**Single clock domain, no new CDC (Phase 2.3):** verified by grep, not just
documented — at Phase 2, every `always_ff` in `rtl/` triggered on `posedge
clk` or the `spi_slave`-internal `sclk_i`/its negedge, the one documented SPI
exception. **Phase 3 (section 6.7) then removed that exception entirely** —
as of Phase 3, the same grep finds zero `always_ff` outside `posedge clk`
anywhere in the synthesizable tree. No third domain, and no second one
either.

---

## 7. Register and Protocol Specification

### 7.1 Register map, as implemented **[IMPL]**

This is now the Rev 4.3 target layout (section 7.2's table), not an interim
one — Phase 6 closed the gap between them except for two deliberately
unresolved items noted below.

| Addr | Name | Access | Purpose |
|---|---|---|---|
| 0x0 | `REG_CTRL` | RW | bit0=start pulse, bit7=clear sticky protocol flags. **No core-enable bit** — see the note below |
| 0x1 | `REG_PAIR_LOG2` | RW | M = 2^value. Constrained to 6 or less in RTL (values above clamp to 64 and set the overrange status bit) — accumulator width, section 9.3 |
| 0x2 | `REG_SETTLE` | RW | Excitation *periods* to wait after start (section 6.1), not raw cycles |
| 0x3 | `REG_FREQ_SEL` | RW | **2-bit selector**, not raw N: 0 -> 10 MHz (N=1), 1 -> 100 kHz (N=100), 2 -> 1 kHz (N=10000). Replaces the Phase 1-5 `REG_DIVIDER`; see the note below |
| 0x4 | `REG_PHASE_IDX` | RW | Present in the map; **writes are stored and read back, but not wired to anything** — see the note below and GAP-10 |
| 0x5 | `REG_CONV` | RW | SAR comparator regeneration wait, per bit trial |
| 0x6 | `REG_STATUS` | RO | bit7 protocol_err, bit6 bad_addr, bit5 illegal_ro_write, bit4 **overrange** (new), bit1 done, bit0 busy |
| 0x7 | `REG_RESULT_IDX` | RW | Pointer into the result byte vector, 0-15. **Auto-increments on each `REG_RESULT_DATA` read** (not on writes to this register, and not on reads of this register itself) |
| 0x8 | `REG_RESULT_DATA` | RO | Byte at the current index — see the mapping note below |
| 0x9 | `REG_ID` | RO | Fixed design/revision identifier, `8'h43` |

**`REG_RESULT_DATA` index mapping.** The Rev 4.3 target result set is I/Q for
three frequency points plus temperature — 13 bytes. Only one frequency
point's data exists today (Phase 7's sweep isn't built, and no temperature
sensing exists anywhere in the digital RTL):

```text
idx 0: result_i_o[7:0]     idx 1: result_i_o[15:8]
idx 2: result_q_o[7:0]     idx 3: result_q_o[15:8]
idx 4-15: reserved, reads as 0
```

Indices 4-15 read as an honest, deliberate zero rather than garbage — real
data for frequency points 1/2 and temperature lands there once Phase 7
exists to produce it. `result_idx_q` is a plain 4-bit register (0-15, wrapping
naturally on overflow), three addresses wider than the 13-byte result set
strictly needs; that's a free simplification, not a bug — a mod-13 counter
would cost more than the three unused addresses are worth.

**`REG_FREQ_SEL`, Phase 6 note — closes GAP-1's remaining half, on the SPI
and programming-interface paths only.** The internal divider register
(`cfg_exc_divider_o`/`cfg_divider_w`, 14 bits since Phase 4) needs N=10000 to
reach the 1 kHz point — too wide for one SPI byte. Rather than widen the
2-byte SPI protocol (which the design doc explicitly wants to avoid), Phase 6
replaced the raw-N `REG_DIVIDER` with a 2-bit **selector** on SPI and the
parallel programming interface: the host writes 0/1/2, the wrapper looks up
the corresponding N combinationally (`cfg_divider_w`, not a stored register —
there is nothing to keep in sync), and `excitation_ctrl` never knows the
difference. **This is the only way to reach 1 kHz through a single SPI byte
without changing the framing.** The three preset N values (1, 100, 10000) are
exact for the "roughly 1 kHz, 100 kHz, 10 MHz" points the baseline design doc
specifies, at `f_clk = 160 MHz` (the same table GAP-1 derived). RV32I MMIO
keeps its own register **named `REG_DIVIDER`, not renamed** — it takes raw N
directly (`agriasic_rv32i_mmio.sv`, 0x8000_000C) because native 32-bit
MMIO writes have no byte-framing constraint to work around; giving it the
same name as SPI's selector-based register would wrongly imply matching
semantics it doesn't have.

**`REG_PHASE_IDX` and `REG_CTRL`'s core-enable bit — two items the target
spec calls for that Phase 6 deliberately left unwired, not silently
dropped.** Both addresses/bits exist and accept writes (so host software
probing the documented map doesn't get an unexpected NACK), but:
- `REG_PHASE_IDX` ("phase index into the 16-state counter") doesn't reconcile
  cleanly with how Phase 5 actually built I/Q sampling: four FIXED,
  90-degree-spaced phase points, not a single host-selectable one. The most
  plausible reading — a phase *offset* that shifts all four points together,
  as a calibration trim — is an interpretation, not a specification. Building
  silicon-bound RTL against a guessed semantic was judged worse than an
  honest no-op. See GAP-10.
- A **core-enable** bit in `REG_CTRL` doesn't have an obvious home in the
  current architecture either: `agriasic_digital_spi_top` (where `REG_CTRL`
  lives) has no RV32I core to enable — the RV32I core only exists in the
  separate `agriasic_digital_rv32i_top`, and the two are alternative,
  mutually exclusive integrations today, not one chip where a host can
  toggle between them at runtime. This bit presumably targets some future
  unified top this codebase doesn't have yet. Also tracked under GAP-10.

### 7.2 Register map, Rev 4.3 target — reconciled with 7.1 above
The table Section 7.1 now shows **is** the target table; there is no separate
version to duplicate here anymore. What remains open is exactly the two items
called out above (`REG_PHASE_IDX`, `REG_CTRL`'s core-enable bit — GAP-10) plus
the result *data* Phase 7 needs to produce before indices 4-12 mean anything.
Existing response codes are retained (0xA5 / 0x5A / 0xE1 / 0xE2), and the
wrapper still consumes and discards the data byte of an illegal command to
keep framing aligned — both unchanged by Phase 6.

![rev43_register_map](diagrams/rev43_register_map.svg)
*(redrawn for this MAS revision: marks `REG_FREQ_SEL` as the resolved 2-bit
selector, flags `REG_PHASE_IDX` and `REG_CTRL`'s core-enable bit as reserved-
not-wired (GAP-10), and distinguishes the real idx 0-3 result bytes from the
reserved idx 4-15 placeholder bytes pending Phase 7.)*

### 7.3 SPI command format **[IMPL]**
- bit7: RW (1=READ, 0=WRITE)
- bit6:3: register address
- bit2:0: reserved, shall be zero

### 7.4 SPI response byte codes **[IMPL]**
- 0xA5 write accepted (ACK)
- 0x5A write rejected (NACK)
- 0xE1 invalid command (reserved bits violation)
- 0xE2 invalid address

### 7.5 Framing rule **[IMPL]**
Every SPI transaction is exactly two bytes. If Byte0 is illegal, Byte1 is
consumed and discarded before the next command decode.

### 7.6 Readback contract and byte-boundary timing **[IMPL]**
- Byte 0 of every transaction is always the command word
- Byte 1 is either the write payload or the read dummy cycle
- The read response is preloaded before the dummy byte begins and is shifted out
  on MISO as the host clocks the dummy byte
- `spi_slave` emits exactly one `rx_valid_o` pulse per completed byte
- `agriasic_digital_spi_top` consumes the command byte in the same clk domain and
  does not accept a second byte for the same transaction until the prior byte has
  completed

This contract is what prevents stale status or result values from being returned
in the next byte window.

![spi_byte_timing_contract](diagrams/spi_byte_timing_contract.svg)

![spi_control_readback_contract](diagrams/spi_control_readback_contract.svg)

![agriasic_digital_spi_protocol_flow](diagrams/modules/agriasic_digital_spi_protocol_flow.svg)

---

## 8. Clocking, Reset and Error Handling

### 8.1 Clocking **[IMPL]** unless noted
- Single clock domain at **160 MHz** (the sim clock period stands in for 160 MHz
  timing; actual 160 MHz closure is a physical-design question, not verified
  by RTL simulation) — verified by grep: every `always_ff` in `rtl/` is on
  `posedge clk` or the documented SPI exception, nothing else
- The core receives a **clock enable, not a gated clock** — verified by grep:
  no `.clk(...)` connection anywhere is a derived/gated expression. Section
  6.12 has the implementation and the 93%-of-cycles-frozen measurement
- No CDC anywhere except SPI — same grep, same result
- Core clock-enabled off during accumulation bursts — this is the boolean
  "off while a measurement is in flight" gating from section 6.12, **not** the
  fallback below, which is a different technique for a different problem

**Timing-closure fallback — [SPEC], not implemented.** If the flow will not
close 160 MHz on the accumulate path specifically, keep only the phase counter
and strobe at full rate and clock-enable the accumulate logic every fourth
cycle (a periodic 1-cycle-in-4 enable, distinct from the boolean burst-gating
above). This is a physical-design contingency, not something RTL simulation
can confirm is needed or sufficient.

**Phase-resolution fallback — [SPEC], not implemented.** If the pad, clock buffer
and sampling logic do not close 160 MHz in this process, drop to **8 phase
steps at 80 MHz**, which still supports I and Q at 45-degree resolution. Phase
steps fall out of the divider counter, so no delay line or DLL is required
either way. This only becomes relevant once Phase 4's phase counter exists.

### 8.2 Reset **[IMPL]**
- `rst_n` asynchronous assert, **synchronous deassert** via a 2FF reset
  synchronizer (`rst_sync`, section 6.12), instantiated once per chip-boundary
  top — verified at multiple clk-unaligned assert/deassert phases by
  `tb_rst_sync.sv`
- State machines return to deterministic idle/reset states **[IMPL]**
- Configuration registers return to defaults **[IMPL]**
- Sticky protocol bits clear on reset **[IMPL]**

### 8.3 Error policy **[IMPL]**
- Illegal command/address/RO write do not alter configuration payload targets
- Sticky status bits remain set until software clear via CTRL bit7

---

## 9. Timing and Control Contracts

### 9.1 Implemented **[IMPL]**
- `conv_start_o` is a one-cycle pulse per accepted sample request
- `done_o` and `busy_o` are mutually constrained by end-of-sequence semantics
- **(Phase 4, extended Phase 5)** A sample strobe (`sample_req_o`/
  `sample_phase_o`) is issued **only** when the free-running phase counter
  equals the selected phase index — **four** indices now (0, 4, 8, 12 for
  0/90/180/270 degrees), not two — there is no longer a `settled_i` handshake
  to gate on; settle is a one-time period count in `S_SETTLE` before the FSM
  starts watching for phase matches at all (section 6.1). Verified exactly,
  not just asserted: `tb/smoke/tb_agriasic_digital_top.sv`'s phase-match check
  confirms every one of the 16 samples in a full 4-pair run (4 phases x 4
  pairs) lands on the documented index, using the cycle-before-transition
  phase value (section 6.11's reading note)
- **(Phase 5)** The accumulator shadow-register snapshot contract (see
  "Accumulator snapshot" below, formerly listed as **[SPEC]**) is now
  **[IMPL]**: `i_shadow_q`/`q_shadow_q` latch the live accumulators only on
  the `S_LOOP -> S_DONE` transition, the one cycle `busy_o` drops. Confirmed
  in the section 6.11 trace: both shadow registers read 0 through the entire
  run and change to their final values on exactly that one cycle
- The `sar_done_i` handshake gates transitions out of sample states
- `{exc_drive_p_o, exc_drive_n_o} = 2'b11` structurally unreachable — asserted
  every cycle in `tb_excitation_drive.sv`, holds for the free-running Phase 4
  design as it did for the Phase 1 FSM-commanded design
- **(Phase 4)** `f_exc = f_clk / (16 x N)` holds **exactly**, not
  approximately: `tb_excitation_drive.sv` measures 16, 80, and 208
  cycles/period for N=1, 5, 13 respectively, with zero drift — this replaces
  the pre-Phase-4 divider, whose tick comparison actually produced periods of
  `divider_i + 1` cycles (an off-by-one bug fixed, not carried forward — see
  section 6.3)
- **(Phase 4)** Positive and negative half-cycles are equal to within one
  clock cycle by construction: 7 phase states per half (0-6 and 8-14), each
  lasting the same N cycles — this was unmeasurable before Phase 4 since the
  FSM-commanded flip had no fixed period to check it against, and is now a
  structural property of the phase encoding, not a tuned value
- `adc_comp_i` unsynchronized; the controller guarantees `conv_cycles_i` cycles
  of comparator regeneration time by construction before sampling it, per bit
  trial — no comparator regeneration number is known yet (GAP-2), so this is
  the mechanism, not a validated timing margin
- SAR bit-trial conversion time: `8 × (3 + conv_cycles_i)` clock cycles, verified
  for `conv_cycles_i` ∈ {0, 2}

**Settle timing after Phase 1, 4, and 5:** because break-before-make adds
`DEAD_CYCLES` before drive can assert, and SAR conversion takes 24+ cycles
instead of the few cycles `adc_code_i` needed, total run time grew
substantially versus the pre-Phase-1 baseline (measurement smoke: I=480/Q=320
in 690 cycles at N=1/settle=2, section 6.11, vs. the pre-Phase-1 ~73, and vs.
368 for the Phase 4 single-channel version — Phase 5 roughly doubled run time
again by doubling SAR conversions per pair from 2 to 4). Phase 4 changed the
*unit* `settle` is measured in (excitation periods, not raw cycles); Phase 5
did not change the unit again, only how much work happens between settles.
The *ratios and monotonicity* `tb_settle_timing` checks are unaffected by
either change — settle=0 < settle=2 < settle=5 < settle=20 still holds.
Nothing about any of this is a defect; it is the real cost of moving from a
placeholder ADC/excitation signal to actual bit-trial, phase-lock, and now
dual-channel mechanisms.

### 9.2 Rev 4.3 additions — nothing outstanding here
This section used to specify the I/Q split (sign and accumulator selection by
phase index, a second phase-index pair for 90/270 degrees). Both are `[IMPL]`
as of Phase 5 — see section 9.1 and section 6.1. Kept as a placeholder
heading rather than renumbering; a genuinely new Phase 6/7 timing contract
(if one turns out to be needed for the frequency sweep or indexed readout)
belongs here.

### 9.3 Contracts to freeze **[SPEC]**

```text
f_exc = f_clk / (16 * N)          phase step = 22.5 degrees
f_clk = 160 MHz                   for 10 MHz excitation with 16 phase steps
```

**Sampling aperture.** Under **5 ns**, with jitter small enough to hold phase
error below **one degree at 10 MHz**.

**Accumulator width.** 16-bit signed, **for each of I and Q independently**
(Phase 5 added the second accumulator; the per-channel bound is unchanged by
having two). Worst case at M = 64 is `64 × 255 = 16320`, inside the 32767
limit. At M = 128 the worst case is 32640 — inside the limit but **without
margin** — so constrain M to 64 or widen to 18 bits. `REG_PAIR_LOG2` is
therefore constrained to 6 or less, and this constraint applies identically
to whichever channel is larger in a given run; there is no combined I+Q bound
to worry about since they are separate registers, never summed on die.

**Phase command handshake.** Superseded by Phase 4. There is no longer a
polarity command to hand-shake on — the excitation generator is free-running
and the FSM only watches its phase counter (section 6.1, section 9.1). The
D-1/D-2 edge-triggered command mechanism this contract described no longer
exists in any form and cannot regress (section 6, `tb_settle_timing.sv`
header). The replacement contract, watch-and-strobe on phase match, is
implemented and verified (section 9.1) but not yet asserted as a formal RTL
`assert property` — that remains open (see V-5, section 12.3).

**Accumulator snapshot — [IMPL] as of Phase 5, one half still [SPEC].** The
FSM writes both accumulators into shadow registers **only at completion**
(`S_LOOP -> S_DONE`, section 6.1), so the host can never read a partial sum —
this half is implemented and verified (section 9.1, section 6.11). **Not yet
implemented:** a start written while busy is not specially handled as an
"ignored, error-flagged" case — the RTL's current behavior when `start_i` is
asserted mid-run is whatever falls out of `S_IDLE` never being re-entered
until `S_DONE` naturally completes (the `start_i` write is simply not
consumed, not actively rejected with an error bit). Whether that passive
behavior is good enough or needs an explicit reject-and-flag path is an open
question for Phase 6-8 signoff, not resolved here.

**Boundary to defend.** The FSM never gets a program counter. If it needs
branching beyond "repeat M times", it has become a second processor and the
schedule cannot absorb verifying two of them.

![agriasic_measurement_fsm_cycle_flow](diagrams/agriasic_measurement_fsm_cycle_flow.svg)

---

## 10. Rev 4.3 Implementation Plan

Sequenced by **external-contract risk first**: pin-level changes block analog
teammates and the 2026-11-18 trial GDS, so they are frozen before internal
restructuring. Every phase lands behind the existing 5-stage regression sweep,
which must stay green.

### Phase 0 — Verified baseline ✅ complete
Three defects fixed, chip lints clean, 5-stage sweep green (lint, measurement
smoke 480, SPI smoke 480, settle regression, e2e average 400).

### Phase 1 — Freeze the analog boundary ✅ complete **(highest external risk)**
| Step | Work | Blocks | Status |
|---|---|---|---|
| 1.1 | Replace `exc_pol_o` with `exc_drive_p_o`/`exc_drive_n_o`; break-before-make; make `2'b11` structurally unreachable; add an assertion proving it | Analog drive, pad ring | **Done.** `DEAD_CYCLES` parameter, default 1 cycle — placeholder pending analog sign-off (GAP-6) |
| 1.2 | Rewrite `sar_controller` as a real bit-trial engine: `adc_enable_o`, `adc_sample_o`, `adc_dac_o[7:0]`, `adc_comp_i`. Delete `adc_code_i` | ADC analog core | **Done.** `conv_cycles_i` (REG_CONV) reinterpreted as regeneration wait per bit trial — placeholder value, runtime-tunable (GAP-2 still open, now de-risked: no respin needed once characterized) |
| 1.3 | Add `miso_oe_o` for MISO high-Z when `cs_n` inactive | Pad ring | **Done.** Registered in the SCLK domain alongside `miso_o`; `assert property (miso_oe_o == !cs_n_i)` holds |

**Exit criterion met at the RTL level:** pin list is implemented, lints clean,
and covered by three new regression tests — `tb_excitation_drive.sv` (break-
before-make, structural `2'b11` exclusion), `tb_sar_bit_trial.sv` (bit-trial
convergence across the full 0–255 range), and the `miso_oe_o` assertion added
to the existing SPI smoke test. **Not yet done:** actual sign-off with the
analog owners on `DEAD_CYCLES` and the comparator regeneration time — the pins
exist and work in simulation, but the two placeholder timing values (GAP-2,
GAP-6) are still guesses, not characterized numbers. Regression sweep is now
7 stages (was 5): + SAR bit-trial, + excitation drive.

**Verified 480/400 unchanged.** Both the measurement result (480) and e2e
average (400) are bit-for-bit the same as pre-Phase-1 — the bit-trial engine is
functionally transparent to measurement correctness, as it must be. What
changed is timing: conversions now take 24+ cycles instead of a handful, so
absolute cycle counts grew substantially (documented in section 9.1) while
every monotonicity/correctness check still passes.

### Phase 2 — Clock and reset discipline ✅ complete
| Step | Work | Status |
|---|---|---|
| 2.1 | 2FF reset synchronizer at top: async assert, sync deassert | **Done.** `rst_sync.sv`, instantiated in all three chip-boundary tops. Verified at 4 clk-unaligned phase offsets by `tb_rst_sync.sv` |
| 2.2 | Core clock enable (`core_clk_en`), off during accumulation bursts. Enable, never a gated clock | **Done.** Threaded into `DatapathPipelined`/`RegFile`; driven automatically by `agriasic_rv32i_control_shell.sv` off the real `start_pulse_o`/`measurement_done_i` handshake. Verified via `tb_agriasic_rv32i_e2e.sv`: 93% of total cycles frozen across 4 real measurements, zero PC-freeze violations, bit-exact results |
| 2.3 | Document and assert the single-160 MHz-domain rule; no CDC except SPI | **Done** as a verified grep check, not just prose: every `always_ff` in `rtl/` is on `clk` or the documented SPI exception; every `.clk(...)` connection is the bare signal, never gated |

**What "verified" means here, precisely:** the freeze mechanism is exercised
through its *real* trigger path (an actual measurement run), not a synthetic
forced scenario — the 93% figure and the zero-violation assertion both come
from the same firmware run already used for end-to-end correctness. The
reset synchronizer, by contrast, needed a *dedicated* test: every other
testbench in this tree drives `rst_n` cleanly and synchronously, so none of
them exercised the async, clk-unaligned edge that `rst_sync` exists for.
Regression sweep is now 8 stages (was 7): + reset sync.

**Not yet closed:** whether 160 MHz genuinely meets timing on the accumulate
path is a physical-design question RTL simulation cannot answer. The two
fallbacks in section 8.1 (periodic 1-cycle-in-4 enable; 8 phase steps at
80 MHz) exist for exactly that contingency and remain **[SPEC]**.

### Phase 3 — SPI domain rework ✅ complete
| Step | Work | Status |
|---|---|---|
| 3.1 | 2FF synchronizers for `sclk`/`cs_n`/`mosi` in the clk domain; remove every `always_ff @(posedge sclk_i)` | **Done.** Verified by grep: zero matches outside `posedge clk` in the synthesizable tree |
| 3.2 | CPOL=0/CPHA=0 MISO on synchronized falling-edge detect; enforce max SCLK = f_clk/16 | **Done.** `tb_spi_domain_crossing.sv` verifies correct transfer at exactly `f_clk/16` and demonstrates corruption at a rate below the sampling clock's own Nyquist rate |
| 3.3 | `cs_n` rising resets framing only, never measurement state | **Done.** Verified: mid-byte deselect + reselect starts a clean new byte, no module reset needed |
| 3.4 | Refresh `interface_contract.md`, which is already stale by three SPI changes | **Done.** Full rewrite reflecting the current register map, response codes, `miso_oe_o`, and the `f_clk/16` timing contract |

**Resolved, not left open:** the plan's own note anticipated that removing the
toggle-synchronizer CDC might let the inter-byte-gap host requirement (section
6.7) be relaxed. Checked directly: `agriasic_digital_spi_top`'s response byte
(`spi_tx_data`) is a single registered update inside
`if (spi_rx_valid) begin ... end`, and `read_byte_from_addr` is pure
combinational — so the response is ready **exactly 1 clk cycle** after byte
completion. At `f_clk/16`, even a fully back-to-back byte (zero explicit gap)
gives ≥8 clk cycles before the next possible falling edge. **The inter-byte
gap requirement is now satisfied automatically by the `f_clk/16` rate limit
itself and does not need to be called out as a separate host-facing
requirement.** The RTL's defensive TX pattern (bit 7 driven combinationally,
remaining 7 bits shifted) is kept regardless — it costs nothing and remains
correct, it's just no longer the only thing standing between a fast host and a
stale byte.

### Phase 4 — Phase-locked excitation ✅ complete *(the architectural inversion)*
| Step | Work | Status |
|---|---|---|
| 4.1 | `excitation_ctrl` becomes a free-running divider + 4-bit phase counter; export `phase_index_o[3:0]` | **Done.** Rewritten; `period_tick_o` also added. Phase encoding: 0-6 drive positive, 7 dead, 8-14 drive negative, 15 dead — 7 states/half, exact symmetry (section 6.3) |
| 4.2 | **Widen the divider to ≥14 bits** — see [GAP-1] | **Done.** `divider_i`/`cfg_divider_q` widened to 14 bits end-to-end through `agriasic_digital_top`, both control shells, and MMIO (fully 14-bit, no windowing). SPI and the byte-oriented programming interface keep an 8-bit write/read window onto the 14-bit register for now — extending that window is Phase 6's job, not Phase 4's (GAP-1, encoding half still open) |
| 4.3 | `measurement_fsm` strobes on phase-index match; remove the per-flip polarity command | **Done.** States are now `S_IDLE, S_SETTLE, S_WAIT_P, S_SAMPLE_P, S_WAIT_N, S_SAMPLE_N, S_ACCUM, S_LOOP, S_DONE`; `exc_set_phase_o`/`exc_phase_o`/`settled_i` removed entirely, not deprecated in place (section 6.1) |
| 4.4 | Equivalent-time sampling: one phase point per excitation cycle across many cycles | **Done.** Verified structurally (excitation never waits on the FSM) and behaviorally: `tb/smoke/tb_agriasic_digital_top.sv`'s phase-match check confirms every sample across a full 4-pair run lands on the exact documented phase index, not merely the right half-cycle (section 3.2, section 6.11) |

**Exit criterion met:** the 9-stage regression sweep (`verify_all.sh`) is green,
including the rewritten `tb_excitation_drive.sv` (exact N-cycle timing at
N=1/5/13, structural `2'b11` exclusion) and the smoke/SPI/e2e/settle tests
updated for the new interface. **Two real bugs were found and fixed while
building this, not just claimed fixed:**

1. **Off-by-one divider bug (pre-existing since Rev 4.2).** The old tick
   comparison produced a period of `divider_i + 1` cycles, not `divider_i`.
   Harmless when `divider_i` only qualitatively gated a settle check;
   unacceptable once it must be a precise, host-computable N. Fixed in the new
   design — verified exact at three divider values (section 6.3).
2. **Testbench ADC model correctness gap, found only because excitation
   became free-running.** All six testbenches' behavioral comparator models
   read `exc_drive_p_o` *live* every cycle to pick a target code. That was
   correct when excitation only changed on a command the FSM controlled, but
   once excitation is free-running, `exc_drive_p_o` can change mid-conversion
   (a SAR conversion takes 24+ cycles; one phase state can last as little as 1
   cycle at N=1) — so the model could sample a *different* phase's target than
   the one actually captured at `adc_sample_o`. First symptom: the smoke test
   failed outright, `expected=480 got=204`. Fixed by making every testbench's
   ADC model track-and-hold: latch the target on `adc_sample_o` and hold it,
   exactly like a real T&H would, instead of re-deriving it live from a drive
   signal that may have already moved on.

**A verification gap was also closed proactively, not left implicit:** a
numerically correct `result=480` does not by itself prove samples landed on
the *documented* phase index (0 and 8) rather than merely "somewhere in the
7-state positive/negative half" — the track-and-hold ADC model can't tell
those apart, since `exc_drive_p_o` reads true across all of phase 0-6. The
phase-match check added to `tb/smoke/tb_agriasic_digital_top.sv` (section
3.2, section 6.11) closes this by comparing the actual `phase_index_i` value
at the moment each sample was requested against the exact expected index.

**Warning realized, as flagged in the prior revision of this plan:** this
changed measurement semantics, so every timing expectation in the testbenches
moved again (368 cycles for the smoke test at N=1/settle=2, vs. the
pre-Phase-4 ~300+), exactly as the D-3 fix moved 240 → 480 and Phase 1 moved
~73 → ~300+. The *numeric* result (480) did not move, because the underlying
math (`M x (D+ - D-)`) is unchanged — only cycle counts and the sampling
mechanism did.

### Phase 5 — I/Q accumulation ✅ complete
| Step | Work | Status |
|---|---|---|
| 5.1 | Two signed 16-bit accumulators (I and Q) | **Done.** `i_acc_q`/`q_acc_q` in `measurement_fsm`, each independently bounded exactly as the single accumulator was (section 9.3) |
| 5.2 | Sample and accumulate at all four phase indices: 0°/180° → I, 90°/270° → Q | **Done.** `S_WAIT_0/90/180/270` + `S_SAMPLE_0/90/180/270` + `S_ACCUM_I`/`S_ACCUM_Q` (section 6.1). `sar_controller`'s D+/D− slots are reused unmodified as generic per-sample storage — no new hardware there |
| 5.3 | Shadow registers snapshot on `done` so the host never reads a partial sum | **Done.** `i_shadow_q`/`q_shadow_q` latch only on the `S_LOOP -> S_DONE` transition — the first time this contract (section 9.3) has actually been implemented, not just specified |
| 5.4 | M ≤ 64 — already enforced | **Unchanged, reverified.** Same `pair_target` clamp as Phase 1-4; applies independently to both channels |
| 5.5 | Expose both channels on every host interface | **Done, ahead of Phase 6's indexed scheme.** Four direct registers (`REG_RESULT_I_LO/HI`, `REG_RESULT_Q_LO/HI`) added to SPI (0x6-0x9), the parallel programming interface (bare ports), and RV32I MMIO (`REG_RESULT_I`/`REG_RESULT_Q`, 0x8000_0018/0x8000_001C) — see section 7.1's note on why this is an interim layout, not the Phase 6 target |

**Exit criterion met:** the 9-stage regression sweep is green with the
dual-accumulator FSM integrated everywhere — measurement smoke (I=480, Q=320,
all 16 samples phase-matched), SPI smoke (same values read back over SPI),
settle timing regression (both channels checked at 4 settle values), and the
RV32I end-to-end firmware test (`fw.c` reads both `REG_RESULT_I`/
`REG_RESULT_Q` and writes `OUT_AVERAGE`/`OUT_AVERAGE_Q` and
`OUT_SAMPLES`/`OUT_SAMPLES_Q` to scratch RAM, all verified bit-exact across 4
real measurements).

**A real testbench-modeling bug was found and fixed while building this, not
just claimed fixed — the second one of this kind in two phases.** Every
behavioral ADC model's track-and-hold logic (added in Phase 4) latched its
target keyed on `exc_phase_index` at the moment `adc_sample_o` fired. That
broke silently for Phase 5: `sar_controller` registers `adc_sample_o` the
cycle it **accepts** a sample request, one cycle after the phase match that
triggered it — harmless when the model only needed to distinguish two things
(P half vs. N half, since polarity doesn't change within that one-cycle
window), but Phase 5 needs to distinguish **four** phases, and at N=1 the
phase counter advances every single cycle, so by the time `adc_sample_o`
pulses, `exc_phase_index` has already ticked past 0/4/8/12 to 1/5/9/13 —
values the model's `case` statement didn't recognize, silently leaving the
held ADC code at its reset value of 0 for the entire run. First symptom:
`SMOKE_FAIL: expected I=480 got=0`. **Fixed by keying the model on
`measurement_fsm`'s own state** (`S_SAMPLE_0`/`S_SAMPLE_90`/`S_SAMPLE_180`/
`S_SAMPLE_270`) instead of on `phase_index` directly — the state is
unambiguous regardless of the one-cycle lag, so this sidesteps the timing
subtlety instead of trying to compensate for it. Applied to all four
testbenches with a 4-target ADC model (`tb/smoke/tb_agriasic_digital_top.sv`,
`tb/smoke/tb_agriasic_digital_spi_top.sv`, `tb/tb_settle_timing.sv`,
`tb/tb_agriasic_rv32i_e2e.sv`, plus the two non-gating diagnostics
`tb/tb_diag.sv` and `tb/tb_spi_diag.sv`). This is the identical *class* of bug
as the Phase 4 track-and-hold finding (a testbench model's timing assumption
broke only once the design changed in a way that stressed a case the model
had never needed to handle) — worth naming as a pattern: **every phase-lock
Phase so far has broken exactly one pre-existing testbench modeling
assumption that happened to be untested by the previous phase's coverage.**

**A pre-existing, undiscovered port-identity drift was found and fixed in the
same pass.** `agriasic_rv32i_control_shell.sv.orig` (the microsequencer
descope fallback, section 4.2) still had `cfg_exc_divider_o` at `[7:0]` —
Phase 4 widened the real shell's copy to `[13:0]` but never touched `.orig`,
because **`.orig` is not referenced by any lint or build script in this
tree** and so nothing caught the divergence. Fixed now (widened to match,
plus the Q-channel result ports mirrored in), and `.orig` was lint-checked
directly (it has no dedicated script, so this was done by hand) to confirm
it compiles clean against the current `agriasic_rv32i_core`/`agriasic_rv32i_mmio`.
**This is a standing risk, not fully closed**: since nothing automatically
lints or builds `.orig`, a future interface change could silently
re-diverge it again. Tracked as GAP-8 (section 10.3).

Two testbenches (`tb_diag.sv`, `tb_agriasic_rv32i_e2e.sv`) were also found to
have the **same** stale `cfg_exc_divider_o` width (`[7:0]` instead of
`[13:0]`) left over from Phase 4 — fixed alongside the `.orig` shell fix
above, same root cause (nothing forced every file referencing that port to be
touched when the width changed).

### Phase 6 — Register map and readout ✅ complete (with two items deliberately left open)
| Step | Work | Status |
|---|---|---|
| 6.1 | `REG_RESULT_IDX` (auto-incrementing) + `REG_RESULT_DATA`, replacing Phase 5's direct `REG_RESULT_I/Q_LO/HI` | **Done.** 4-bit pointer, auto-increments on `REG_RESULT_DATA` reads only, wraps naturally at 16. Indices 0-3 serve real I/Q; 4-15 read as 0 (section 7.1) |
| 6.2 | Six 16-bit accumulators (3 frequencies × I/Q) plus temperature | **Not done, correctly deferred.** This is *data* Phase 7's sweep would produce, not a register-map mechanism — building storage for values nothing generates yet was judged premature. The mechanism that will serve that data once it exists (6.1) is built and tested now |
| 6.3 | Frequency-selection register encoding: selector index vs. raw N (GAP-1's remaining half) | **Done.** SPI and the parallel programming interface both got a 2-bit `REG_FREQ_SEL`/`CFG_FREQ_SEL` selector (0/1/2 -> N=1/100/10000); RV32I MMIO keeps raw-N `REG_DIVIDER` unchanged, since it has no byte-width constraint forcing a selector — see section 7.1 for why the two interfaces deliberately use different registers rather than one name with two meanings |

**Two items beyond the original three-step plan were added and then
deliberately left unresolved, not silently skipped:**

1. **`REG_ID`** (0x9, fixed `8'h43`) and **`REG_STATUS`'s overrange bit**
   (bit4, set when `REG_PAIR_LOG2 > 6` is written and silently clamped to
   M=64) — both unambiguous, cheap, and implemented on the SPI path; the
   overrange bit is mirrored on RV32I MMIO's `REG_STATUS` too (same bit
   position, different address). Both are real, verified features that
   weren't in the original three-step Phase 6 plan but were straightforward
   enough to add without the same ambiguity risk as the two items below.

2. **`REG_PHASE_IDX`** and **`REG_CTRL`'s core-enable bit** — reserved in the
   register map (writes accepted, stored, read back) but **not wired to
   anything**. Both are called for by the baseline design doc, and both have
   genuine semantic ambiguity given how Phases 4-5 actually built the rest of
   the design (section 7.1 has the full reasoning for each). Building RTL
   against a guessed meaning for a register that will be silicon-bound was
   judged a worse outcome than an honestly-inert placeholder plus a
   documented open question. Tracked as **GAP-10** (section 10.3) — get the
   actual intended semantics from whoever specified these before wiring
   anything to them.

**Exit criterion met:** the 9-stage regression sweep is green with the
reworked register map integrated everywhere it applies (SPI, the parallel
programming interface). `tb/smoke/tb_agriasic_digital_spi_top.sv` was
extended with real, passing checks for the auto-increment behavior (pointer
reads back as 4 after four `REG_RESULT_DATA` reads starting from index 0),
the reserved-index-reads-zero behavior (index 4 reads 0x00, not stale I/Q
data), `REG_ID` (reads back `0x43`), and the overrange bit (sets on
`REG_PAIR_LOG2=7`, clears on a subsequent valid write) — none of these were
asserted without being run.

### Phase 7 — Sweep policy in firmware ✅ complete (7.1/7.2/7.4), 7.3 blocked
| Step | Work | Status |
|---|---|---|
| 7.1 | Three frequency points → divider N values (see [GAP-1] table) | **Done.** `fw.c` writes `REG_DIVIDER` = 1, then 100, then 10000 in sequence via `run_sweep_point()` — the exact three presets `REG_FREQ_SEL` exposes on SPI. Verified for the real N=10000 (1 kHz) point in simulation, not a stand-in value: `tb_agriasic_rv32i_e2e.sv` measures the full sweep at ~3.15M cycles, confirming the mechanism works at the actual worst-case timing, not an optimistic one |
| 7.2 | Four phase offsets per point | **Already done, since Phase 5.** Every measurement already samples all four I/Q phases (0/90/180/270) per pair; Phase 7 just runs that same mechanism three times, once per frequency point. There was no separate "phase offset" mechanism left to build |
| 7.3 | Temperature read and result packing | **Blocked, not implemented.** No PTAT/ADC-test-mux interface exists anywhere in the digital RTL — this is an analog-side dependency (Krishna/Vidhu), not a firmware gap. `fw.c` writes a `-1` sentinel to `OUT_TEMP` so nothing downstream mistakes an unread value for a real reading. "Result packing" into the Phase 6 target's 13-byte format was not attempted either — see GAP-11, the reason is architectural, not a missing feature |
| 7.4 | Mirror any shell interface change into the microsequencer per section 4.2 | **N/A this phase.** Phase 7 changed only `fw.c` (firmware) — no port or interface on `agriasic_rv32i_control_shell.sv` changed, so there is nothing to mirror into `.orig` |

**New scratch-RAM layout (retires the Phase 1-6 single-frequency-demo
layout):** `OUT_COUNT`/`OUT_NUM_POINTS` (0x100/0x104), `OUT_DIV[3]` (0x110),
`OUT_I[3]`/`OUT_Q[3]` (0x120/0x130), `OUT_TEMP` (0x140, sentinel). The old
`OUT_AVERAGE`/`OUT_AVERAGE_Q`/`OUT_SAMPLES`/`OUT_SAMPLES_Q` addresses are
gone — a real 3-point sweep replaces the placeholder one-frequency loop those
existed to demonstrate, the same way each earlier phase's completion moved
the expected numbers (D-3: 240→480; Phase 4: cycle counts; Phase 5: added Q).
`tb_agriasic_rv32i_e2e.sv` and `tb_diag.sv` were updated to match and both
verify the new layout end to end.

**GAP-11, found while implementing this, not before:** the ADC model in
every RV32I-path testbench is frequency-invariant (keyed on FSM state, not
real analog response — section 6.11), so all three sweep points correctly
produce identical I/Q numbers in simulation; that is the expected result of
*this* test, not a sign the sweep mechanism doesn't work — what it proves is
that `REG_DIVIDER` really changes, each point's measurement really completes
and averages correctly, and results land in the right per-point slots. What
it can *not* prove, because no chip variant in this tree makes it possible to
prove, is that a real external host can ever retrieve these swept results:
`agriasic_digital_rv32i_top` has no SPI (or any other) pin-level interface,
and `agriasic_digital_spi_top` has no RV32I core. See GAP-11 (section 10.3)
for the full reasoning and the architectural options for closing it.

### Phase 8 — Verification and signoff ✅ complete (8.1/8.2 with real coverage; 8.3 partial)
| Step | Work | Status |
|---|---|---|
| 8.1 | V-1 through V-5 from section 12.3, added to `verify_all.sh` as each lands | **Done for V-1, V-2, V-4, V-5; V-3 already superseded.** Two new regression stages added (`tb_settle_conv_sweep.sv`, `tb_accum_edge_cases.sv`) plus two new formal `assert property` statements in the existing smoke test. Details in section 12.3 |
| 8.2 | Assertions: `{p,n}` never `2'b11`; half-cycle symmetry; accumulator range | **Done, all three now explicit.** `{p,n}` never `2'b11` was already a formal assert (Phase 1). Half-cycle symmetry was previously provable only by combining the phase-map and per-state-timing checks by hand — `tb_excitation_drive.sv` now counts `drive_p_o`/`drive_n_o` cycles directly and checks `7*N == 7*N` explicitly, at every N already under test. Accumulator range is a new formal `assert property` in the smoke test, checking both `i_acc_q` and `q_acc_q` stay within the section 9.3 ±16320 bound at every cycle, not just at completion |
| 8.3 | Refresh this MAS and `interface_contract.md`; re-run the 77-test ISA regression | **MAS and interface_contract.md refreshed for Phases 7-8 (this revision). ISA regression still not re-run** — same blocker as every prior phase: it needs the external CIS 5710 cocotb harness and a built `riscv-tests`, neither present in this environment. Phase 7 touched only `fw.c`, not `agriasic_rv32i_core.sv`, so the risk profile is lower than Phase 2.2's core changes, but "lower risk" is not the same as "re-run and confirmed" |

**Exit criterion met:** the regression sweep grew from 10 to **12 stages**,
all passing, total wall-clock time ~32 seconds including the real N=10000
sweep point — verification headroom did not come at the cost of a slow
regression. Every new claim in this section (grid coverage, edge-case
values, symmetry counts, accumulator bounds) is backed by a real, run
simulation result, not asserted from the arithmetic alone.

**What "V-1" and "V-2" mean in practice, stated plainly so the scope
decisions are visible, not just the results:**
- V-1's original wording calls for the full 8-bit x 8-bit settle/conv grid
  (65,536 combinations). That is not what was built: `tb_settle_conv_sweep.sv`
  covers a 9x6 = 54-point grid spanning both axes' extremes and several
  intermediate scales. This is a deliberate, documented trade — literal
  exhaustive coverage would make the regression impractically slow for a
  property (a hang) that manifests across a wide swath of the space, not at
  an isolated point, which is exactly what D-1/D-2's history (section 5)
  shows. A 54-point grid catches the same class of bug the full grid would.
- V-2's original rationale (catching a D-3-style rounding defect specific to
  odd/±1 differences) is now structurally moot: the current arithmetic path
  has no shift or rounding operation anywhere to have that defect in.
  `tb_accum_edge_cases.sv` was still built and still earns its keep as a
  regression against reintroducing scaling, and it uses the real M=64 bound
  for its saturating case (16320), not an arbitrary smaller stand-in.

### 10.1 Effort and ownership

From the Rev 4.3 baseline section 5. Rev 4.3 adds roughly **1.5–2 FTE-weeks** over
Rev 4.2, most of it the excitation restructure and the defect fixes. The FSM
promotion itself is nearly free because the block already exists; what is new is
the handshake discipline and the cross product of core and FSM states in
verification.

| Block | Owner | Delta | Status | MAS phase |
|---|---|---|---|---|
| Excitation generator (digital: `excitation_ctrl.sv`) | Taarana | 0.8 wk | Rework | 1, 4 |
| SAR controller (digital: `sar_controller.sv`) | Taarana | — | Rework | 1.2 |
| Measurement FSM (`measurement_fsm.sv`) | Taarana | 0.6 wk | Rework | 4, 5 |
| I/Q accumulators | Taarana | 0.5 wk | **New** | 5 |
| Core and program | Taarana | 0.4 wk | Exists (core); firmware rewritten | 7 |
| SPI and regfile | Taarana | 0.3 wk | Rework | 3, 6 |
| Wideband TIA | Krishna | 1–2 wk | Unchanged | — |
| SAR ADC | Vidhu | 1.0 wk | Unchanged | — |
| Temp sense (PTAT) | Vidhu | 0.5 wk | Unchanged | — |

Digital total ≈ **2.6 wk**, against a 2026-11-18 trial GDS. The excitation
generator is jointly owned, which makes Phase 4 the coordination risk as well as
the technical one.

**Corrected against actual per-file history (this revision):** the original
baseline table attributed step **1.2** (the `sar_controller.sv` bit-trial
rewrite, section 6.6) to the "Measurement FSM" row and omitted Phase 5 from
it entirely, even though section 6.1's own header states `measurement_fsm.sv`
had "I/Q accumulation added in Rev 4.3 Phase 5" — its single largest rework.
`sar_controller.sv` now has its own row (no baseline effort estimate existed
for it separately, hence the `—` delta) rather than being folded into a
block it never touched. The excitation generator row was also missing Phase
1: `excitation_ctrl.sv` is the module that first exported
`exc_drive_p_o`/`exc_drive_n_o` in Phase 1.1, before Phase 4 rewrote it again
into the free-running design. "Core and program" is split to make clear that
only the RV32I hardware core is unchanged from before Rev 4.3 — the Phase 7
sweep program (`fw.c`) itself was fully rewritten, not merely reused.

### 10.2 Descope path

The descope path **improves** under Rev 4.3. Because the FSM owns all measurement
behaviour, dropping the core at the Week 4 gate changes nothing about what the
chip measures — it only removes the ability to change the sweep program after
tapeout. Present it as the planned contingency, not a failure mode. Section 4.2's
port-identical shells make the cut a file swap.

Descope order, applied only as far as needed:

1. Drop the 32 MHz stretch point
2. Reduce phase steps from 16 to 8, halving the required clock to 80 MHz
3. Replace the core with a fixed FSM program
4. Reduce the sweep from three frequency points to two, keeping the widest separation

**Retain in all cases:** two frequency points, I and Q accumulation, the TIA,
8-bit conversion, temperature sense, reset safety, and a readable result vector
over SPI.

### 10.3 Open gaps

**[GAP-1] Divider width and register encoding — RESOLVED as of Phase 6.**
With `f_exc = f_clk/(16·N)` at `f_clk = 160 MHz`:

| Target f_exc | Required N | Bits needed |
|---|---|---|
| 10 MHz | 1 | 1 |
| 100 kHz | 100 | 7 |
| **1 kHz** | **10000** | **14** |

Pre-Phase-4, `divider_i` was 8 bits, so N maxed at 255 and the excitation floor
was **39.2 kHz** — the 1 kHz point, the one carrying most of the ionic
information since the `1/w` term is strongest at low frequency, was
unreachable. **As of Phase 4, the divider counter and its compare are 14
bits** throughout `excitation_ctrl`, `agriasic_digital_top`, both control
shells, and the MMIO path — the 1 kHz point is reachable today from a program
running on the RV32I core.

What Phase 4 did **not** resolve, and Phase 6 has now: the byte-oriented
interfaces (SPI, the parallel programming interface) could only expose an
8-bit write/read window onto the 14-bit register, capping N at 255 (39.2 kHz
floor) — the 1 kHz point needs N=10000, 14 bits, more than one SPI byte can
carry without widening the 2-byte protocol.

| Reading | Register holds | Register width over SPI | Divider counter width |
|---|---|---|---|
| **Selector (chosen)** | An index (0/1/2) into three preset N values | 8 bits is fine | 14 bits |
| Raw N (not chosen for SPI) | N itself | needs ≥14 bits, so two SPI bytes | 14 bits |

**Resolution: `REG_FREQ_SEL` on SPI and the parallel programming interface is
now a 2-bit selector** (0 -> N=1/10 MHz, 1 -> N=100/100 kHz, 2 ->
N=10000/1 kHz), translated to the internal 14-bit N combinationally — the
only way to reach the 1 kHz point through a single SPI byte. This was the
**only** viable choice given the "two-byte protocol unchanged" constraint in
the baseline design doc, not a preference among equally good options.
**RV32I MMIO keeps raw-N `REG_DIVIDER`, unrenamed, unchanged** — no
byte-width constraint applies there, so there was nothing to resolve on that
path (section 7.1). Both are verified: `tb_agriasic_digital_spi_top.sv`
confirms `REG_FREQ_SEL=0` produces the same N=1 behavior the old
`REG_DIVIDER=0` did (I=480/Q=320, unchanged), and MMIO's raw-N path is
exercised unchanged by the RV32I end-to-end test.

Settle timing is unaffected either way: `settle_cycles_i` now counts
excitation *periods* (section 6.1), so even a modest settle value is ample
margin at any reachable N.

**[GAP-7] Sample points sit immediately adjacent to a dead-time/transition
state, with no settle margin inside the sampled half-cycle itself.** Found
during Phase 4 design, not resolved, and not silently assumed away. Phase
encoding is 0-6 positive drive, 7 dead, 8-14 negative drive, 15 dead (section
6.3); the FSM samples at phase index 0 (first cycle of the positive half) and
8 (first cycle of the negative half) — i.e., the *very first* clock cycle
after each polarity transition, with zero phase states of settle time inside
that half-cycle before the sample is requested. `S_SETTLE` (section 6.1)
provides settle time *before the FSM starts watching for a phase match at
all*, measured in whole excitation periods — but once the FSM is watching,
the phase it locks onto is always the first cycle of the half, not a cycle
comfortably after the transition. Whether this matters depends on the analog
settling time constant relative to one clock period (6.25 ns at 160 MHz),
which is not yet characterized (see GAP-6, dead time, and GAP-2, comparator
regeneration — both analog-timing unknowns this gap is adjacent to but
distinct from). **This needs analog/systems review before trusting samples at
the fastest excitation points**, where one clock period is a larger fraction
of the excitation half-period. A fix, if needed, is cheap in RTL — sample at
a phase index a few states into the half (e.g., 2 or 10 instead of 0 or 8)
— but changing it moves the D+/D- targets in every testbench again, so it
should be decided once, deliberately, not discovered late.

**[GAP-2] Comparator regeneration time is unknown.** No longer blocks Phase 1 —
`conv_cycles_i` (REG_CONV) is a runtime register, reinterpreted to mean
regeneration wait per bit trial, so the real number can be written into the
chip during bring-up with no respin. It is still **unknown**, and the current
default (used throughout simulation: 1–2 cycles) is a placeholder with no
basis in real comparator behavior. Get a real number from Vidhu before trusting
any bring-up timing budget built on it.

**[GAP-6] Break-before-make dead time is unspecified.** `excitation_ctrl`'s
`DEAD_CYCLES` parameter (default 1 cycle at 160 MHz, 6.25 ns) is a placeholder
with no basis in the actual pad/driver turn-off time. Unlike GAP-2, this is an
RTL **parameter**, not a runtime register — no register map slot exists for it
in the Rev 4.3 spec, and none is proposed, since it's a fixed safety margin
rather than a corner-tunable quantity. **This one does need a respin if wrong**,
since it can't be corrected in the field. Get the real minimum dead time from
Krishna before this is anywhere near tapeout-ready.

**[GAP-3] `interface_contract.md` — RESOLVED for Phase 3, reopened for Phase
4.** The original staleness (predating three SPI changes: sticky `STATUS[1]`,
dummy-byte consumption, mode-0 MISO timing) was fixed by the Phase 3.4 rewrite
(section 10, Phase 3). Phase 4 reopens it in a smaller way: the divider
register is now 14 bits internally with an 8-bit SPI window (section 7.1),
and `settle_cycles_i` now means excitation periods, not raw cycles (section
6.1) — `interface_contract.md` needs both of these noted before host firmware
is written against the divider or settle registers.

**[GAP-4] Shell status outputs are unconnected** in
`agriasic_digital_rv32i_top.sv` (`shell_busy`, `shell_done`,
`shell_result_i`/`shell_result_q` — now two signals as of Phase 5, still both
dangling — `shell_clear_errors`). Open question which is authoritative for an
external host.

**[GAP-5] No foundry SRAM macro.** `agriasic_imem`/`agriasic_dmem` are behavioral
models carrying the correct timing contract, with an `AGRIASIC_USE_SRAM_MACRO`
ifdef for memory-compiler output.

**[GAP-8] `agriasic_rv32i_control_shell.sv.orig` is not covered by any lint
or build script.** Found during Phase 5 when its `cfg_exc_divider_o` port
turned out to still be `[7:0]`, three phases after the real shell widened the
same port to `[13:0]` (section 10, Phase 5). The port-identity constraint
(section 4.2) is a documented standing rule, but nothing mechanical enforces
it for this specific file — every other file in the tree gets touched by
`verify_all.sh`, this one does not. Fixed by hand this time (widened, plus the
Phase 5 result-port mirroring), and lint-checked manually, but the same class
of drift can recur silently at the next interface change. **Recommend adding
a `lint_shell_orig.sh` companion to `lint_shell.sh`** so this file is checked
automatically going forward, or dropping it if the microsequencer descope
path is no longer considered live enough to maintain — that's a scope
decision for the team, not made here.

**[GAP-9] Two `.orig` files are dead, undocumented code; a third is
documented but equally unbuildable.** A full synthesizability/lint pass
across every file in `rtl/` (not just what the regression scripts touch),
done for this MAS revision, checked every `.orig` snapshot individually:

- **`agriasic_digital_spi_top.sv.orig`** — found during Phase 5, not part of
  any documented descope story (section 4.2 only describes the control-shell
  alternative), referenced by no script, not mentioned anywhere else in this
  MAS. Predates even Phase 1: still uses the old `adc_code_i`/`exc_pol_o`/
  `result_o` interface. **Confirmed unbuildable, not just unused**: linting
  it standalone found a genuine syntax error (`case`/`endcase` mismatch,
  fixed as a zero-risk one-line change so the file at least parses), and
  linting it against the *current* `agriasic_digital_top` produces three
  `PINNOTFOUND` errors (`adc_code_i`, `exc_pol_o`, `result_o` don't exist on
  the current module) plus eight `PINMISSING` warnings for ports it never
  knew about. This file cannot be compiled against anything in the current
  tree without a rewrite equivalent to recreating it from scratch.
- **`ctrl/spi_slave.sv.orig`** — found during this same pass, same category:
  not referenced by any script, not mentioned anywhere else in this MAS.
  Its header describes the pre-Phase-3 SCLK-domain design ("Captures MOSI on
  rising edges of sclk_i") that Phase 3 replaced with 2FF-oversampled
  clk-domain logic (section 6.7) — a snapshot from before that rework, same
  situation as the SPI top `.orig` above.
- **`ctrl/sar_controller.sv.orig`** — different category: **documented**,
  not silently forgotten. Section 5.3 explains its original purpose (a
  pre-fix/post-fix comparison leg in the measurement smoke test) and that the
  comparison it supported stopped being meaningful after the D-1/D-2 fix, and
  became **structurally impossible** after the Phase 1 SAR bit-trial rewrite
  (it still expects the retired `adc_code_i` port). Functionally in the same
  dead-and-unbuildable state as the two files above, but at least a reader
  finding it has somewhere to look for why.

**Recommend deleting all three** once someone confirms none of them is
serving as a reference snapshot the team still wants — that confirmation is
outside the scope of what this pass could determine. If any are kept
deliberately, say so here and in section 4.2 so the next person doesn't
have to rediscover the same thing.

**[GAP-10] `REG_PHASE_IDX` and `REG_CTRL`'s core-enable bit have no
implemented semantics — found and deliberately left open during Phase 6.**
Both are called for by the baseline design doc's register map (section 6 of
`agriasic_rev43_phase_locked_design.md`), and both are reserved addresses/bits
in the as-implemented map (section 7.1) that accept writes and read them back,
but do nothing:

- **`REG_PHASE_IDX`** ("phase index into the 16-state counter") doesn't
  reconcile with the actual, already-verified Phase 5 architecture:
  `measurement_fsm` samples at four FIXED, 90-degree-spaced phase points
  (0/4/8/12) to do I/Q, and there is no scenario where a host would want
  "one arbitrary phase" instead — that isn't what I/Q sampling means. The
  most plausible reading is a phase *offset* that shifts all four points
  together (e.g. `phase_index_i == (phase_offset_i + K) mod 16` for each of
  the four targets K), useful as a calibration trim for excitation-path
  propagation delay. That is a reasonable guess, not a specification. Get
  confirmation of the intended semantics from whoever wrote the baseline
  design doc before wiring this to anything — it is a small RTL change
  (`measurement_fsm` would need one new input and four comparisons changed
  from constants to sums) but a wrong guess is silicon-bound.
- **`REG_CTRL`'s core-enable bit** presumes an architecture this codebase
  doesn't have: a single chip where a host can toggle an on-die RV32I core
  on/off via SPI. Today the RV32I-driven and SPI-driven control paths are two
  separate, mutually exclusive top-level modules
  (`agriasic_digital_rv32i_top` vs. `agriasic_digital_spi_top`) — the SPI top
  has no core to enable. Either this bit targets a future unified
  architecture not yet designed, or the baseline doc's intent needs
  clarifying against the shells-are-alternatives reality established in
  section 4.2.

Both are safe to leave as inert placeholders indefinitely — they cost nothing
functionally and don't block any other work — but should not be assumed to
work by anyone reading only the register map without also reading this note.

**[GAP-11] No chip variant in this tree lets a real host retrieve
RV32I-swept results — found while implementing Phase 7, not before.**
Phase 7's frequency sweep runs correctly and stores real per-point I/Q data
in scratch RAM (section 10, Phase 7), but that data has no path to an
external pin:

- `agriasic_digital_rv32i_top` exposes `result_i_o`/`result_q_o` as bare
  output pins reflecting only the LATEST single measurement's shadow
  registers (section 6.1) — not a packed, multi-point result set — and has
  no SPI or other host-facing protocol at all. A host watching those two
  pins would see whichever frequency point happened to finish last, with no
  way to tell which point it was or retrieve the other two.
- `agriasic_digital_spi_top` has the indexed `REG_RESULT_IDX`/
  `REG_RESULT_DATA` readout Phase 6 built specifically to serve a
  multi-point result set (section 7.1) — but this module has no RV32I core
  inside it and never runs the Phase 7 sweep. Its indexed readout currently
  serves the single always-on measurement core's I/Q, the same one-point
  data the interim Phase 5 registers served.

These are two separate, never-composed top-level integrations (section 4.2's
port-identical *shells* are two implementations of the same RV32I-core-shaped
slot inside `agriasic_digital_rv32i_top`; they are not alternatives to
`agriasic_digital_spi_top`, a structurally different module with no shared
lineage). Closing this gap needs a real architecture decision, not a
one-line fix — plausible directions, none built or chosen here:
1. A new combined top instantiating both the RV32I core and `spi_slave`,
   with firmware writing swept results into a register file the SPI decode
   logic then serves — the most direct realization of what Phase 6 and
   Phase 7 each separately assumed the other would provide.
2. Give `agriasic_digital_rv32i_top` its own byte-serial output path (SPI or
   otherwise) driven directly by firmware, bypassing `agriasic_digital_spi_top`
   entirely.
3. Treat `agriasic_digital_rv32i_top` as headless-by-design (results meant
   for an external ADC/DAQ watching the raw pins, one measurement at a time,
   sequenced by some other means) and scope the "3-point sweep with indexed
   readout" requirement to the SPI-only integration path instead, dropping
   the RV32I core from that story entirely.

This does not block Phase 7/8's own verification (which correctly checks
what each existing chip variant actually does), but it should be resolved,
deliberately, before treating "frequency sweep" as done at the system level
rather than the firmware level.

---

## 11. Requirement Trace Matrix

| Req ID | Requirement | Implementation Mechanism | Verification | Status |
|---|---|---|---|---|
| DR-001 | Start shall trigger autonomous measurement sequence | REG_CTRL bit0 → start pulse → FSM entry | Smoke TB start-to-done | **[IMPL]** |
| DR-002 | Excitation frequency and settle timing shall be programmable | `cfg_exc_divider_i` sets the free-running divider N; `cfg_settle_cycles_i` sets the `S_SETTLE` period count (Phase 4: polarity is a structural consequence of the phase encoding, not a separately commanded/timed quantity) | `tb_settle_timing` monotonicity, `tb_excitation_drive` exact N-cycle timing | **[IMPL]** |
| DR-003 | SAR comparator regeneration time shall be programmable per bit trial | REG_CONV (`conv_cycles_i`) gates each of 8 bit trials | `tb_sar_bit_trial` timing (24 cyc @ conv=0, 40 @ conv=2) | **[IMPL]** |
| DR-004 | Sequencer shall process positive and negative samples per pair | `S_WAIT_P`/`S_SAMPLE_P` and `S_WAIT_N`/`S_SAMPLE_N` watch the free-running phase counter for a match at index 0 and 8 respectively (Phase 4: replaces the old commanded-flip mechanism) | D+/D− update checks, plus exact phase-index match verification | **[IMPL]** |
| DR-005 | Result shall accumulate the **raw** signed pair difference | S_ACCUM adds `pair_delta` with sign extension, no scaling | Deterministic result check (480) | **[IMPL]** |
| DR-006 | SPI framing shall be a deterministic 2-byte protocol | Byte0 decode + Byte1 always consumed | SPI protocol tests | **[IMPL]** |
| DR-007 | Illegal SPI commands shall be detectable | reserved-bit and bad-address checks → sticky bits | Negative-path SPI tests | **[IMPL]** |
| DR-008 | Illegal writes to RO registers shall be rejected | legality checks + NACK | write-to-RO test | **[IMPL]** |
| DR-009 | Status shall expose busy/done and protocol errors | REG_STATUS [7:5],[1:0] | status mirror checks | **[IMPL]** |
| DR-010 | Sticky errors shall be software-clearable | REG_CTRL bit7 write-one-clear | clear-after-error sequence | **[IMPL]** |
| DR-011 | SPI byte crossing shall avoid duplicate byte-valid pulses | Rev 4.3 Phase 3: byte detection is native to the clk domain (2FF-oversampled edge detect), so there is no crossing left to produce a duplicate on. The pre-Phase-3 toggle synchronizer this row originally described is removed | `tb_spi_domain_crossing` confirms exactly one `rx_valid_o` pulse per byte | **[IMPL]** |
| DR-012 | Fallback path shall remain viable without the CPU | port-identical microsequencer shell | 14-port identity verified | **[IMPL]** |
| DR-013 | Settle interval shall have a monotonic, observable effect | `S_SETTLE` counts `period_tick_i` pulses against `settle_cycles_i` (Phase 4: unit is now excitation periods, not raw cycles) | `tb_settle_timing` | **[IMPL]** |
| DR-014 | Excitation frequency shall be directly selectable | Free-running divider + 16-state phase counter, `f_exc = f_clk/(16·N)` exact | `tb_excitation_drive`: exact 16/80/208-cycle periods at N=1/5/13, zero drift | **[IMPL]** Phase 4 |
| DR-015 | Drive outputs shall never both assert | break-before-make, `2'b11` structurally unreachable | `tb_excitation_drive` assertion, every cycle | **[IMPL]** Phase 1.1 |
| DR-016 | SAR bit trials shall be performed in digital | `adc_dac_o`/`adc_comp_i` 8-trial search | `tb_sar_bit_trial`, full 0–255 sweep | **[IMPL]** Phase 1.2 |
| DR-017 | I and Q shall be accumulated separately | Two independent signed 16-bit accumulators (`i_acc_q`/`q_acc_q`), sampled at 4 phase indices per pair | `tb/smoke/tb_agriasic_digital_top.sv`: I=480, Q=320 from deliberately different deltas (channel-swap-proof), all 16 samples phase-matched | **[IMPL]** Phase 5 |
| DR-018 | Host shall never read a partial sum | Shadow registers (`i_shadow_q`/`q_shadow_q`) snapshot the live accumulators only on `S_LOOP -> S_DONE`, the one cycle `busy_o` drops | Confirmed in the section 6.11 cycle trace: shadows read 0 throughout the run, change only on that one transition | **[IMPL]** Phase 5.3 |
| DR-019 | Result block shall be readable within 16 SPI addresses | `REG_RESULT_IDX`/`REG_RESULT_DATA` indexed byte readout, auto-incrementing on data reads | SPI smoke: reads I/Q back via the index (0-3), confirms auto-increment (pointer=4 after 4 reads), confirms reserved index 4 reads 0 | **[IMPL]** Phase 6.1 (mechanism); result *data* for indices 4-12 is **[SPEC]**, and now known to need an architecture decision before it can be reached at all — see GAP-11 |
| DR-020 | SPI shall be the only asynchronous domain, oversampled rather than run as a second clock | `sclk_i`/`cs_n_i`/`mosi_i` 2FF-synchronized in `spi_slave`; zero `always_ff` outside `clk` anywhere in the tree | grep audit + `tb_spi_domain_crossing` | **[IMPL]** Phase 3.1 |
| DR-025 | Max SCLK shall be enforced at `f_clk/16` | Oversampling ratio itself is the enforcement mechanism, not a runtime rate check | `tb_spi_domain_crossing`: correct at exactly `f_clk/16`, corrupted below the sampling Nyquist rate | **[IMPL]** Phase 3.2 |
| DR-021 | MISO shall be high-Z when not selected | `miso_oe_o`, registered with `cs_n_i` in the SCLK domain | `assert property (miso_oe_o == !cs_n_i)` in SPI smoke | **[IMPL]** Phase 1.3 |
| DR-022 | External reset shall be asynchronously assertable, synchronously released | `rst_sync`, 2FF, one per chip-boundary top | `tb_rst_sync`, 4 clk-unaligned phase offsets | **[IMPL]** Phase 2.1 |
| DR-023 | Core shall be clock-enabled off during a measurement, never clock-gated | `core_clk_en_i` on every core register; driven by the shell's start/done handshake | `tb_agriasic_rv32i_e2e` PC-hold assertion, 93% frozen, zero violations | **[IMPL]** Phase 2.2 |
| DR-024 | Design shall use exactly one clock domain outside SPI | grep audit: every `always_ff` on `clk` or documented SPI exception | Structural grep, not simulation | **[IMPL]** Phase 2.3 |
| DR-026 | Every sample shall be taken at the exact documented phase index, not merely within the correct half-cycle | `measurement_fsm` strobes only on an exact `phase_index_i` match, now at 4 indices (0/4/8/12) since Phase 5, not 2 | `tb/smoke/tb_agriasic_digital_top.sv` phase-match check: compares the actual phase index at request time against the expected index for every one of 16 samples in a full 4-pair run | **[IMPL]** Phase 4.3/4.4, extended Phase 5 |
| DR-027 | The excitation divider shall support the full 1 kHz-10 MHz sweep range | `divider_i`/`cfg_divider_q` widened to 14 bits end-to-end (`excitation_ctrl`, `agriasic_digital_top`, both control shells, MMIO); off-by-one tick bug from the 8-bit design fixed so `divider_i` equals N exactly. SPI/programming interfaces reach the full range via `REG_FREQ_SEL`'s selector encoding (Phase 6, see DR-030) | `tb_excitation_drive`: exact period at N=1/5/13; MMIO reaches N up to 16383 directly, SPI/programming reach N=1/100/10000 via the three selector values | **[IMPL]** Phase 4.2 (MMIO) + Phase 6 (SPI/programming) |
| DR-028 | The I and Q channels shall never cross-contaminate each other's data | `sar_controller`'s D+/D− capture slots are reused for all four samples per pair; FSM sequencing (not new hardware) keeps `S_ACCUM_I` reading D(0)/D(180) before either slot is overwritten with D(90)/D(270) | Deliberately asymmetric I/Q deltas in every testbench (e.g. I=480, Q=320 — never equal) so a channel-swap or stale-slot bug would produce a numerically wrong result, not a coincidentally correct one | **[IMPL]** Phase 5 |
| DR-029 | Both result channels shall be readable identically across every host interface | `REG_RESULT_IDX`/`REG_RESULT_DATA` indices 0-3 (SPI), bare `result_i_o`/`result_q_o` ports (parallel programming interface), `REG_RESULT_I`/`REG_RESULT_Q` (RV32I MMIO, 0x8000_0018/0x001C) | SPI smoke and RV32I e2e both independently confirm I=480/Q=320-class results read back correctly through their respective paths | **[IMPL]** Phase 5 (registers existed); Phase 6 (SPI access mechanism changed to indexed) |
| DR-030 | The 1 kHz excitation point shall be reachable over the 2-byte SPI protocol without widening it | `REG_FREQ_SEL`, a 2-bit selector (0/1/2), translated combinationally to N (1/100/10000) — the only encoding that fits 14 bits of divider range into a 1-byte SPI write | `tb_agriasic_digital_spi_top.sv`: `REG_FREQ_SEL=0` reproduces the pre-Phase-6 N=1 behavior exactly (I=480/Q=320) | **[IMPL]** Phase 6, closes GAP-1 |
| DR-031 | A host shall be able to identify the design/revision it is talking to | `REG_ID`, fixed `8'h43`, read-only | `tb_agriasic_digital_spi_top.sv`: reads back `0x43` | **[IMPL]** Phase 6 |
| DR-032 | A silently-clamped M configuration shall be host-visible | `REG_STATUS` bit4 (SPI) / MMIO `REG_STATUS` bit4, set when `REG_PAIR_LOG2 > 6` is written | `tb_agriasic_digital_spi_top.sv`: sets on `PAIR_LOG2=7`, clears on a subsequent valid write | **[IMPL]** Phase 6 |
| DR-033 | Firmware shall sweep the three real excitation frequency points and store per-point I/Q results | `fw.c`'s `run_sweep_point()` writes `REG_DIVIDER` = 1/100/10000 in sequence, averages `NUM_MEASUREMENTS` runs at each, stores to `OUT_DIV`/`OUT_I`/`OUT_Q` scratch RAM arrays | `tb_agriasic_rv32i_e2e.sv`: all three divider values, both channels, at all three points confirmed correct after a real ~3.15M-cycle run including the true N=10000 point | **[IMPL]** Phase 7.1 |
| DR-034 | A host shall be able to identify that temperature was not sampled, rather than reading an uninitialized value as if it were real | `OUT_TEMP` sentinel, hardwired to `-1` | `tb_agriasic_rv32i_e2e.sv`/`tb_diag.sv`: confirm the sentinel is written | **[IMPL]** Phase 7.3 (the sentinel only — no temperature sensing exists, see GAP-11's header note in `fw.c`) |
| DR-035 | The accumulator shadow-register snapshot contract (never updates while busy) shall be checked by a formal assertion, not only by inspection | `assert property (p_shadow_stable_while_busy)` in `tb/smoke/tb_agriasic_digital_top.sv` | Passes across the full 4-pair run; would fail if `i_shadow_q`/`q_shadow_q` ever changed value on any cycle `busy_o` reads 1 | **[IMPL]** Phase 8, closes V-4 |
| DR-036 | A sample strobe shall rise only on an exact phase-index match for its own wait state, checked by a formal assertion | `assert property (p_sample_req_exact_phase_match)` in `tb/smoke/tb_agriasic_digital_top.sv`, correlating `measurement_fsm.state_q` with `exc_phase_index` at the exact rising edge of the internal `sample_req` wire | Passes across the full run; would catch a target-swap bug a weaker "matches any of the four" check could miss | **[IMPL]** Phase 8, closes V-5 |
| DR-037 | Neither accumulator shall exceed its documented safe range at any point during a run, not just at completion | `assert property (p_i_acc_in_range)` / `p_q_acc_in_range`, bounding `i_acc_q`/`q_acc_q` to ±16320 every cycle | Passes across the full run, including the M=64 saturating edge case (`tb_accum_edge_cases.sv`) which reaches exactly that bound | **[IMPL]** Phase 8 (8.2) |
| DR-038 | No `settle`/`conv` combination across a representative grid shall hang or produce a wrong result | `tb_settle_conv_sweep.sv`: 9 settle values × 6 conv values = 54 points, each run to completion with a timeout | 54/54 points pass; documented as a practical, non-exhaustive grid, not the literal 65,536-point sweep V-1's original wording specifies (see the Phase 8 section 10 note on why) | **[IMPL]** Phase 8, closes V-1 |
| DR-039 | Odd, ±1, and saturating pair differences shall accumulate exactly, with no hidden rounding or truncation | `tb_accum_edge_cases.sv`: four cases including the real M=64/delta=255 saturating point (expected and measured: 16320) | All four cases pass exactly | **[IMPL]** Phase 8, closes V-2 (the original D-3-style rounding defect this item was written against is now structurally impossible — no shift/round exists in the arithmetic path — so this is regression coverage, not defect-hunting) |

---

## 12. Verification Plan

### 12.1 Test categories
- T1 Reset determinism and startup
- T2 Nominal sequence completion and result correctness
- T3 SPI legal transactions and readback integrity
- T4 SPI illegal command/address/RO-write behavior
- T5 Sticky error clear and command recovery
- T6 CDC sanity on byte-valid pulse semantics
- T7 Settle-interval monotonicity and deadlock freedom **(new, D-1/D-2)**
- T8 Drive-overlap and half-cycle symmetry assertions **[IMPL]** as of Phase 4 (structural, both properties hold for the free-running design)
- T9 Bit-trial sequencing against an ADC behavioral model **[IMPL]** as of Phase 1 (`tb_sar_bit_trial.sv`)
- T10 Exact phase-index match on every sample, all four points **(Phase 4, extended Phase 5)** — **[IMPL]**
- T11 I/Q channel isolation against cross-contamination **(new, Phase 5)** — **[IMPL]**
- T12 Accumulator shadow-register snapshot timing (never updates while `busy_o` is high) **(new, Phase 5)** — **[IMPL]**, now a formal `assert property` (Phase 8, closes V-4)
- T13 Sample-strobe rise correlated with an exact phase-index match, per wait state **(new, Phase 8)** — **[IMPL]**, formal `assert property`, closes V-5
- T14 Accumulator range bound (±16320) held at every cycle, not just at completion **(new, Phase 8)** — **[IMPL]**, formal `assert property`
- T15 Settle × conv practical grid, no hangs or wrong results **(new, Phase 8)** — **[IMPL]**, closes V-1 (54-point grid, not the literal 65,536-point sweep — see section 10's Phase 8 note)
- T16 Accumulator edge cases: odd, ±1, and true M=64 saturating differences **(new, Phase 8)** — **[IMPL]**, closes V-2
- T17 Real 3-frequency-point sweep in firmware, including the true N=10000 point **(new, Phase 7)** — **[IMPL]**

### 12.2 Current collateral **[IMPL]**
The `verify_all.sh` sweep runs twelve stages, all passing, in ~32 seconds of
wall-clock time total. (Stages 1-9 have carried this numbering since Phase 3;
stage 10 was added in a later lint/synthesizability audit pass, not tied to
any single Rev 4.3 phase, section 10.3 GAP-8; stages 11-12 are Phase 8.)

| Stage | Check | Result |
|---|---|---|
| 1 | Full chip lint | clean |
| 2 | Measurement smoke | pass, I=480/Q=320, all 16 samples phase-matched (0 errors); shadow-register, phase-match, and accumulator-range formal asserts all hold (Phase 8) |
| 3 | SPI smoke | pass, I=480/Q=320 read back via indexed `REG_RESULT_IDX`/`REG_RESULT_DATA` (Phase 6); auto-increment, reserved-index-zero, `REG_ID`, and overrange bit all checked |
| 4 | SAR bit-trial unit test (Phase 1) | pass, exact convergence over 0–255 |
| 5 | Excitation free-running phase generator (Phase 4, rewritten) | pass: exact 16/80/208-cycle periods at N=1/5/13, phase-to-drive map (0-6 P, 7 dead, 8-14 N, 15 dead), `2'b11` unreachable holds, half-cycle symmetry now explicit (Phase 8: 7N/7N counted directly, not inferred) |
| 6 | Reset synchronizer (Phase 2.1) | pass, 4 clk-unaligned phase offsets |
| 7 | SPI clk-domain rework (Phase 3) | pass, correct at exactly `f_clk/16`, corrupted below Nyquist, clean mid-byte reframe |
| 8 | Settle timing regression (reinterpreted for Phase 4: settle now counts excitation periods; extended Phase 5 to check both channels) | pass, I=480/Q=320 at all 4 settle values |
| 9 | End-to-end firmware + measurement (incl. core clock enable, Phase 2.2; both channels, Phase 5; real 3-point frequency sweep, Phase 7) | pass, all 3 points (N=1/100/10000) confirmed, ~3.15M cycles for the full sweep, 93% of cycles frozen |
| 10 | Control shell descope fallback lint (`.orig`, closes GAP-8) | clean |
| 11 | Accumulator edge cases (Phase 8, closes V-2) | pass: odd (55), +1, -1, and true M=64 saturating (16320) all exact |
| 12 | Settle × conv grid sweep (Phase 8, closes V-1) | pass: 54/54 practical grid points, no hangs, correct results |

**Phase 7 required no new testbench-modeling fix** — the sweep is pure
firmware (`fw.c`) plus scratch-RAM address changes; the ADC behavioral model
and excitation timing that caused the Phase 4/5 fixes were untouched.
`tb_agriasic_rv32i_e2e.sv` and `tb_diag.sv` needed real content updates
(new memory layout, new expected checks, a ~3.15M-cycle timeout budget for
the real N=10000 sweep point) but no new class of bug in the fix sense — the
tests simply needed to check the new, correct behavior instead of the
retired single-frequency demo.

**Testbench fix made necessary by Phase 4, applied to all six testbenches with
a behavioral ADC model** (`tb/smoke/tb_agriasic_digital_top.sv`,
`tb/smoke/tb_agriasic_digital_spi_top.sv`, `tb/tb_agriasic_rv32i_e2e.sv`,
`tb/tb_diag.sv`, `tb/tb_settle_timing.sv`, `tb/tb_spi_diag.sv`): the comparator
model now latches its target on `adc_sample_o` (track-and-hold) instead of
reading `exc_drive_p_o` live every cycle — see section 10, Phase 4 for why a
live read silently produced a wrong result (`480` expected, `204` measured)
once excitation became free-running.

**Second testbench-modeling fix made necessary by Phase 5, same six
testbenches:** the track-and-hold model above, keyed on `exc_phase_index`,
broke again once four phases needed distinguishing instead of two (one-cycle
sample-accept lag inside `sar_controller` means `exc_phase_index` has already
advanced past its nominal value by the time `adc_sample_o` fires at small N).
Fixed by keying every model on `measurement_fsm.state_q` instead — see
section 10, Phase 5 for the full explanation and the `SMOKE_FAIL: expected
I=480 got=0` symptom this produced before the fix.

**Phase 6 required no new testbench-modeling fix** — the register map rework
is entirely host-facing protocol logic (SPI/programming-interface address
decode), with no interaction with the ADC model or excitation timing that
caused the Phase 4 and Phase 5 fixes. The one existing testbench pattern that
did need touching was hardcoded register addresses in `tb/tb_spi_diag.sv`
(raw `4'h5`/`4'hF` literals for what used to be `REG_STATUS`/an invalid
address) — fixed to use the renumbered addresses, and to stop referencing
`dut.cfg_divider_q`, which no longer exists as a stored register on the SPI
path (`cfg_divider_w` is combinational now, derived from `cfg_freq_sel_q`).

**Separately, and NOT re-run for Phase 2:** 77/77 on the rv32ui ISA suite +
dhrystone, which needs the external CIS 5710 cocotb harness and a built
`riscv-tests`, neither present in this environment. Phase 2.2 touched
`agriasic_rv32i_core.sv` (`DatapathPipelined`, `RegFile`) — the same file this
suite exercises. The generic `Processor`/`MemorySyncUnified` wrapper that
harness uses ties `clk_en_i` permanently high (section 6.12), so every branch
this change added is provably dead code on that path — but "provably dead
code" is not the same as "re-run and confirmed 77/77." Re-run this suite
before treating Phase 2 as signed off.

Style constraints: SystemVerilog, self-checking testbenches, **Icarus-compatible**
— no vendor PLI (`$fsdbDump*`, `$vcdplus`, `$shm`) anywhere in the tree.

### 12.3 Verification additions from the Rev 4.3 baseline — closed as of Phase 8

From the Rev 4.3 baseline, section 8.1.

| # | Check | Status |
|---|---|---|
| V-1 | **Sweep `settle` against `conv`** with a completion timeout on every combination | **Closed, practically not exhaustively.** `tb_settle_conv_sweep.sv`: a 9x6 = 54-point grid across both axes' extremes and several intermediate scales, not the literal 65,536-point 8-bit x 8-bit grid the original wording specifies — see the section 10 Phase 8 note on why literal exhaustive coverage isn't attempted and why this grid still catches the same class of bug D-1/D-2 were |
| V-2 | Check `result == M × (D+ − D−)` for **odd** differences, **±1** differences, and **saturating** differences | **Closed as regression coverage, not defect-hunting.** `tb_accum_edge_cases.sv` covers all three classes, including the true M=64 saturating case (16320). The D-3-style rounding defect V-2 was originally written to catch is now structurally impossible — no shift or rounding exists anywhere in the current arithmetic path — so this guards against regression, not an open defect |
| V-3 | Superseded by Phase 4 — there is no longer a phase command to bound (section 9.3) | Confirmed still superseded; nothing to do |
| V-4 | Assert the accumulator shadow register never updates while `busy` is high | **Closed.** `assert property (p_shadow_stable_while_busy)` in `tb/smoke/tb_agriasic_digital_top.sv` — a real formal restatement, not just the trace-inspection evidence Phase 5 originally offered |
| V-5 | Assert a strobe is issued only when the phase counter equals the selected index | **Closed.** `assert property (p_sample_req_exact_phase_match)`, correlating `measurement_fsm.state_q` with the exact phase-index value on the rising edge of the internal sample-request wire — a genuinely different verification angle than the existing state-transition-based phase-match check, not a restatement of it |

**All five items from this section are now resolved** (three closed with new
regression coverage, one confirmed structurally moot, one confirmed already
superseded). This section is kept rather than deleted so the reasoning behind
each scope decision (especially V-1's practical-grid and V-2's
regression-not-defect-hunting framing) stays visible to whoever reads this
next.

### 12.4 Remaining gaps
- **GAP-11 (Phase 7 finding):** `agriasic_digital_rv32i_top` has no SPI or
  other host-facing pins at all (confirmed by grep, zero matches) — the
  firmware-computed sweep results in `fw.c`'s scratch RAM have no path to any
  real external host. See section 10.3 GAP-11 for the three architectural
  resolution options. This is the single most significant open item from
  Phases 7-8 and should be resolved before Rev 4.3 is considered
  integration-ready, not just simulation-clean
- Broader randomized SPI traffic and error-recovery tests
- Formal or lint CDC signoff evidence for the byte transport bridge
- Reference traces not regenerated for the synchronous-SRAM core, so cycle-level
  trace comparison is unavailable
- `OUT_TEMP` (Phase 7.3, temperature/compensation channel) remains an
  unimplemented `-1` sentinel — no temperature sensor interface exists in the
  current RTL to wire it to

---

## 13. Acceptance Criteria for Digital Signoff

- A1. DR-001..DR-013 pass simulation-based checks with archived logs
- A2. Protocol negative paths are reproducible and deterministic
- A3. STATUS and RESULT mirrors stay software-coherent during and after a run
- A4. Reset and restart behavior is stable under repeated runs
- A5. The port-identical microsequencer fallback build remains regression-clean
  — **currently unverified by automation** (GAP-8): `agriasic_rv32i_control_shell.sv.orig`
  is checked only by hand, most recently during Phase 5 when its divider-width
  port was found already stale. Add a dedicated lint script before treating
  this criterion as met on an ongoing basis, not just as of this writing
- A6. For Rev 4.3 signoff: remaining **[SPEC]** rows (DR-019's result-*data*
  half, Phase 7) implemented, and GAP-2, GAP-6, GAP-7, GAP-8, GAP-9 and
  GAP-10 closed. GAP-1 is fully closed as of Phase 6. DR-014..DR-018,
  DR-020..DR-032 are already **[IMPL]** as of Phases 1-6, except GAP-10's
  two inert placeholders (`REG_PHASE_IDX`, `REG_CTRL`'s core-enable bit),
  which are in the register map but not covered by any DR row — they need a
  requirement written for them, not just an implementation, once their
  semantics are actually decided. **DR-019 is now fully closed (Phase 7):**
  the sweep firmware in `fw.c` computes and stores I/Q results for all three
  frequency points, verified end-to-end (section 12.2, stage 9). GAP-2,
  GAP-6, GAP-7, GAP-8 and GAP-9 are closed as of the lint/synthesizability
  audit and Phase 7-8 work; GAP-10 remains open by design (section 10.3) and
  should not be closed without a real decision on `REG_PHASE_IDX`/core-enable
  semantics
- A7. **Verification items V-1, V-2, V-4, V-5 from section 12.3 are closed**
  (V-3 confirmed superseded) — this criterion is met as of Phase 8
- A8. **GAP-11 (RV32I top has no host-facing path for its own sweep results)
  must be explicitly acknowledged and resolved, or explicitly waived, before
  Rev 4.3 is called integration-ready.** Simulation-clean firmware that
  computes unreachable results is not the same as a working end-to-end
  system; this criterion exists so that distinction cannot be silently
  dropped during signoff

---

## 14. Artifact Map

Paths are relative to the repository root.

| Artifact | Path |
|---|---|
| RV32I chip top | `agriasic_digital_v2/rtl/agriasic_digital_rv32i_top.sv` |
| SPI top | `agriasic_digital_v2/rtl/agriasic_digital_spi_top.sv` |
| Measurement top | `agriasic_digital_v2/rtl/agriasic_digital_top.sv` |
| Control shells | `agriasic_digital_v2/rtl/agriasic_rv32i_control_shell.sv{,.orig}` |
| Reset synchronizer (Phase 2.1) | `agriasic_digital_v2/rtl/rst_sync.sv` |
| Control modules | `agriasic_digital_v2/rtl/ctrl/` |
| Processor and SRAM wrappers | `agriasic_digital_v2/rtl/rv32i/` |
| Firmware | `agriasic_digital_v2/fw/` |
| Smoke testbenches | `agriasic_digital_v2/tb/smoke/` |
| Settle regression | `agriasic_digital_v2/tb/tb_settle_timing.sv` |
| SAR bit-trial regression (Phase 1) | `agriasic_digital_v2/tb/tb_sar_bit_trial.sv` |
| Excitation free-running phase generator regression (Phase 1 break-before-make, rewritten Phase 4 for the free-running interface) | `agriasic_digital_v2/tb/tb_excitation_drive.sv` |
| Reset synchronizer regression (Phase 2.1) | `agriasic_digital_v2/tb/tb_rst_sync.sv` |
| SPI clk-domain regression (Phase 3) | `agriasic_digital_v2/tb/tb_spi_domain_crossing.sv` |
| End-to-end testbench (incl. core clock-enable monitor, Phase 2.2; both I/Q channels, Phase 5; 3-point sweep, Phase 7) | `agriasic_digital_v2/tb/tb_agriasic_rv32i_e2e.sv` |
| Diagnostic testbench (Phase 7 sweep timing) | `agriasic_digital_v2/tb/tb_diag.sv` |
| Accumulator edge-case regression (Phase 8, closes V-2) | `agriasic_digital_v2/tb/tb_accum_edge_cases.sv` |
| Settle x conv grid sweep (Phase 8, closes V-1) | `agriasic_digital_v2/tb/tb_settle_conv_sweep.sv` |
| Shadow-register / phase-match / accumulator-range formal assertions (Phase 8, closes V-4/V-5) | `agriasic_digital_v2/tb/smoke/tb_agriasic_digital_top.sv` |
| Regression scripts (incl. `accum_edge_cases.sh`, `settle_conv_sweep.sh`, `lint_shell_orig.sh`) | `agriasic_digital_v2/tb/rv32i_regression/` |
| Rev 4.3 design note | `agriasic_digital_v2/docs/agriasic_rev43_phase_locked_design.md` |
| Implementation plan | `agriasic_digital_v2/docs/agriasic_digital_implementation_plan.md` |
| Timing checklist | `agriasic_digital_v2/docs/agriasic_digital_timing_checklist.md` |
| Diagrams | `agriasic_digital_v2/docs/diagrams/` |
| Slides | `agriasic_digital_v2/docs/slides_svg/` |

---

This MAS is a living document. The **[IMPL]** / **[SPEC]** / **[GAP]** tags are
load-bearing: they are what keeps the target architecture from being mistaken for
the shipped one. Update them in the same commit as the RTL they describe.

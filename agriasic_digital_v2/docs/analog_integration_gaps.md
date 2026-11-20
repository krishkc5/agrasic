# Analog integration gaps

Open questions on the analog/digital boundary, found while building the
behavioural AFE macro (`rtl/analog/agriasic_afe_top.sv`) and the chip top
(`rtl/agriasic_asic_top.sv`), and tracked since.

Each live gap is reflected in the model: either a placeholder parameter whose
value is a guess, or a check that fires. Fixing one means replacing a number
or answering a question — not changing the model's structure.

The digital boundary itself is not in question. It is the eight signals of
`docs/interface_contract.md`, "Analog front-end interface (Rev 5,
tetrapolar)", and the model implements exactly those.

| | Gap | Status |
|---|---|---|
| A1 | SAR reference pair undocumented | **Closed** 2026-11-19 |
| A2 | S/H acquisition time constant inferred from a plot | Open |
| A3 | Schematic pins with no counterpart on the boundary | **Closed** (interface), numbers provisional |
| A4 | TIA gain code 3 never characterised | Partly answered |
| A5 | E1 drive excursion unspecified | Open |
| A6 | Hold release and acquisition window | **Closed** 2026-11-20 |
| A7 | Temperature channel has no route to the converter | Open |
| A8 | End-to-end current-path response after the restructure | Open, blocked |
| A9 | Fast-path window is narrower than the overrange flag | Open |
| A10 | DC headroom at high gain | Open, in progress |
| A11 | Hold droop over the 264 ns hold | Open, bounded |

---

## A6 — hold release and acquisition window — CLOSED

Kept at the top because it was the one that looked unfixable.

The concern was that `afe_sample_o` is a one-clock pulse with no release
signal anywhere on the boundary, which seemed to force the analog to
self-time the hold against a window the firmware can move. Measured from the
chip-top bench, the budget appeared infeasible: a 450 ns conversion pair and
a 475 ns strobe period leave 25 ns to re-acquire, against roughly 76 ns
needed.

**That was wrong about the analog, in the design's favour.** The hold does
not last the whole conversion pair. It releases once the CDAC has sampled the
current channel onto its own array, so the real figures are a **264 ns hold
and 211 ns of re-acquisition** inside the same 475 ns period — 2.8× the
requirement.

Two follow-ups also came back clean:

- **The release is derived from the digital's own sequencing plus internal
  delays, not a fixed analog timer** (confirmed 2026-11-20). It therefore
  tracks whatever firmware does to `mux_settle` and `conv_cycles`, which was
  the part that looked structurally unfixable.
- **Both hold cells share controls**, so the channels release together. An
  earlier proposal to swap the conversion order so the slower current channel
  got the longer window buys nothing and was dropped. No RTL change.

---

## A2 — the acquisition time constant is read off a plot — OPEN

`SH_TAU_NS = 7.2` is inferred from the sampling slide: settling to half an
LSB of full scale takes about 6.24 time constants, and the curve crosses at
roughly 45 ns. Hold-node capacitance (2.0396 pF) comes from the subsystem
slide.

Less urgent than it was — A6's 211 ns window has margin at any plausible τ —
but it still sets a real error. Running the firmware, worst-case acquisition
error is **1.42 LSB** at the top sweep point, against the half-LSB criterion
the sampling slide itself uses. The cause is the interaction with excitation
frequency, not the settling figure: point 0 runs `exc_divider = 1`, roughly a
10 MHz excitation, where a 7.2 ns time constant is no longer negligible
against the signal's slew rate and the S/H tracks with a lag. A code-domain
ADC model cannot show this, because the error depends on where in the
waveform the strobe lands.

**Request:** extracted switch on-resistance and hold capacitance, so this is
back-annotated rather than read off a graph.

---

## A3 — schematic pins with no counterpart — CLOSED for the interface

The ADC schematic shows `CLK_COMP`, `RESET` and `DAC_EN`/`SAMPLE`, none of
which exist on the digital boundary. Resolved 2026-11-19: **the macro
generates them internally from `afe_adc_dac_o`, `afe_conv_start_o` and
`afe_adc_enable_o`, with no second SAR search and no code-out pin.** That is
exactly the contract.

Worth noting an earlier macro version *did* run its own successive
approximation, which would have duplicated `sar_controller` outright.
**Confirm the new version is the one that goes to layout.**

**The numbers are provisional.** Referenced to our code edge — the only
reference the boundary has:

| | |
|---|---|
| enable offset after code edge | 6.25 ns |
| DAC settling after enable | 3.125 ns |
| comparator, worst of five corners at ±1 mV | 0.96 ns |
| **total from code edge** | **10.3 ns** |

`sar_controller` waits `S_TRIAL_SET` + (`conv_cycles`+1) = 3 cycles =
18.75 ns at `REG_CONV = 1`, so there is 8.4 ns of margin. `REG_CONV = 0`
would give 12.5 ns and only 2.2 ns — **too tight; leave it at 1.**

Provisional because the 6.25 ns enable offset was measured on the *old*
sequencer. The new interface's offset is still being characterised.

---

## A4 — TIA gain code 3 never characterised — PARTLY ANSWERED

`gain_decode` in `agriasic_rv32i_mmio.sv` maps `AFE_CTRL` code 3 to `3'b111`,
all three feedback switches in parallel. The current-sense slide simulated
only the three one-hot settings.

Answered 2026-11-20 to the extent that the design "works in the cases tested
across all four gains" — so the code is not unreachable or broken. Still
missing is the gain and bandwidth pair, which the model needs. It currently
uses 1483 Ω, the arithmetic parallel combination of the three, not a
simulation result.

Superseded in part by **A8**: the restructure will change all four numbers
anyway.

---

## A8 — end-to-end current-path response after the restructure — OPEN

The analog side is lowering the feedback resistors and adding a fixed-gain
amplifier after the PGA, to fix A10 while holding total transimpedance
(2026-11-20).

Noise cost looks negligible: Rf's own thermal current noise at 28.18 kΩ
integrates to about 3.5 nA rms over a 13 MHz noise bandwidth, under 1% of the
measured 400 nA, so Rf is not setting the floor and dropping it 10× only
raises that term to ~11 nA.

**What the digital needs when it settles: end-to-end gain and phase versus
frequency for the whole current path, per switch setting — not per-stage
specs.** A second stage adds a second pole, and the off-die de-embedding
works on the composite current path against the composite voltage path. Stage
specs would just force us to compose them ourselves and get it subtly wrong.

Current known response, for the 13 MHz high-gain setting. Phase lag is
atan(f / 13 MHz) on the current channel against 266.9 MHz on the voltage
channel; only the difference reaches `Z = dV / I`:

| Sweep point | f | net phase error | \|Z\| error |
|---|---|---|---|
| 0 | 10 MHz | −35.5° | +26% |
| 1 | 1 MHz | −4.2° | +0.3% |
| 2 | 312.5 kHz | −1.3° | negligible |
| 3–7 | ≤100 kHz | <0.5° | negligible |

Corrected off die, not in RTL.

**Also ask:** whether the restructure keeps three settings plus all-parallel.
That is the one outcome here that touches RTL, since `gain_decode` maps a
2-bit code to exactly four switch combinations.

---

## A10 — DC headroom at high gain — OPEN, IN PROGRESS

At the high-gain setting the large feedback resistor puts the output DC well
away from mid-scale — measured around 0.59 V — which costs swing and clips
large signals. With the fast-path floor at 0.50 V that leaves about 90 mV of
downward swing, roughly **23 LSB** of usable amplitude against ~2.9 LSB of
noise: about 4 effective bits, or 6 with `REG_PAIR_LOG2 = 6`.

Two things the digital contributes here:

- **A static DC offset is not an accuracy problem.** The measurement
  subtracts opposite excitation phases (`dv_i = Σ[D(0°) − D(180°)]`), so a
  constant offset cancels exactly. It costs headroom only. The spec is
  "enough headroom never to clip", not "output DC equals input DC" — a much
  easier target. Clipping is what breaks it, because it is nonlinear and the
  cancellation then fails.
- **Excitation amplitude is a free lever.** `AFE_CTRL[5:4]` selects
  full/half/quarter/eighth and firmware currently writes full, which is the
  worst thing to pair with maximum gain. High gain at half amplitude still
  nets about 6× more signal than low gain at full amplitude.

Being addressed on the analog side by the A8 restructure plus work on output
swing.

---

## A9 — the fast-path window is narrower than the overrange flag — OPEN

The converter range is 0.4–1.4 V, but the **fast sampling path is targeted at
0.5–1.3 V** (2026-11-19) — codes 26 to 230 of 0 to 255. Outside that window a
conversion still returns a code, but it is not trustworthy at speed.

`sar_controller.sv:242` flags overrange only at code 0 or code 255, so the
digital cannot currently tell the difference between a trustworthy code and
one outside the fast-path window. If the 0.5–1.3 V target holds, tightening
that comparison to `ADC_FAST_CODE_LO`/`ADC_FAST_CODE_HI` is a one-line change
and makes the flag mean "untrustworthy" rather than just "railed".

Deliberately not changed yet: the window is a target, not a measured limit.

---

## A11 — hold droop over the 264 ns hold — OPEN, BOUNDED

Now that A6 is understood, the current channel's sample is held for about
264 ns before the CDAC captures it. The behavioural model assumes zero
leakage (`DROOP_V_PER_US = 0.0`) and would not catch droop.

The bound is easy: half an LSB over 264 ns on 2.0396 pF allows

```text
  I_leak  <  C * dV / dt  =  2.0396 pF * 1.953 mV / 264 ns  ~=  15 nA
```

15 nA is generous at room temperature but not obviously safe at the top of an
outdoor temperature range, where junction leakage climbs. **Worth one
confirmation rather than an analysis.**

---

## A5 — E1 drive excursion unspecified — OPEN

`afe_sine_code_o` is documented as offset binary with mid-code 128 = VCM,
which fixes the centre of the excitation swing but not its span. The model
uses ±0.45 V as a placeholder.

This matters more than it looks: the excitation amplitude sets the dV the PGA
sees, and the PGA has a fixed 4.1 dB gain with no digital trim, so the drive
level is the only thing setting that channel's operating point.

**Question:** what differential swing do code 0 and code 255 produce at E1?

---

## A7 — the temperature channel has no route to the converter — OPEN

`afe_mux_sel_o` is two bits, but the interface contract defines only codes 0
(dV) and 1 (current). The subsystem slide shows a temperature divider at
`VIN_T` with no other path to the converter.

Code 2 is the obvious candidate, but that is an inference, so the model
drives VCM and warns rather than inventing the channel. `vin_t_i` is present
on the macro boundary and connected to nothing.

**Question:** is `VIN_T` meant to be mux code 2? If so the measurement FSM
needs a third channel state and the contract needs a row — small, but not
free, and better decided before tapeout.

---

## Closed, retained for context

**A1 — SAR reference pair.** Back-derived from the sampling slide's 1.953 mV
half-LSB as 0.4 V / 1.4 V; confirmed directly by the analog side on
2026-11-19. The derivation was right, and every absolute voltage in the model
now rests on a confirmed number: full scale 1.000 V, LSB 3.906 mV.

**`afe_adc_enable_o` cannot serve as a hold release.** It goes low between
the two conversions of a pair. This mattered while A6 was open; recorded so
nobody re-proposes it.

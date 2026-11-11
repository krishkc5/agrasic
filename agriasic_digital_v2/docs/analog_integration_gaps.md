# Analog integration gaps

Seven things the analog/digital boundary does not currently pin down, found
while building the behavioural AFE macro (`rtl/analog/agriasic_afe_top.sv`)
and the chip top (`rtl/agriasic_asic_top.sv`).

Each one is live in the model: either a placeholder parameter whose value is
a guess, or a check that fires. Fixing a gap means replacing a number or
answering a question — not changing the model's structure.

The digital boundary itself is **not** in question. It is the eight signals
of `docs/interface_contract.md`, "Analog front-end interface (Rev 5,
tetrapolar)", and the model implements exactly those. Two of the gaps below
(A3, A4) are already recorded there as open; the other five are new.

---

## GAP-A6 — how is `afe_sample_o` wired to the hold switch? *(highest impact)*

**This is the only gap that currently has a measured consequence, and it is
large.**

`afe_sample_o` is a **one-clock pulse**: `sar_controller.sv` drives it low by
default every cycle and sets it only on request acceptance, so at 160 MHz it
is 6.25 ns wide. Nothing in the repo says how the analog connects that pulse
to the sampling switch, and the two possible readings differ by about 8× in
acquisition time:

| Reading | Acquisition window | dV error | current error | dV code (expect 169) |
|---|---|---|---|---|
| Track continuously, pulse commands a freeze | the whole preceding interval | −0.00 LSB | 0.00 LSB | 169 |
| Pulse **is** the acquisition window | 6.25 ns | **−17.84 LSB** | +4.99 LSB | 151 |

Measured by driving the model with a known 100 mV differential and 20 µA
return current and running the same SAR algorithm `sar_controller.sv` runs.

The second reading puts the dV channel 18 LSBs — 7% of full scale — away from
the right answer. The converter's 7.42-bit ENOB would be irrelevant; the
sample is already wrong before it reaches the CDAC. The sampling slide shows
the storage capacitor needing roughly 40–50 ns to settle below half an LSB
from a 10 Ω source, against 6.25 ns available.

The RTL's own wording ("freezes **both** channels at this instant") points at
the first reading, which is why the model defaults to it. But that is an
inference from a comment, not a specification.

**Question for analog:** is the sampling switch closed by default and opened
by this pulse, or closed only while the pulse is high?

### Second half: there is no release signal, and self-timing will not work

Nothing on the boundary marks "both conversions of this pair are done", so
under the first reading the analog has to self-time the hold with a fixed
timer. `tb_agriasic_asic_top.sv` measures both bounds on that timer, running
the real firmware:

```
longest conversion pair : 450 ns   (the hold must EXCEED this)
shortest strobe gap     : 475 ns   (the hold must stay UNDER this)
```

That leaves **25 ns** between the end of the conversion pair and the next
strobe — and that 25 ns is all the time the S/H has to re-acquire before it
is frozen again.

Re-acquiring to within half an LSB takes about 6.24 time constants. At the
`SH_TAU_NS = 7.2` inferred from the sampling slide, that is **45 ns**:

```
  available : 475 - 450 = 25 ns
  needed    : 6.24 x 7.2 = 45 ns
```

**The budget does not close, by 20 ns.** There is no fixed hold time that
works, whatever its tolerance: too short and the converter digitises a
re-acquiring node, too long and the S/H is still holding when the next phase
point is strobed. Neither failure is visible to the digital.

This is observable, not just arithmetic. With the hold set to 460 ns — the
only value that even approximately fits — the chip-top bench measures a
worst-case acquisition error of **13.62 LSB** on the current channel.

**Caveat, stated plainly:** the 45 ns rests on `SH_TAU_NS`, which is GAP-A2,
read off a plot. The 25 ns does not — it comes from the RTL's own behaviour
under real firmware. If the true time constant is below about 4 ns the budget
closes; at the value the slide implies it does not. **Settling GAP-A2 is
therefore the first thing to do**, because it decides whether this is a
scheduling problem or not a problem at all.

If it is real, the fixes are all on the digital side and all cheap: lengthen
the gap between phase points, shorten the conversion pair via `conv_cycles`,
or both. Worth noting that `mux_settle` and `conv_cycles` are
firmware-writable, so firmware can close this window at run time regardless
of what the hardware defaults are.

Too short and the converter digitises a re-acquiring node. Too long and the
S/H is still holding when the next phase point is strobed, so that sample is
silently stale. Neither failure is visible to the digital.

**Conclusion: self-timing is not a viable answer even if the budget closes.**
Both ends of the window are firmware-writable, so no fixed analog timer can
be guaranteed correct. The boundary wants an explicit release — most cheaply
an `afe_hold_o` level the digital drives high at the strobe and low when the
second conversion of the pair retires. One pin, a contract change, and a few
gates in `sar_controller.sv`, and it makes the whole question go away: the
S/H then re-acquires for the entire remainder of the period instead of
whatever a timer guessed.

**Questions for analog:** (a) what is the real acquisition time constant
(GAP-A2), and (b) can you take a hold level instead of deriving the hold from
the strobe?

---

## GAP-A3 — three schematic pins with no counterpart on the boundary

The ADC schematic shows `CLK_COMP`, `RESET` and `DAC_EN`/`SAMPLE` on the
`cdac_diff_8b` and `dynamic_comparator` cells. The digital boundary carries
only `afe_adc_dac_o`, `afe_conv_start_o` and `afe_adc_enable_o`, so all three
must be generated **inside** the macro.

`docs/interface_contract.md` already flags the related item: the ADC progress
report's Q7 measures settling from **reference-switch enable**, while the
digital can only offer the code edge.

The model therefore times settling from the code edge, which is the
**optimistic** case. If the real block needs an explicit per-trial enable,
the usable settling window is shorter than modelled and `REG_CONV` is
undersized by the difference — which shows up as conversion errors, not as a
timing violation.

**Question for analog:** are `CLK_COMP`, `RESET` and the per-trial DAC enable
generated inside the macro from the three signals available, or do they need
to come out to the boundary? The second answer costs a handful of gates in
digital and a contract change.

Placeholders: `CDAC_SETTLE_NS = 3.0`, `COMP_REGEN_NS = 1.5`.

---

## GAP-A1 — the SAR reference pair is not written down

No file in the repo states VREFH or VREFL. The values in the model are
**back-derived**: the sampling slide quotes a half-LSB of 1.953 mV, so
LSB = 3.906 mV, so an 8-bit full scale is 1.000 V; centring that on the
documented VCM of 0.9 V gives 0.4 V / 1.4 V.

Every absolute voltage in the model, and every code-to-voltage conversion
anyone does off-die, rests on that arithmetic.

**Questions for analog:** (a) confirm VREFH/VREFL, (b) are they pads or
generated on die from a bandgap? The model declares them as inputs, which is
the assumption that fails loudly if wrong.

---

## GAP-A2 — the acquisition time constant is read off a plot

`SH_TAU_NS = 7.2` is inferred from the sampling slide: settling to half an LSB
of full scale takes about 6.24 time constants, and the curve crosses at
roughly 45 ns. Hold-node capacitance (2.0396 pF) comes from the subsystem
slide.

**Request:** the extracted switch on-resistance and hold capacitance, so this
becomes a back-annotated number rather than a reading off a graph. GAP-A6's
margin depends directly on it.

**It is already costing more than half an LSB.** Running the real firmware,
the worst acquisition error is **1.42 LSB** even under the favourable
`FREEZE_ON_RISE` reading — against the half-LSB criterion the sampling slide
itself uses. The cause is not the settling figure but its interaction with
excitation frequency: the first sweep point runs `exc_divider = 1`, roughly a
10 MHz excitation, where a 7.2 ns time constant is no longer negligible
against the signal's slew rate and the S/H tracks with a lag. A code-domain
ADC model cannot show this, because the error depends on where in the
waveform the strobe lands.

Worth deciding deliberately: either accept a frequency-dependent gain and
phase error at the fast end of the sweep, or bound the sweep's top frequency
by the S/H time constant.

---

## GAP-A4 — TIA gain code 3 was never simulated

`gain_decode` in `agriasic_rv32i_mmio.sv` maps `AFE_CTRL` code 3 to `3'b111`,
all three feedback switches in parallel. The current-sense slide simulated
only the three one-hot settings:

| Wires | Gain | Bandwidth |
|---|---|---|
| `001` (a1) | 67.02 dB → 2.245 kΩ | 197.1 MHz |
| `010` (a2) | 74.27 dB → 5.168 kΩ | 99.8 MHz |
| `100` (a3) | 89.00 dB → 28.18 kΩ | 18.6 MHz |
| `111` | **?** | **?** |

The model uses 1483 Ω, the arithmetic parallel combination of the three — not
a simulation result.

**Either** supply the simulated gain and bandwidth for `111`, **or** say so
and code 3 gets removed from `gain_decode`. Note that an all-parallel network
gives the *lowest* transimpedance of the four, below code 0, so the code
ordering is not monotonic in gain.

---

## GAP-A5 — the E1 drive excursion is unspecified

`afe_sine_code_o` is documented as offset binary with mid-code 128 = VCM,
which fixes the centre of the excitation swing but not its span. The model
uses ±0.45 V as a placeholder that stays inside the rails.

This matters more than it looks: the excitation amplitude sets the dV the PGA
sees, and the PGA has a **fixed** 4.1 dB gain with no digital trim, so the
drive level is the only thing setting that channel's operating point.

**Question for analog:** what differential swing does code 0 / code 255
produce at E1?

---

## GAP-A7 — the temperature channel has no route to the converter

`afe_mux_sel_o` is two bits wide, but `docs/interface_contract.md` defines
only codes 0 (dV) and 1 (current). The subsystem slide shows a temperature
divider at `VIN_T`, and there is no other path by which the converter could
reach it.

Code 2 is the obvious candidate, but that is an inference, so the model
drives VCM and warns rather than inventing the channel. `vin_t_i` is present
on the macro boundary and connected to nothing.

**Question for analog:** is `VIN_T` meant to be mux code 2? If so the
measurement FSM needs a third channel state and the contract needs a row —
small, but not free, and better decided now than after tapeout.

---

## Not a gap, but worth stating

`afe_adc_enable_o` is documented as the comparator bias/power gate and goes
**low between the two conversions of a pair**, so it cannot serve as the S/H
hold-release signal (see GAP-A6). If the analog was planning to use it that
way, it will not work.

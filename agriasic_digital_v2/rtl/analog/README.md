# Analog front end — two views of one macro

The AFE is **one hard macro**, `agriasic_afe_top`. Everything in this
directory is its *behavioural view*, used for simulation only. Synthesis
never reads a file from here.

```
rtl/analog/agriasic_afe_pkg.sv      electrical constants the chip-top bench drives
rtl/analog/agriasic_afe_top.sv      the analog team's behavioural model (2026-11-20)
rtl/analog/sh_adc_behavioral.sv     its shared S/H, mux and comparator
lib/agriasic_afe_top.lib            template Liberty       <- replace on handoff
```

## The model (2026-11-20 analog handoff)

`agriasic_afe_top.sv` and `sh_adc_behavioral.sv` are the analog team's
full-chain functional model, copied unedited (sha256 `6052425e3135…` and
`27181a6686896340…`). `agriasic_afe_top` is a thin wrapper with this
repository's 19-port boundary around `agriasic_afe_integrated_model`, which
models:

- **Excitation:** sine code to E1 through a first-order buffer, ±0.45 V
  about VCM with a 2 ns time constant. Both are placeholders (GAP-A5).
- **Voltage path:** E2−E3 times **4.81** with one pole (2.39 ns), clipped
  0.1 V inside the rails.
- **Current path:** E4 current (amperes) times the selected transimpedance,
  with two equal poles. Codes `001`/`010`/`100`/`111` give **1637 / 12236 /
  204999 / 1446 Ω**; any other code gives zero gain.
- **Both paths are non-inverting.** The previous model's TIA inverted; this
  one follows the analog team's fitted two-stage path, so a current flowing
  into E4 raises the converter input.
- **S/H and converter:** both hold cells freeze on `afe_sample_i` rising and
  release together 18.25 ns after the current channel's `afe_conv_start_i`
  (or 50 ns after `afe_adc_enable_i` falls). The selected input is captured
  10 ns after `afe_conv_start_i`, and the comparator answers 6.25 ns after
  the capture or a trial-code change: 1 = input ≥ VREFL + code × LSB.
  Channel 2 reads `vin_t_i` directly.

The gains and poles are a 10 MHz typical-corner fit to the analog team's
earlier "gain36" compensation experiment, **not** the r59 macro and not a
broadband characterisation. They are module parameters, so a newer fit
replaces numbers, not structure.

**What it does not model:** S/H acquisition bandwidth, droop or kickback
(it tracks ideally, so GAP-A2 cannot show up), the finite-rail hold
disturbance, noise, mismatch, supply effects, and a reconstruction filter
on the excitation. It checks its supplies, bias, VCM and references against
nominal at time zero, and stops on anything but the 1.4 V / 0.4 V reference
pair (or 1.15 V / 0.65 V with `PHYSICAL_REFERENCES=1`).

The previous model carried live checks for the open GAP items (S/H released
before the converter captured, mux change mid-conversion, strobe while
holding, open TIA, bias out of range). This one does not.
`tb/tb_agriasic_asic_top.sv` re-checks the parts that matter at chip level
against the model's own sampler, plus an end-to-end impedance check; the
mux-stability property lives in `tb/smoke/tb_agriasic_digital_top.sv`.

## Selecting a view

| Build | Define | Sources | `agriasic_afe_top` resolves to |
|---|---|---|---|
| Simulation | `AGRIASIC_AFE_BEHAVIORAL` | include `rtl/analog/*.sv` | the model in this directory |
| Synthesis / STA | *(none)* | **omit** `rtl/analog/` | the `.lib` cell, as a blackbox |

The define does exactly one thing beyond selecting sources: it switches
`agriasic_asic_top`'s analog ports between `real` (behavioural) and `wire`
(synthesis). That is the only `ifdef` in the wrapper, and a `real` port is
not synthesisable, which is why it cannot be avoided.

Synthesis setup:

```tcl
read_lib lib/agriasic_afe_top.lib        ;# lc_shell, then write_lib -format db
# do NOT analyze rtl/analog/*.sv
set_dont_touch [get_cells u_afe]
```

**The digital synthesis target is still `agriasic_digital_rv32i_top`**, where
the AFE is not instantiated at all and `afe_adc_comp_i` is an ordinary input
constrained by `set_input_delay`. The library is only needed if you
synthesise or run STA on `agriasic_asic_top`.

## Checking the model

```bash
bash tb/rv32i_regression/lint_asic_top.sh    # chip top: digital + AFE
bash tb/rv32i_regression/lint_top.sh         # digital synthesis target, unchanged
```

The model needs `--timing`: the AFE boundary carries no clock, so the
continuous-time blocks advance on `#` delays.

## Two simulator traps, both already hit

1. A comment line whose first word after `//` is the simulator's name parses
   as a lint directive and fails the build. Reword such comments.
2. **A `real` expression that is a pure function of a narrow logic vector is
   folded into a lookup table over the whole input domain — and that table is
   emitted with an integer type**, so the build dies in hundreds of
   narrowing-conversion errors. This bit three times while building the
   model: a `case` selecting between real gain constants, the sine DAC's
   8-bit code-to-voltage map (256 entries), and the CDAC's trial-voltage map.

   Two shapes avoid it. The previous model used both deliberately, and the
   handoff model's stepped `initial forever` loop is the second:
   - selects between real constants are written as `if`/`else` chains, not a
     `case`;
   - code-to-voltage conversions are evaluated **inside a stepped `always`
     process**, not in `always_comb` or a continuous `assign`, so there is no
     combinational function over the input domain left to fold.

   Do not "simplify" either back. The failure is at C++ compile time with no
   reference to the offending line of Verilog, so it is expensive to
   rediscover.

## What the chip-top bench checks with it

`bash tb/rv32i_regression/asic_top.sh` runs firmware, digital and this model
against a tetrapolar electrode load, then checks that every SAR code equals
the code the model's comparator input implies, that the held voltage and
current survive until they are converted, that nothing clips, and that the
impedance the chip reports from its own I/Q results matches the load's
inner soil segment at 10 MHz, 1 MHz and 312.5 kHz.

## On handoff

Ask for **four** things, not one: `.lib` (synthesis/STA), LEF (place and
route), GDS, and a **Verilog functional view** (simulation). A `.lib` alone
cannot be simulated. If no functional view is available, the model here stays
as the permanent stand-in — which is why its port list is written to be the
specification the delivered macro must meet.

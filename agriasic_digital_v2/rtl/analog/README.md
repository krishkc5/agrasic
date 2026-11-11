# Analog front end — two views of one macro

The AFE is **one hard macro**, `agriasic_afe_top`. Everything in this
directory is its *behavioural view*, used for simulation only. Synthesis
never reads a file from here.

```
rtl/analog/agriasic_afe_pkg.sv    electrical constants (LSB, references, gains)
rtl/analog/agriasic_afe_top.sv    the behavioural model  <- delete on handoff
lib/agriasic_afe_top.lib          template Liberty       <- replace on handoff
```

The `afe_beh_*` modules inside `agriasic_afe_top.sv` are model scaffolding,
not a claim about how the real macro is built. They are named so they cannot
be confused with, or collide with, the analog team's cell names.

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

   Two shapes avoid it, both used here deliberately:
   - selects between real constants are written as `if`/`else` chains, not a
     `case`;
   - code-to-voltage conversions are evaluated **inside a stepped `always`
     process**, not in `always_comb` or a continuous `assign`, so there is no
     combinational function over the input domain left to fold.

   Do not "simplify" either back. The failure is at C++ compile time with no
   reference to the offending line of Verilog, so it is expensive to
   rediscover.

## What the model is for

Running the chip top end to end is the lesser half. The real purpose is that
the unwritten parts of the analog/digital boundary fail loudly instead of
silently: the model carries live checks for every open item, and
`docs/analog_integration_gaps.md` explains each one. The first of them,
GAP-A6, already produces a number — an 18 LSB sampling error under one of the
two readings of `afe_sample_o`.

## On handoff

Ask for **four** things, not one: `.lib` (synthesis/STA), LEF (place and
route), GDS, and a **Verilog functional view** (simulation). A `.lib` alone
cannot be simulated. If no functional view is available, the model here stays
as the permanent stand-in — which is why its port list is written to be the
specification the delivered macro must meet.

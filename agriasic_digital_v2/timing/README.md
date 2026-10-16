# Timing

## What is here, and what is not

| | |
|---|---|
| `agriasic_digital_rv32i_top.sdc` | Constraints. Library-independent and complete as far as the RTL determines them. |
| `path_depth.py` | Structural critical-path analysis — longest combinational depth between registers. |
| **Not here** | **Signoff STA.** |

There is no Liberty library and no STA tool in this tree, and TSMC 180 nm
timing models need PDK access. So nothing here tells you whether the design
closes at 160 MHz. What it does is get the constraints written and identify
*which paths to look at first* when the library arrives.

## Running it

```bash
python timing/path_depth.py            # reuse the existing netlist
python timing/path_depth.py --build    # re-synthesise first (several minutes)
```

Run under **Windows Python**. The vendored wasmtime in `.tools/power-python`
ships only the win32 native library, so WSL `python3` cannot load YoWASP yosys
and fails with a confusing missing-`.so` error.

The timing netlist is built differently from the power one on purpose: memories
are **included** (they are standard-cell flop arrays, and their read mux is the
whole question), and `-noabc` is **dropped** so abc balances the logic. The
power flow needs the opposite on both counts — blackboxed memories and
un-restructured logic, so every netlist register still pairs with a VCD signal.

## What the analysis found

Two paths dominate, and **both numbers are inflated by generic mapping** — read
the ranking, not the magnitude.

**1. Ibex fetch address datapath — 125 levels.**
Endpoint `u_core.u_ibex_core.if_stage_i.gen_prefetch_buffer.prefetch_buffer_i.fetch_addr_d[31]`,
reached through a long chain of ANDs ending in an XNOR. That is a **32-bit
ripple-carry adder**: with no library, yosys maps `+` to a ripple chain. A real
flow picks the library's fast adder and this collapses. Mostly an artifact, but
worth confirming it does collapse.

**2. IMEM read path — 111 levels.** Endpoint `u_control_shell.u_imem.mem_array$rdreg`.

This is the one that matters, and it **confirms the structural concern**: with
no SRAM compiler, a 256-deep flop array needs a 256:1 32-bit read mux between
the array and the fetch data register, where an SRAM macro would have had a
specified access time. yosys built it close to linear; a real flow builds a
balanced tree at roughly 8 levels, so the 111 will shrink a lot.

**But depth is the wrong metric for this path.** The real risk is **load, not
logic levels**: the mux reads from 8,192 physically distributed flops, and that
wire capacitance and fanout is invisible to a structural analysis. Place-and-
route is where this path is decided, not synthesis.

So: check the IMEM read path first, and check it post-route, not post-synthesis.

## Constraints that are easy to get wrong

Three are worth calling out, because getting any of them wrong hides a real
failure rather than causing a visible one.

- **`gpio_spi_sclk_i` is not a clock.** `spi_slave` 2FF-oversamples it into
  `clk` and detects edges on the synchronised version; there is no second clock
  domain. The real requirement — SCK ≤ f_clk/16 — is architectural and no
  timing report will check it.
- **`afe_adc_comp_i` is not a false path.** The comparator answer is
  deliberately unsynchronised and timed by `conv_cycles_i` instead, because a
  synchroniser would cost a whole bit trial. Declaring it false removes the only
  check that the answer arrives before the trial is evaluated.
- **`rst_n` release is timed.** Assertion is asynchronous, but `rst_sync`
  releases synchronously, so recovery/removal on the synchroniser output is a
  real check. Do not blanket-false-path the reset.

## Still needed for signoff

1. **The PDK** — Liberty for the standard cells, and latch handling. STA must
   treat latches as latches with time borrowing or it will report nonsense,
   and there are now two sources of them: the Ibex register file
   (`AGRIASIC_LATCH_REGFILE`) and **the memories themselves**, which are
   latch arrays by default. `prim_clock_gating` must also map to a real ICG
   cell. If the flow cannot do either, build with `AGRIASIC_FLOP_MEM`.
2. **Real numbers for the `<<PLACEHOLDER>>` values** in the SDC: clock
   uncertainty and transition from the PDK, flash MISO timing from the chosen
   part's datasheet, and the comparator delay from analog (GAP-2).
3. **Post-route check of the IMEM read path**, per above.
4. **A DFT decision.** `test_en_i` and both `testmode_i` inputs are tied to
   `1'b0` and there is no scan chain anywhere. If scan is added the clock
   structure changes and these constraints need a test mode.

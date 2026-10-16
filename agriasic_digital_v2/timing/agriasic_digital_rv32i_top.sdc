# =============================================================================
# AgriASIC digital top -- timing constraints
#
# Target: agriasic_digital_rv32i_top, TSMC 180 nm, 160 MHz.
#
# These constraints are library-independent and complete as far as the RTL
# determines them. Numbers marked <<PLACEHOLDER>> depend on the PDK or on
# analog characterisation and MUST be replaced before signoff -- they are
# deliberately pessimistic guesses, not measurements.
#
# Read timing/README.md first. In particular: `gpio_spi_sclk_i` is NOT a clock,
# and `afe_adc_comp_i` is NOT a false path. Both are easy to get wrong and both
# are wrong in a way that hides a real failure.
# =============================================================================

set CLK_PERIOD   6.25   ;# 160 MHz
set TCK_PERIOD 100.00   ;# 10 MHz JTAG; the DTM crosses TCK->clk with a 2-phase
                        ;# handshake, so this only has to be well under CLK.

# -----------------------------------------------------------------------------
# 1. Clocks
# -----------------------------------------------------------------------------
create_clock -name clk      -period $CLK_PERIOD [get_ports clk]
create_clock -name jtag_tck -period $TCK_PERIOD [get_ports gpio_jtag_tck_i]

# The flash SCK is generated on die by the boot loader's divider (clk/16 during
# boot, firmware-selectable afterwards). Constrain it as a generated clock so
# the MOSI/CS_N launch and MISO capture are timed against the edge the chip
# actually produces.
create_generated_clock -name flash_sck \
    -source [get_ports clk] -divide_by 16 [get_ports gpio_flash_sck_o]

# clk and TCK are genuinely asynchronous. The DTM owns the crossing.
set_clock_groups -asynchronous -group {clk flash_sck} -group {jtag_tck}

# <<PLACEHOLDER>> replace with PDK numbers once the library is available.
set_clock_uncertainty 0.25 [all_clocks]
set_clock_transition  0.15 [all_clocks]

# -----------------------------------------------------------------------------
# 2. Reset
#
# rst_n is asynchronously asserted and synchronously released by rst_sync, so
# the assertion path is not timed but the RELEASE is -- recovery/removal on the
# synchroniser output is a real check. Do not blanket-false-path the reset.
# -----------------------------------------------------------------------------
set_input_delay -clock clk 1.0 [get_ports rst_n]
set_false_path -fall_from [get_ports rst_n]   ;# assertion only; release is timed

# -----------------------------------------------------------------------------
# 3. Host SPI port -- OVERSAMPLED, NOT A CLOCK
#
# spi_slave 2FF-synchronises SCK, CS_N and MOSI into clk and detects edges on
# the synchronised versions. There is no second clock domain. Defining
# gpio_spi_sclk_i as a clock would both be wrong and hide the real constraint,
# which is simply that these are slow asynchronous inputs.
#
# The load-bearing requirement is architectural, not an SDC check:
#   max SCK <= f_clk / 16.
# A host that violates it loses bytes; no timing report will tell you.
# -----------------------------------------------------------------------------
set SPI_IN [get_ports {gpio_spi_sclk_i gpio_spi_cs_n_i gpio_spi_mosi_i}]
set_input_delay -clock clk 1.0 $SPI_IN
set_max_delay   $CLK_PERIOD -from $SPI_IN
set_output_delay -clock clk 1.0 [get_ports {gpio_spi_miso_o gpio_spi_miso_oe_o}]

# -----------------------------------------------------------------------------
# 4. External SPI flash (chip is master)
# -----------------------------------------------------------------------------
set_output_delay -clock flash_sck 2.0 \
    [get_ports {gpio_flash_mosi_o gpio_flash_cs_n_o}]
# <<PLACEHOLDER>> MISO capture depends on the chosen flash part's t_V plus
# board delay. 10 ns is a generic SPI NOR figure; confirm against the datasheet.
set_input_delay -clock flash_sck -max 10.0 [get_ports gpio_flash_miso_i]
set_input_delay -clock flash_sck -min  0.0 [get_ports gpio_flash_miso_i]

# -----------------------------------------------------------------------------
# 5. JTAG
#
# TDI/TMS are captured on rising TCK, TDO is launched on falling TCK.
# -----------------------------------------------------------------------------
set_input_delay  -clock jtag_tck 10.0 [get_ports {gpio_jtag_tdi_i gpio_jtag_tms_i}]
set_output_delay -clock jtag_tck -clock_fall 10.0 [get_ports gpio_jtag_tdo_o]
# TRST_N is an asynchronous TAP reset, independent of rst_n by design.
set_false_path -from [get_ports gpio_jtag_trst_ni]

# -----------------------------------------------------------------------------
# 6. Straps and slow status pins
#
# gpio_boot_sel_i is a STRAP: sampled on the first cycle out of reset and then
# ignored. It is still timed into its sampling flop -- a false path here would
# hide a genuine setup failure on the one cycle that matters.
# -----------------------------------------------------------------------------
set_input_delay  -clock clk 1.0 [get_ports {gpio_boot_sel_i gpio_start_i}]
set_output_delay -clock clk 1.0 [get_ports gpio_boot_fail_o]

# -----------------------------------------------------------------------------
# 7. Analog front end -- the paths that actually matter
#
# afe_adc_comp_i is the comparator answer coming back. It is DELIBERATELY
# UNSYNCHRONISED: sar_controller times it with conv_cycles_i rather than adding
# a synchroniser, because a synchroniser would cost a full bit-trial of latency.
#
# That makes it a real, timed path -- NOT a false path. Declaring it false is
# the single most tempting mistake in this file and would silently remove the
# only check that the comparator answer arrives before the trial is evaluated.
# -----------------------------------------------------------------------------
# <<PLACEHOLDER>> comparator regeneration + routing. GAP-2: analog has not yet
# characterised this. The value below assumes the answer lands within one core
# cycle at conv_cycles_i = 1; raise conv_cycles_i if it does not.
set_input_delay -clock clk -max 4.0 [get_ports afe_adc_comp_i]
set_input_delay -clock clk -min 0.5 [get_ports afe_adc_comp_i]

# Outputs to the AFE. The budgets come from the sequencer, not the PDK:
#   afe_adc_dac_o   must settle within one bit trial = 25 ns at conv_cycles=1
#   afe_sine_code_o updates at 16 x f_exc -- every clock at the 10 MHz point
#   afe_mux_sel_o   is held for a whole conversion (~212 ns)
#   afe_sample_o    one strobe per phase point, freezes BOTH channels
set_output_delay -clock clk 2.0 [get_ports {afe_sine_code_o[*] afe_adc_dac_o[*]}]
set_output_delay -clock clk 2.0 [get_ports {afe_adc_enable_o afe_sample_o afe_conv_start_o}]
set_output_delay -clock clk 2.0 [get_ports {afe_mux_sel_o[*]}]
# Gain switch wires are quasi-static: written by firmware, then held for an
# entire measurement. Relaxed, but not false -- they still have to settle.
set_multicycle_path -setup 4 -to [get_ports {afe_pga_gain_o[*] afe_tia_rf_o[*]}]
set_multicycle_path -hold  3 -to [get_ports {afe_pga_gain_o[*] afe_tia_rf_o[*]}]
set_output_delay -clock clk 2.0 [get_ports {afe_pga_gain_o[*] afe_tia_rf_o[*]}]

# -----------------------------------------------------------------------------
# 8. Debug-visibility ports -- NOT BONDED
#
# Every dbg_* port exists so simulation, the power flow and the memory audit can
# observe internal state without hierarchical references. None of them is a pad.
# Constraining them would waste optimisation effort on paths that do not exist
# in silicon; the pad ring must not bond them.
# -----------------------------------------------------------------------------
set_false_path -to [get_ports dbg_*]

# -----------------------------------------------------------------------------
# 9. Design-specific notes for whoever runs signoff
#
# a. LATCH REGISTER FILE. The ASIC build defines AGRIASIC_LATCH_REGFILE, which
#    selects lowRISC's latch-based register file. STA must be told these are
#    latches and allowed to time-borrow, or it will report nonsense. If your
#    flow cannot handle it, build with the flop register file and accept the
#    area (992 extra flop bits).
#
# b. MEMORY READ MUX IS IN THE FETCH PATH. There is no SRAM compiler, so IMEM
#    and DMEM are standard-cell flop arrays. A 256-deep array means a 256:1
#    32-bit read mux between the array and the fetch data register, where a
#    macro would have had a specified access time. See timing/path_depth.py for
#    the structural measurement. This is the expected critical path; check it
#    first, not last.
#
# c. NO SCAN. test_en_i and both testmode_i inputs are tied to 1'b0 and there is
#    no scan chain anywhere. If DFT is added later these constraints need a test
#    mode and the clock structure will change.
#
# d. CLOCK GATING. Ibex gates its own core clock while idle (that is how the wfi
#    sleep saves power). Integrated clock gating cells need their enable timed;
#    do not let the flow convert them to ordinary muxes without checking.
# =============================================================================

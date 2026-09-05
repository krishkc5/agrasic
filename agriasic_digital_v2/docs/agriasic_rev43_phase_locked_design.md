# Single-Die Impedance Sensing Node

## High-Level Design Document, Revision 4.3: Phase-Locked Measurement Engine

| | |
|---|---|
| **Project** | Low-power agricultural impedance sensing (senior design) |
| **Team** | Krishna Chemudupati (analog front end), Vidhu Bulumulla (SAR ADC), Taarana Jammula (digital, integration) |
| **Process** | TSMC 180nm MS/RF-G, Muse shared block |
| **RTL** | github.com/krishkc5/agrasic, `agriasic_digital_v2` |
| **Trial GDS** | November 18, 2026 |
| **Supersedes** | Revision 4.2, September 2026 |

Revision 4.3 is driven by review of the existing RTL. Two things change at the architecture level. First, the measurement FSM is promoted from descope fallback to a permanent block that runs in parallel with the core, because the inner measurement loop has a hard real-time requirement no processor can meet. Second, the control relationship between the excitation generator and the measurement engine inverts: excitation becomes free-running and the sampler locks to its phase, rather than the FSM causing each polarity flip.

| Item | Rev 4.2 | Rev 4.3 |
|---|---|---|
| Measurement FSM | Descope fallback for the core | Permanent block. Owns all cycle-accurate timing, runs concurrently with the core |
| Excitation control | FSM commands each polarity change | Free-running phase generator; FSM slaves sample strobes to its phase |
| Phase command | Level-driven | Edge-triggered pulse with a settle-complete handshake |
| Accumulation | Per-pair halving before summing | Raw difference summed; all scaling on the host |
| Clock domains | Unspecified | Single domain; core runs on a clock enable, not a gated clock |
| Result readout | Two fixed result registers | Indexed readout port, auto-incrementing |

---

## 1. Sensing method, in brief

Soil impedance has two contributions with opposite frequency behaviour. Ionic conduction, which tracks dissolved nutrient and salt content, carries a `1/w` factor and fades as frequency rises. Dielectric polarization, dominated by water, does not. Measuring at widely separated frequencies is therefore what separates moisture from nutrients.

```
eps*(w)  =  eps'(w)  -  j [ eps"_relax(w)  +  sigma_dc / (w · eps_0) ]
                            water                     ions
```

The chip sweeps three points, roughly 1 kHz, 100 kHz and 10 MHz, and at each point samples four phase offsets to recover in-phase and quadrature components:

```
I  =  ( D(0deg)  -  D(180deg) ) / 2          Q  =  ( D(90deg)  -  D(270deg) ) / 2
```

Opposite-phase subtraction cancels static TIA and ADC offset, because offset does not reverse when excitation does. `I` tracks conduction, `Q` tracks the reactive term. Magnitude, phase and calibration are computed on the host. The full derivation, frequency-selection rationale and source citations are in Revision 4.2 sections 1.1 through 1.3 and are not repeated here.

---

## 2. Control partition

The measurement contains two loops with radically different timing requirements. Trying to serve both from one controller is what forces the partition.

| Loop | Cadence | Work per iteration | Determinism |
|---|---|---|---|
| Inner | 100 ns at 10 MHz excitation | Strobe track-and-hold at the commanded phase, run 8 bit trials, add or subtract into I or Q | Hard. Strobe jitter becomes phase error becomes measurement error |
| Outer | 10 to 100 ms | Load divider ratio, set M, wait settle, read temperature, pack results, service SPI | Soft. A few microseconds of variation is irrelevant |

A compact RISC-V core cannot service a 100 ns event, and no software path gives jitter-free strobe timing. The inner loop is therefore hardware regardless of whether a core is present. The FSM is the measurement engine; the core configures it and interprets its output.

| Owner | Responsibility |
|---|---|
| **Measurement FSM** | Divider load, phase counter, sample strobe generation, ADC start and busy handshake, sign selection per phase index, both accumulators, cycle counter against M, done flag |
| **RV32I core** | Sweep program, settle intervals, M and frequency selection, temperature read, result packing, SPI register servicing, error and reset policy |
| **Neither, host does it** | Magnitude, phase, calibration, moisture and conductivity mapping |

> **Boundary to defend:** the FSM never gets a program counter. If it needs branching beyond "repeat M times", it has become a second processor and the schedule cannot absorb verifying two of them.
>
> **Power benefit:** during an accumulation burst the core has nothing to do, so it is clock-enabled off and only the FSM toggles. This is a direct improvement to energy per measurement.

---

## 3. Inverted excitation control

In the current RTL the FSM causes each polarity flip: it commands a phase, waits for a settle qualification, requests a sample, then commands the opposite phase. Excitation frequency is therefore an emergent side effect of the settle and conversion register values rather than a programmed quantity.

That cannot support Rev 4.2 measurement. Equivalent-time sampling assumes a *stationary periodic stimulus*: the excitation runs continuously at a known frequency, and the sampler takes one phase point per cycle, assembling the picture over many cycles. Rev 4.3 therefore inverts the relationship.

| Aspect | Current RTL | Rev 4.3 |
|---|---|---|
| Who sets excitation timing | Measurement FSM, per flip | Free-running divider from the master clock |
| Excitation frequency | Emergent from settle and conv values | `f_exc = f_clk / (16 · N)`, N programmed |
| What the FSM does | Drives polarity | Selects a phase index and strobes the sampler when the phase counter matches |
| Phase resolution | Two phases, 0 and 180 degrees | 16 counter states, four used per measurement |
| Settle handling | Level-held command reloads the counter every cycle | Edge-triggered pulse, counter runs to zero, handshake back to the FSM |

Phase steps fall out of the divider counter, so no delay line or DLL is required. For 10 MHz excitation with 16 phase steps, `f_clk` is 160 MHz. If the pad, clock buffer and sampling logic do not close timing at 160 MHz in this process, drop to 8 phase steps at 80 MHz, which still supports I and Q at 45 degree resolution.

---

## 4. Architecture

```
  EXTERNAL                            ASIC DIE
  --------                            --------

  160 MHz clock ------------->  [ Excitation generator ]
  V_EXC, VREFH, VREFL, VCM        free-running divider
                                      |            |
                                      | drive      | phase
                                      v            v
  [ soil electrodes ] <---------------+     [ Measurement FSM  ]
          |                                  phase strobe, SAR ctrl
          | return current                        |
          v                                       | strobe / code
  [ Wideband TIA ] --> [ 8-bit SAR ADC ] ---------+
    10 MHz, I to V       fast-aperture T/H        |
                               ^                  v
  [ Temp sense (PTAT) ] -------+           [ I/Q accumulators ]
                                            4-phase differencing
                                                  |
                                                  v
                                           [ RV32I core + ROM ]
                                             sweep policy
                                                  |
                                                  v
  host <----------------------------------- [ SPI slave + regfile ]
```

The excitation generator now exports a phase reference to the FSM, which is the key structural change from Rev 4.2. Core-to-FSM configuration writes and FSM-to-core status reads run through the register block and are omitted above for clarity.

The excitation generator divides the master clock and drives the electrodes continuously at the programmed frequency, exporting its phase counter to the measurement FSM. Return current enters the TIA and is converted to a voltage. The FSM strobes the ADC when the phase counter reaches the selected index, runs the eight bit trials, and adds the result into the I or Q accumulator with the sign that phase requires. The core steps through phase indices, cycle counts and frequency points, reads the PTAT sensor through the ADC test mux during frequency-change settling, and reports over SPI.

---

## 5. Components

| Block | Function and change from Rev 4.2 | Owner | Delta | Status |
|---|---|---|---|---|
| Excitation generator | Restructured to free-running. Divider produces three selectable frequencies and a 16-state phase counter exported to the FSM. Phase command becomes edge-triggered with a settle handshake. | Krishna, Taarana | 0.8 wk | Rework |
| Wideband TIA | 10 MHz closed loop, R_F near 10 kOhm, C_F near 0.5 pF. Stability across electrode and pad capacitance at the new pole. | Krishna | 1 to 2 wk | Unchanged |
| SAR ADC | Track-and-hold aperture near 5 ns with low jitter. Conversion time unconstrained. Test mux also carries PTAT output. | Vidhu | 1.0 wk | Unchanged |
| Temp sense | PTAT through the ADC test mux, read during frequency-change settling so it costs no additional active time. | Vidhu | 0.5 wk | Unchanged |
| **Measurement FSM** | **Promoted to permanent block.** Phase-index compare and strobe, SAR handshake, sign selection, cycle counting. Absorbs the existing `sar_controller` handshake. | Taarana | 0.6 wk | Rework |
| I/Q accumulators | Two signed 16-bit accumulators with shadow registers, snapshot on done. Raw differences, no per-pair scaling. | Taarana | 0.5 wk | New |
| Core and program | Sweep policy only. Clock-enabled off during accumulation bursts. | Taarana | 0.4 wk | Exists |
| SPI and regfile | Indexed result readout, frequency and phase control, error policy. | Taarana | 0.3 wk | Rework |

---

## 6. Register map

The SPI command byte allocates `bit[6:3]` to the register address, giving 16 registers. Six 16-bit accumulators plus temperature is roughly 13 result bytes, which will not fit alongside control as fixed registers. Rev 4.3 uses an indexed readout port instead, so the protocol is unchanged and a burst read is a sequence of two-byte transactions.

| Addr | Name | Access | Purpose |
|---|---|---|---|
| 0x0 | REG_CTRL | RW | Start pulse, error clear, core enable |
| 0x1 | REG_PAIR_LOG2 | RW | M = 2^value. Constrain to 6 or less, see accumulator width below |
| 0x2 | REG_SETTLE | RW | Settle cycles after a frequency or phase change |
| 0x3 | REG_FREQ_SEL | RW | Divider ratio N selecting the excitation frequency point |
| 0x4 | REG_PHASE_IDX | RW | Phase index into the 16-state counter |
| 0x5 | REG_CONV | RW | SAR conversion cycles |
| 0x6 | REG_STATUS | RO | Busy, done, overrange, sticky protocol errors |
| **0x7** | **REG_RESULT_IDX** | RW | Pointer into the result set, auto-increments on each data read |
| **0x8** | **REG_RESULT_DATA** | RO | Byte at the current index. Result set: I and Q low and high bytes for three frequency points, then temperature |
| 0x9 | REG_ID | RO | Design and revision identifier |

Existing response codes are retained: 0xA5 write accepted, 0x5A write rejected, 0xE1 invalid command, 0xE2 invalid address. The wrapper continues to consume and discard the data byte of an illegal command to keep framing aligned.

---

## 7. Contracts to freeze

```
f_exc  =  f_clk / (16 · N)          phase step  =  22.5 degrees
f_clk  =  160 MHz for 10 MHz excitation with 16 phase steps
```

- **Single clock domain.** The FSM and the core share the 160 MHz clock. The core receives a clock enable asserting one cycle in N rather than a gated clock, so there is no domain crossing, no synchronizers, and STA sees one synchronous domain with declared multicycle paths on the core. If the flow will not close 160 MHz on the accumulate path, keep only the phase counter and strobe at full rate and clock-enable the accumulate logic every fourth cycle. Still one domain.
- **Sampling aperture.** Under 5 ns, with jitter small enough to hold phase error below one degree at 10 MHz.
- **Accumulator width.** 16-bit signed. Worst case at M = 64 is 64 x 255 = 16,320, inside the 32,767 limit. At M = 128 the worst case is 32,640, which is inside the limit but without margin, so constrain M to 64 or widen to 18 bits.
- **Phase command handshake.** Edge-triggered. The excitation block must reload its settle counter only on a rising edge of the command, and must assert settle-complete no more than one settle interval later. Assert this in RTL.
- **Accumulator snapshot.** The FSM writes accumulators into shadow registers only at completion, so the core can never read a partial sum. A start written while busy is ignored and sets an error bit rather than restarting mid-burst.

---

## 8. RTL status and required fixes

The repository already implements the measurement path, the RV32I control shell, MMIO, firmware and a regression suite. The policy-versus-mechanism partition described in section 2 is already present in the control shell, and the port list is identical between the microsequencer and RV32I shells, so the descope path is a file swap. The memory wrappers present a real single-port synchronous macro contract with an `AGRIASIC_USE_SRAM_MACRO` swap hook that fails elaboration loudly rather than silently.

Three defects in the current measurement path must be fixed before the Rev 4.3 restructure, since the restructure will otherwise inherit them. All three were reproduced in simulation.

> **D1. Settle interval is never applied.** `measurement_fsm` holds `exc_set_phase_o` for the whole settle state, and `excitation_ctrl` reloads on the level. Because `settled_o` is registered, the FSM reads the stale value of 1 on entry and leaves before the countdown begins. Measured: settle = 0 and settle = 2 both complete in 50 cycles with identical results. The ADC is sampling into the excitation transient.

> **D2. Deadlock above a settle threshold, and the threshold moves.** If the countdown does not finish before the next settle state is entered, the held command pins `settled_o` low permanently. Measured: settle = 20 with conv = 1 hangs; settle = 20 with conv = 40 completes. Two independently programmable registers jointly determine whether the chip hangs. Current tests and firmware use settle = 2, inside the safe window. Every settle value Rev 4.3 actually needs at 1 kHz excitation is in the hang region.

> **D3. Per-pair halving destroys averaging and reintroduces an offset.** `pair_delta` applies an arithmetic right shift to each pair before accumulation. This discards the sub-LSB resolution the dynamic range budget depends on, and because arithmetic shift rounds toward negative infinity the error is sign-dependent. Measured at M = 8: a difference of +1 accumulates to 0 against an ideal of +4, and a difference of -1 accumulates to -8 against an ideal of -4. A signal-dependent DC offset is exactly what the polarity chop exists to cancel.

**Fixes.** D1 and D2 share one: make the phase command edge-triggered in `excitation_ctrl`, and split the settle state into a one-cycle command state followed by a wait state. D3: accumulate the raw difference with sign extension and move all scaling to the host.

### 8.1 Verification additions

- Sweep `settle` against `conv` across the full 8-bit range with a completion timeout on every combination. Either D1 or D2 would have been caught by this.
- Check `result == M x (D+ - D-)` for odd differences, plus or minus 1 differences, and saturating differences.
- Assert that settle-complete falls within one settle interval of a phase command.
- Assert that the accumulator shadow register never updates while busy is high.
- Assert that a strobe is issued only when the phase counter equals the selected index.

---

## 9. Effort and descope

Rev 4.3 adds roughly 1.5 to 2 FTE-weeks over Rev 4.2, most of it the excitation restructure and the defect fixes. The FSM promotion itself is nearly free because the block already exists; what is new is the handshake discipline and the cross product of core and FSM states in verification.

> **The descope path improves under this revision.** Because the FSM now owns all measurement behaviour, dropping the core at the Week 4 gate changes nothing about what the chip measures. It only removes the ability to change the sweep program after tapeout. That is a far cheaper cut than it was in Rev 4.1, and it should be presented as the planned contingency rather than a failure mode.

Descope order, applied only as far as needed: drop the 32 MHz stretch point; reduce phase steps from 16 to 8, halving the required clock to 80 MHz; replace the core with a fixed FSM program; reduce the sweep from three frequency points to two, keeping the widest separation. Retain in all cases: two frequency points, I and Q accumulation, the TIA, 8-bit conversion, temperature sense, reset safety, and a readable result vector over SPI.

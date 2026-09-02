# AgriASIC Digital Timing and Waveform Checklist

## Scope
This checklist defines cycle-level timing expectations for the current digital RTL implementation.

## Key Configuration Registers
- REG_PAIR_LOG2 (0x1): number of pairs is 2^pair_log2
- REG_SETTLE (0x2): settle ticks per phase
- REG_DIVIDER (0x3): excitation tick divider (0 means tick every clk)
- REG_CONV (0x4): conversion latency in cycles

## Measurement Sequencer Timeline
1. `start` pulse accepted in S_IDLE.
2. Enter S_SETTLE_P:
- `exc_enable_o=1`
- `exc_set_phase_o=1`, `exc_phase_o=1`
- wait until `settled_i=1`
3. Enter S_SAMPLE_P:
- `sample_req_o=1`, `sample_phase_o=1`
- wait for `sar_done_i=1`
4. Enter S_SETTLE_N:
- `exc_set_phase_o=1`, `exc_phase_o=0`
- wait until `settled_i=1`
5. Enter S_SAMPLE_N:
- `sample_req_o=1`, `sample_phase_o=0`
- wait for `sar_done_i=1`
6. Enter S_ACCUM:
- `acc += (D+ - D-) / 2`
- `pair_count++`
7. Enter S_LOOP:
- if `pair_count >= pair_target`: go S_DONE
- else go S_SETTLE_P
8. In S_DONE:
- `done_o=1`
- stay until `start_i` is deasserted

## Excitation Controller Timing
1. When `enable_i=0`:
- `polarity_o=0`
- `settled_o=1`
2. On `set_phase_i=1`:
- `polarity_o` updates to `phase_value_i`
- `settled_o` clears unless `settle_cycles_i==0`
- settle counter loads from `settle_cycles_i`
3. On each `tick_o` while unsettled:
- settle counter decrements
- `settled_o` asserts when counter reaches zero

## SAR Controller Timing
1. On `sample_req_i` when `busy_o=0`:
- latch `sample_phase_i`
- load conversion counter from `conv_cycles_i`
- pulse `conv_start_o` for one cycle
2. While busy:
- conversion counter decrements each cycle
3. On conversion counter expiration:
- capture `adc_code_i` into D+ or D- by phase
- pulse `sample_done_o`
- clear `busy_o`

## SPI Wrapper Timing
1. SPI command byte format:
- bit[7]=RW, bit[6:3]=address, bit[2:0]=0
2. Write:
- Byte0 command (RW=0)
- Byte1 payload data
 - Wrapper prepares `0xA5` ACK on success or `0x5A` NACK on rejected write
3. Read:
- Byte0 command (RW=1)
- Byte1 dummy clocks out selected register byte on MISO
 - Invalid read command returns `0xE1` (bad command) or `0xE2` (bad address)
4. Framing:
- Transactions are fixed at 2 bytes.
- If Byte0 is invalid, wrapper still consumes Byte1 (discard) before accepting next command.
5. CDC:
- byte-complete toggle crosses from SCLK domain to clk domain
- `rx_valid_o` pulses one clk for each completed byte

## SPI Status Flags (REG_STATUS)
- bit[7]: protocol error (reserved bits in command were non-zero)
- bit[6]: illegal address access attempt
- bit[5]: illegal write to read-only register
- bit[1]: done
- bit[0]: busy

Sticky error flags clear when writing CTRL with bit[7]=1.

## Waveform Checks
1. `conv_start_o` pulses once per sample request.
2. D+ updates only on positive-phase sample completion.
3. D- updates only on negative-phase sample completion.
4. `busy_o` remains high from first settle state through loop completion.
5. `done_o` asserts after final accumulation.
6. Result bytes at REG_RESULT_HI/LO match `result_o`.
7. STATUS bit[1] mirrors `done_o`, bit[0] mirrors `busy_o`.
8. Invalid command/address/write set corresponding sticky status bits.
9. CTRL bit[7] write clears sticky status error bits [7:5].

## Pass Criteria
- All waveform checks above pass at at least two settings:
  - quick profile: pair_log2=1, settle=0, conv=0
  - nominal profile: pair_log2=2, settle=2, conv=1
- SPI readback of status/result is consistent with direct top-level outputs.

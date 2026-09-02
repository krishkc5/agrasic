# AgriASIC Digital Interface Contract

## Clock and Reset
- `clk`: digital core clock
- `rst_n`: active-low asynchronous reset

## Measurement control
- `start`: one-cycle pulse to start one measurement burst
- `busy`: high while the FSM/controller is executing the burst
- `done`: pulse/high to indicate result update

## ADC handshake
- `conv_start`: conversion trigger toward SAR analog domain
- `adc_code_i[7:0]`: sampled conversion code returned to digital domain

## Excitation control
- `exc_pol_o`: excitation polarity control exported to analog driver
- Settle and divider controls will be mapped through register space

## SPI protocol (implemented)
- Mode: SPI mode-0 (`CPOL=0`, `CPHA=0`)
- Command byte format:
	- `bit[7]`: `1=READ`, `0=WRITE`
	- `bit[6:3]`: 4-bit register address
	- `bit[2:0]`: reserved, must be `3'b000`
- Every transaction is 2 bytes (`Byte0=command`, `Byte1=data/dummy`)
- If `Byte0` is illegal (reserved bits or bad address), the wrapper consumes `Byte1` and discards it to keep framing aligned.

## SPI response codes (implemented)
- `0xA5`: write accepted (ACK)
- `0x5A`: write rejected (NACK, e.g. write to read-only register)
- `0xE1`: invalid command (`cmd[2:0] != 0`)
- `0xE2`: invalid register address

## Register map (implemented)
- `0x0` `REG_CTRL` (RW):
	- bit[0] write-one pulse to start measurement
	- bit[7] write-one clears sticky protocol error bits in `REG_STATUS[7:5]`
- `0x1` `REG_PAIR_LOG2` (RW): pair count as log2 (`M = 2^REG_PAIR_LOG2`)
- `0x2` `REG_SETTLE` (RW): settle cycles between phase update and sampling
- `0x3` `REG_DIVIDER` (RW): excitation divider
- `0x4` `REG_CONV` (RW): SAR conversion cycles
- `0x5` `REG_STATUS` (RO):
	- bit[7] sticky protocol error
	- bit[6] sticky bad address
	- bit[5] sticky illegal write to RO register
	- bit[1] done
	- bit[0] busy
- `0x6` `REG_RESULT_LO` (RO): result low byte
- `0x7` `REG_RESULT_HI` (RO): result high byte

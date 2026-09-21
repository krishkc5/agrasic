# AGRASIC firmware and physical memory requirements

The rebuilt application occupies **IMEM bytes `0x00000000–0x0000017F`**;
the exclusive end is **`0x00000180`**, so its linked address extent is **384 bytes**.
The generated [linker map](../fw/agriasic_fw.map) and
[ELF address report](../fw/agriasic_fw.memory.txt) record the highest occupied
address, not just the section sum. There are no address gaps in this particular
instruction image.

The current binary requires **2 KiB of contiguous, zero-based DMEM**, because
its stack accesses bytes through **`0x000007FF`**. Its actual data payload is
small: **48 bytes of fixed-address results + a 32-byte stack frame**, with no
heap. Counting only those 80 bytes would miss the fixed placement and gaps.

The current application needs neither 4 KiB nor 8 KiB of instruction storage.
A **512-byte IMEM** is a practical minimum for this binary; **1 KiB IMEM and
the existing 2 KiB DMEM** are a reasonable initial configuration with margin.
No memory architecture, RTL, startup address or linker layout was changed.

## Build and occupied addresses

Analyzed the newer `agrasic` repository at `b2f1309`. The representative
application is [`fw/fw.c`](../fw/fw.c#L125), which performs the three-frequency
measurement sweep; CIS 5710 ISA tests and Dhrystone are verification workloads,
not the deployed AGRASIC firmware. This subtree has one application firmware
build, startup and linker script.

The existing [`build.sh`](../fw/build.sh#L10) now always emits
`agriasic_fw.map` using `-Wl,-Map=agriasic_fw.map,--cref`, emits compiler stack
usage with `-fstack-usage`, and prints occupied-address bounds from the ELF.
The resulting 96-word HEX image is byte-for-byte unchanged. Tools were
RISC-V GCC 13.2.0 and GNU ld 2.42, with `-march=rv32im -mabi=ilp32 -Os`,
`-ffreestanding -nostdlib -nodefaultlibs` and the existing additional flags.

| Allocated section | Size | Start VMA / LMA | Highest occupied byte | Exclusive end |
|---|---:|---:|---:|---:|
| `.text`, including startup | 384 B | `0x00000000` | **`0x0000017F`** | **`0x00000180`** |
| `.rodata` / `.srodata` | 0 B | No occupied range | None | — |
| `.data` / `.sdata` | 0 B | No occupied range | None | — |
| `.bss` / `.sbss` | 0 B | No occupied range | None | — |
| Other allocated sections | 0 B | None | None | — |

The map splits `.text` into startup `0x00–0x13` (20 B), `run_sweep_point`
`0x14–0x9F` (140 B), and `main` `0xA0–0x17F` (224 B). Alignment is 4 bytes.
The empty `.data` and `.bss` map entries at `0x180` do **not** occupy that byte.

For each physical address space, the capacity criterion is:

```text
highest occupied byte = max(section address + section size - 1)
required extent       = highest occupied byte + 1 - memory origin
```

Only non-empty allocated sections count. The helper also records LMAs for
initialized sections, so future load-vs-run placement remains visible. If the
linker later describes multiple physical regions, calculate the extent for
each region separately; a global maximum across ROM, RAM and MMIO is not a
single physical memory capacity.

The ELF is 4,964 bytes on disk, but only its 384-byte `.text` is loadable.
In particular, the `PT_LOAD` **file offset and alignment of `0x1000` do not
require 4 KiB of occupied IMEM**: its VMA and physical load address are both
zero and its file/memory payload sizes are `0x180`. Symbol and string tables
are metadata. See [readelf output](results/readelf.txt) and
[objdump section headers](results/section_headers.txt).

## Current architecture and hard-coded limits

| Finding | Actual implementation and source |
|---|---|
| Instruction memory | [`agriasic_imem.sv:20`](../rtl/rv32i/agriasic_imem.sv#L20): 32-bit words, synchronous read under CE, one-cycle latency, output holds while CE is low. No write port. |
| Data memory | [`agriasic_dmem.sv:22`](../rtl/rv32i/agriasic_dmem.sv#L22): 32-bit words, one synchronous port, byte write enables, one-cycle read, output holds on writes and disabled cycles. |
| Actual IMEM depth | [`agriasic_rv32i_control_shell.sv:66`](../rtl/agriasic_rv32i_control_shell.sv#L66): 1,024 words = 4 KiB; implemented byte range `0x00000000–0x00000FFF`. |
| Actual DMEM depth | Same shell, line 67: 512 words = 2 KiB; intended byte range `0x00000000–0x000007FF`. The standalone DMEM/MMIO default is 1,024 words, overridden by the shell. |
| Reset PC | [`agriasic_rv32i_core.sv:252`](../rtl/rv32i/agriasic_rv32i_core.sv#L252): reset loads PC=0. |
| Harvard split | Shell instantiates independent IMEM and MMIO/DMEM ports at lines 149 and 168. Fetch address 0 and data address 0 name different memories. Data loads cannot read instruction ROM. |
| Peripheral map | [`agriasic_rv32i_mmio.sv:81`](../rtl/rv32i/agriasic_rv32i_mmio.sv#L81): intended `0x80000000–0x8000001F`, eight word registers. |
| Actual decode | MMIO lines 93–101 check address bit 31 and bits 4:2, not the full intended peripheral window. Higher peripheral addresses alias the same eight registers. Lower-half addresses select RAM, which then indexes only the implemented low bits. |
| Address-width assumptions | IMEM lines 31–32 and DMEM lines 34–35 use `$clog2(NUM_WORDS)` and discard byte-offset bits. Current effective slices are IMEM `[11:2]` and DMEM `[10:2]`. Power-of-two depths fit this decode naturally; other depths need explicit range handling. |
| Bounds checks | IMEM line 69 and DMEM line 76 have simulation assertions under `ifndef SYNTHESIS`. These do not implement silicon address-fault traps. Out-of-map addresses can alias/truncate in hardware. |
| Linker | [`link.ld:15`](../fw/link.ld#L15) declares only a 4 KiB ROM region at zero. `.text` goes there; assertions at lines 34–39 require `.rodata`, `.data`, and `.bss` to be empty. No RAM, stack or heap section is reserved by the linker. |
| Startup / stack | [`start.S:12`](../fw/start.S#L12) sets SP=`0x800`, calls `main`, then loops over `ecall`/jump. No C runtime, data copy, BSS clear, or heap setup. |
| Caches | No instantiated I-cache or D-cache in this top. `cycle_status.sv:50` explicitly labels its cache-miss enum values unused. The verification-only `MemorySyncUnified` and `Processor` near core line 1263 are not the ASIC integration. |
| CPU writes to IMEM | Not supported: the IMEM interface has no data input or write enable; stores only reach the data/MMIO path. |
| Macro hooks | `AGRIASIC_USE_SRAM_MACRO` branches are placeholders with no implemented memory instance. Defining the flag does not create working SRAM. |

Clock-related context from the preceding analysis still applies: current
`core_clk_en` holds CPU state during measurement; it is not an implemented
integrated clock gate. That distinction does not change the address calculations.

## Stack, heap and result storage

The compiled call graph is `_start -> main -> run_sweep_point`.
`run_one_measurement` is inlined. GCC's
[stack-usage file](../fw/agriasic_fw.elf-fw.su) reports:

| Function | Stack frame |
|---|---:|
| `main` | 32 B, static |
| `run_sweep_point` | 0 B, static |
| Startup | No additional frame |

Disassembly confirms `main` subtracts 32 from SP at `0xA0`, saves `ra`, `s0`,
and `s1`, and uses two stack words for I/Q. The helper's accumulators stay in
registers. No large local arrays, recursion, dynamic stack allocation, interrupt
entry code or architectural trap handler is present. This 32-byte maximum
applies to this optimized image and current non-interrupting execution; a
future ISR, library call, printf or changed optimization needs a new analysis.
Reserve **256 B** for stack growth in the recommended 2 KiB configuration,
at `0x700–0x7FF`, as an engineering allowance rather than measured usage.

No `malloc`, `calloc`, `realloc`, `free`, C++ allocation, dynamic container or
heap-dependent runtime is used by this application. **Heap requirement: zero.**

Fixed-address results are defined in [`fw.c:70`](../fw/fw.c#L70). They are
volatile pointer accesses, not linker-allocated `.data` or `.bss` objects:

| Data | Byte interval | Payload |
|---|---|---:|
| Measurement count and number of frequencies | `0x100–0x107` | 8 B |
| Three divider values | `0x110–0x11B` | 12 B |
| Three I results | `0x120–0x12B` | 12 B |
| Three Q results | `0x130–0x13B` | 12 B |
| Temperature sentinel | `0x140–0x143` | 4 B |
| **Total** | **`0x100–0x143` including holes** | **48 B payload / 68 B interval** |

The current sweep has three frequencies and two runs per frequency, with four
I/Q pairs per run. It stores final averaged I and Q, not an array of the six
individual measurements or raw ADC samples. The result set consumes 12 32-bit
words, even though each hardware accumulator is 16-bit signed.

The accelerator separately owns two 16-bit live accumulators and two 16-bit
shadow registers—64 bits total—at
[`measurement_fsm.sv:97`](../rtl/ctrl/measurement_fsm.sv#L97). Its SAR sample
slots hold two 8-bit codes at
[`sar_controller.sv:56`](../rtl/ctrl/sar_controller.sv#L56). These are accelerator
registers and do not consume CPU DMEM. Configuration, status, SAR state and
timing counters are also separate hardware registers. Firmware scalars/spills
are already covered by the measured stack frame.

## Runtime address audit

An instrumented, generated copy of the existing end-to-end testbench monitors
the exact CE/read/write requests sampled on each rising clock edge. Production
RTL is unchanged. Both existing memory-wrapper assertions and added full-map
bounds checks were enabled. The run includes the full sweep plus 32 extra
cycles after the original checks to observe the halt loop.

All original checks passed: 6 measurements, correct dividers, I=400 and Q=280
at all three points, and the core-PC freeze assertion. There were **zero
out-of-map accesses and zero RAM loads before an observed write** for this
workload. See [raw accesses](results/accesses.csv),
[address summary](results/address_summary.json) and
[simulation log](results/simulation.log).

| Quantity | Observed result |
|---|---|
| Highest linked instruction byte | **`0x17F`** |
| Highest fetched word address | **`0x184`**, covering bytes through **`0x187`** |
| Highest retired instruction address | `0x17C`, the final `ret` instruction |
| Fetches outside the linked image | `0x180` and `0x184`; neither retired |
| Highest result-buffer byte | **`0x143`** |
| Stack-frame interval | `0x7E0–0x7FF`, 32 B reserved by SP adjustment |
| Lowest/highest actual stack-access bytes | **`0x7E8–0x7FF`**, 20 distinct bytes within a 24-byte interval |
| Highest normal RAM byte including stack | **`0x7FF`** |
| Total distinct RAM bytes accessed | 68 B = 48 result bytes + 20 stack bytes |
| Required DMEM extent from origin zero | **2,048 B**, including gaps |

The two extra fetches are pipeline lookahead before return redirects fetch to
the halt loop. They remain inside the implemented 4 KiB IMEM but lie beyond
the 96 initialized firmware words. The retirement monitor confirms neither
executes in this run. A final ROM implementation should define unused locations
explicitly, for example with RV32 NOP `0x00000013`; do not rely on a two-state
simulator's value for uninitialized words. A 512-byte IMEM covers both the code
and the observed lookahead without an architectural change to the pipeline.

SP is initialized with two instructions and briefly holds `0x1000` before
becoming `0x800`; no memory access uses that intermediate value. The active
frame lowers SP to `0x7E0`, then the epilogue restores `0x800`. SP itself is a
pointer and the exclusive top, not an occupied byte requiring address `0x800`.

Every MMIO word accessed lies within the intended 32-byte region:

| Word address / byte interval | Operation | Count |
|---|---|---:|
| `0x80000000–0x80000003`, CTRL | Write | 7 |
| `0x80000004–0x80000007`, PAIR_LOG2 | Write | 1 |
| `0x80000008–0x8000000B`, SETTLE | Write | 1 |
| `0x8000000C–0x8000000F`, DIVIDER | Write | 3 |
| `0x80000010–0x80000013`, CONV | Write | 1 |
| `0x80000014–0x80000017`, STATUS | Read | 6 |
| `0x80000018–0x8000001B`, RESULT_I | Read | 6 |
| `0x8000001C–0x8000001F`, RESULT_Q | Read | 6 |

The high MMIO addresses do not imply gigabytes of physical RAM. They are a
separate decoded peripheral region. No invalid access was observed; the RTL
does not implement an operating-system segmentation-fault mechanism.

## Minimum and recommended sizes

| Memory | Current usage | Minimum practical size for unchanged binary | Initial recommendation | Headroom / qualification |
|---|---:|---:|---:|---|
| IMEM | 384 B linked; fetch span 392 B | **512 B** | **1 KiB** | 640 B beyond linked image, 62.5% of capacity |
| Linker-allocated static RAM | 0 B | — | — | Absolute-pointer buffers are counted below |
| Result buffers | 48 B payload, 68 B interval at `0x100` | Span reaches `0x143` | Reserve existing addresses | Keep holes and placement explicit |
| Stack | 32 B frame at top of RAM | Preserve top `0x800` | Reserve **256 B** | 224 B beyond current frame |
| Heap | 0 B | 0 B | **0 B** | Revisit only if a runtime needs it |
| Total DMEM | 80 B payload/frame budget, through byte `0x7FF` | **2 KiB** | **2 KiB** | 1,968 B outside the current 80 B budget; fixed placement still spans all 2 KiB |

The absolute linked code requirement is 384 B; the current observed fetch
interface additionally reaches byte `0x187` (392 B from zero). Practical
power-of-two sizing gives 512 B. The current configured 4 KiB IMEM leaves
3,712 B beyond the linked image; no evidence calls for expanding it to 8 KiB.

For DMEM, **80 B is a payload budget, not the required physical depth**.
Reducing DMEM below 2 KiB requires changing startup SP or address translation.
If a later revision moves SP to `0x200`, a 512-byte RAM can fit the present
result addresses and 32-byte frame; a 128-byte stack reservation at
`0x180–0x1FF` also avoids the results. This is an unimplemented candidate to
rebuild and verify. For a more generous macro-free candidate, 1 KiB RAM with
SP=`0x400` and a 256-byte stack reservation avoids this constraint comfortably.
Moving the result buffers too could pack the payload more tightly, but that
would change the current absolute-address contract.

## Implementation choices

The following are engineering comparisons, not TSMC area/timing results.
An RTL array does not automatically create a dense ASIC memory. Yosys, for
example, maps unsupported memories to registers and decoder logic unless a
suitable memory-library mapping is provided.
[Yosys memory mapping documentation](https://yosyshq.readthedocs.io/projects/yosys/en/latest/using_yosys/synthesis/memory.html#memory-mapping).

| Technology | IMEM assessment | DMEM assessment |
|---|---|---|
| FF/register array | A writable 1 KiB array is 8,192 storage FF bits plus mux/decode; storing immutable code this way is usually wasteful. An FF `initial` value alone is not a silicon loading mechanism. | Technically possible: 512 B / 1 KiB / 2 KiB are 4,096 / 8,192 / 16,384 storage bits, plus read muxes, byte write enables and output state. The unchanged 2 KiB choice has substantial clock/area cost. |
| Synthesized constant ROM | **Realistic for this firmware.** 384 B encodes 3,072 constant bits; a 1 KiB address space contains 8,192 logical bits, but the constant truth table can optimize into gates/muxes with a 32-bit registered output. It does not require one FF per constant bit. | Cannot replace writable stack/results. Could only store separate read-only constants if a data-side ROM path were added. |
| Synthesized RAM | Gives writable code only after adding a loader/write port; may become FF RAM without a macro mapping. Preserve registered read/CE behavior. | Convenient behavioral description, not a distinct dense physical technology. Check the mapped netlist; generic ASIC synthesis can produce the same large FF array. |
| SRAM compiler macro | Useful if firmware must be reloadable. Must add boot loading and match CE, one-cycle read, and output-hold behavior. Macro size/granularity can exceed the required 1 KiB. | **Preferred for the unchanged 2 KiB RAM if a suitable qualified macro is available.** It avoids 16,384 ordinary FF storage bits, but compiler support, views, test/repair requirements and read/write timing must be checked. |
| ROM compiler macro | Technically suitable for fixed firmware, subject to availability and minimum geometry. For 384 B of code, qualification and fixed periphery may outweigh any saving over logic ROM. | Not a replacement for writable DMEM. |

At the 160 MHz design target, both memories must meet the actual 6.25 ns
interface timing with the core. A large standard-cell read mux or a small
memory macro may require changes if it cannot. The current RTL contract is
one-cycle synchronous access, not a variable-latency bus. Numeric area, leakage,
clock power and maximum frequency require the target TSMC 180 nm libraries
and the selected compiler views; none is inferred merely from bit count.

The small code is a strong case for synthesized ROM. Avoiding **all** SRAM
macros is plausible after sizing/rebasing DMEM, but retaining 2 KiB as FF RAM
can dominate the register storage and clock load: the preceding generic core
analysis had 2,800 register bits outside its memory macros, versus 16,384 bits
for a full FF-based 2 KiB scratch RAM alone.

## Is a separate Boot ROM necessary?

Not for a permanently programmed application ROM. The existing reset entry
can live at address zero in the application ROM itself. `$readmemh` can supply
the constant image to a supported synthesis flow; it is not a physical ASIC
mechanism for loading volatile SRAM at power-up.

| Option | Additional memory | Required changes and initialization | Complexity / first-silicon tradeoff |
|---|---|---|---|
| **A. Software Boot ROM copies external SPI flash** | New small boot ROM plus writable application IMEM; a word buffer and boot stack in DMEM. Boot-ROM size is not measured because this code does not exist; 0.5–1 KiB is only a provisional budget to compile and verify. | Add SPI **master**, data-side programming access to IMEM, and boot/application fetch selection or a separately linked application address. CPU stores currently cannot write IMEM. Initialize future `.data` and `.bss` if introduced; current application needs no full DMEM clear. | Flexible boot policy but additional software, address-map/handoff and hardware work. The existing SPI **slave** is insufficient to read an external flash. |
| **B. Hardware SPI loader while CPU is reset** | No Boot ROM. Writable application IMEM plus loader command/address/count/shift registers; streaming permits a word-sized data buffer. | Add SPI master FSM, an IMEM programming-port mux, image-length/range checks, and reset release after loading. Add DMEM loading only if future initialized data requires it. | Attractive for a fixed simple boot protocol: avoids a CPU boot program. Still needs flash protocol, timeout/error behavior and loading verification. |
| **C. Entire firmware in synthesized ROM** | No separate boot memory; the 1 KiB recommended IMEM contains reset code and application. | Implement a fully specified constant ROM image with synchronous read/hold behavior. DMEM can be initially unknown because current loads follow writes, as checked in this run. | **Simplest current first-silicon option.** No loader or external flash dependency, but changing firmware requires changing the silicon image. |
| **D. External host programs memories before release** | No Boot ROM or on-chip flash-reading firmware; writable IMEM and small loader registers/buffer. | Extend/connect a host programming interface to an IMEM write port and hold the CPU reset until the host signals completion. The current SPI/parallel wrappers only program measurement configuration; they do not load CPU IMEM. | Simple on-chip loader for lab bring-up, with a host required at boot. This is additional hardware, not an existing feature. |

All loader options must define fetch handoff at the application's reset vector
and preserve the Harvard split. They are alternatives for a future decision;
none was implemented in this analysis.

## Concrete recommendation

Current firmware:

- Code/constant footprint: **384 B**, last linked byte **`0x17F`**;
  observed pipeline fetches reach **`0x187`**.
- Static RAM footprint: **0 B in linker sections**, plus **48 B fixed-address
  result payload** spanning **`0x100–0x143`**.
- Estimated stack: **32 B**, recommend reserving **256 B** for growth.
- Heap: **0 B**.
- Total required CPU RAM: **2 KiB for the current addresses**, despite an
  80 B result-plus-frame budget. Current highest occupied/accessed RAM byte:
  **`0x7FF`**.

Recommended initial memory configuration:

- Boot ROM: **none**, if application code is permanent.
- Instruction memory: **1 KiB**, 256 x 32; current binary fits in 512 B.
- Data memory: **2 KiB**, 512 x 32, preserving SP=`0x800` and result addresses.

Recommended implementation:

- Boot ROM technology: **not applicable** for the fixed-image option.
- IMEM technology: **synthesized constant ROM with synchronous output**;
  use a ROM macro only if an appropriate one is readily available and beneficial.
- DMEM technology: **qualified SRAM macro if available for 2 KiB**. If avoiding
  macros is a project priority, assess **1 KiB FF RAM with rebased SP** as a
  separate design change; synthesize and time it before committing.

The five largest growth uncertainties are external-flash boot and error
handling; calibration tables/constants requiring data-side storage; integrated
SPI host protocol/result buffers; temperature/calibration/extra-frequency
firmware; and interrupt/trap/runtime-library support with additional stack.
The current absence of host access to the CPU's scratch results is also an
integration task, not evidence that more raw ADC buffering is needed.

## Reproduction and validation

From the repository root, in Linux/WSL with the project's RISC-V toolchain and
Verilator:

```bash
bash agriasic_digital_v2/memory/collect_build.sh
bash agriasic_digital_v2/memory/run_sim.sh
python3 agriasic_digital_v2/memory/summarize.py
python3 agriasic_digital_v2/memory/check_reporter.py
```

The first command runs the actual firmware build and saves `readelf -W -S -l`
and `objdump -h` output. Running `fw/build.sh` directly also generates the map,
stack-usage and address reports. The simulation builds in a fresh `/tmp`
directory to avoid Verilator's make-path restriction on spaces, and logs
addresses through read-only monitors. The summarizer checks byte extents,
MMIO windows, RAM read-before-write and retired instruction addresses.

`check_reporter.py` exercises the requested alignment/gap failure mode with a
synthetic ELF: **8 bytes of allocated sections separated by a gap require
4,100 bytes of address span**, and zero-sized/metadata sections do not expand
that span. It does not alter the application image. All RTL, application C,
startup and linker layout are unchanged by this work.

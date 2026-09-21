# AGRASIC instruction/data memory requirements analysis

Repository analyzed: `agrasic/` at commit `b2f1309` (Rev 4.3, Phases 1–8).
The sibling `agriasic_digital_v2/` at the workspace root is an older pre-Rev-4.3
copy and was not used.

All numbers below come from a clean firmware rebuild and a fresh instrumented
simulation run (2026-09-20). Toolchain: RISC-V GCC 13.2.0, GNU ld 2.42,
Verilator 5.020, all under WSL.

---

## 1. Current memory architecture

| Item | Finding | Source |
|---|---|---|
| Instruction memory | `agriasic_imem`: 32-bit words, synchronous read under `ce_i`, 1-cycle latency, output holds when `ce_i` low. **No write port** (ports: `clk, rst_n, ce_i, addr_i, dout_o`). Behavioral array initialized by `$readmemh` — not a silicon mechanism. `AGRIASIC_USE_SRAM_MACRO` branch is an empty placeholder. | [`rtl/rv32i/agriasic_imem.sv:20-58`](../rtl/rv32i/agriasic_imem.sv#L20-L58) |
| Data memory | `agriasic_dmem`: single-port, byte write enables, 1-cycle read, no-change output on write. | [`rtl/rv32i/agriasic_dmem.sv:22-66`](../rtl/rv32i/agriasic_dmem.sv#L22-L66) |
| Actual depths | `IMEM_WORDS = 1024` (4 KiB), `DMEM_WORDS = 512` (2 KiB). These override the 1024-word defaults in `agriasic_dmem.sv:23` and `agriasic_rv32i_mmio.sv:54`. | [`rtl/agriasic_rv32i_control_shell.sv:66-67`](../rtl/agriasic_rv32i_control_shell.sv#L66-L67) |
| Reset PC | `f_pc_current <= 32'd0` on `rst`. Core is held in reset while `start_i` is low. | [`core.sv:252-254`](../rtl/rv32i/agriasic_rv32i_core.sv#L252-L254), [`control_shell.sv:79-85`](../rtl/agriasic_rv32i_control_shell.sv#L79-L85) |
| Address ranges (intended) | IMEM `0x0000_0000–0x0000_0FFF`; DMEM `0x0000_0000–0x0000_07FF`; MMIO `0x8000_0000–0x8000_001F` (8 words). | [`rtl/rv32i/agriasic_rv32i_mmio.sv:8-41`](../rtl/rv32i/agriasic_rv32i_mmio.sv#L8-L41) |
| Address decode (actual) | `periph_sel = addr_i[31]`, `periph_reg = addr_i[4:2]`. Only bit 31 and bits 4:2 are decoded: the entire upper 2 GiB aliases onto 8 registers; the entire lower 2 GiB aliases onto DMEM modulo its depth. | [`mmio.sv:93-101`](../rtl/rv32i/agriasic_rv32i_mmio.sv#L93-L101) |
| MMIO registers | CTRL(W), PAIR_LOG2, SETTLE, DIVIDER[13:0], CONV, STATUS(R), RESULT_I(R, sign-ext 16b), RESULT_Q(R, sign-ext 16b). | [`mmio.sv:81-88`](../rtl/rv32i/agriasic_rv32i_mmio.sv#L81-L88), [`fw/fw.c:43-53`](../fw/fw.c#L43-L53) |
| Stack location | `li sp, 0x800` — top of 2 KiB DMEM, grows down. Assembles to `lui sp,0x1; addi sp,sp,-2048`. | [`fw/start.S:12`](../fw/start.S#L12) |
| Linker script | Single `ROM` region, `ORIGIN=0, LENGTH=4K`. `.text` → ROM. `.rodata/.data/.bss` are directed to ROM but **`ASSERT`ed to be empty** (Harvard split makes them unreachable from the data port). No RAM region, no stack/heap symbols. | [`fw/link.ld:15-39`](../fw/link.ld#L15-L39) |
| Startup | 3 instructions: set SP, `call main`, then `ecall; j halt` forever. No `.data` copy, no `.bss` clear, no heap init, no trap vector. | [`fw/start.S:7-19`](../fw/start.S#L7-L19) |
| Section placement | `.text` at 0x0 (IMEM). `.rodata/.data/.bss` = 0 bytes. Stack: implicit at DMEM top. Heap: none. Result buffers: absolute volatile pointers at DMEM `0x100–0x143`, not linker-allocated. | [`fw/fw.c:70-75`](../fw/fw.c#L70-L75) |
| True Harvard? | **Yes.** Shell instantiates `u_imem` on `pc_to_imem` and `u_mmio`/`u_dmem` on `addr_to_dmem` as independent arrays. Data address 0 and fetch address 0 are different physical words. A load can never read IMEM. | [`control_shell.sv:149-158`](../rtl/agriasic_rv32i_control_shell.sv#L149-L158), [`:168-187`](../rtl/agriasic_rv32i_control_shell.sv#L168-L187) |
| CPU writes to IMEM? | **No.** IMEM has no `we`/`din`; the core's store path (`store_we_to_dmem`, `store_data_to_dmem`) connects only to the MMIO bridge. | [`core.sv:1141-1143`](../rtl/rv32i/agriasic_rv32i_core.sv#L1141-L1143) |
| Caches | **None.** `CYCLE_ICACHE_MISS`/`CYCLE_DCACHE_MISS` are explicitly "NOT CURRENTLY USED". `MemorySyncUnified` (8192-word unified) and `Processor` are verification-only wrappers for riscv-tests/Dhrystone. | [`cycle_status.sv:50-53`](../rtl/rv32i/cycle_status.sv#L50-L53), [`core.sv:1263-1275`](../rtl/rv32i/agriasic_rv32i_core.sv#L1263-L1275) |
| Traps / interrupts | **None.** No CSRs, no `mtvec`, no interrupt input anywhere in `rtl/`. `ecall` sets `halt`, which becomes the shell's `done_o`; the pipeline keeps looping on `ecall; j halt`. Illegal or out-of-range addresses do **not** trap — they silently alias. | [`core.sv:589`](../rtl/rv32i/agriasic_rv32i_core.sv#L589), [`:1044`](../rtl/rv32i/agriasic_rv32i_core.sv#L1044), [`:1252`](../rtl/rv32i/agriasic_rv32i_core.sv#L1252) |

### Hard-coded depth / width assumptions

Everything that must change together if sizes change:

- `AddrMsb = $clog2(NUM_WORDS)+1`; index slice is `addr_i[AddrMsb:2]` — assumes power-of-two depth. Currently IMEM `[11:2]`, DMEM `[10:2]`. Bits above are ignored in silicon; only checked by `ifndef SYNTHESIS` assertions — [`agriasic_imem.sv:31-32,60-73`](../rtl/rv32i/agriasic_imem.sv#L31-L32), [`agriasic_dmem.sv:34-35,68-80`](../rtl/rv32i/agriasic_dmem.sv#L34-L35).
- `IMEM_WORDS`/`DMEM_WORDS` in the shell ([`:66-67`](../rtl/agriasic_rv32i_control_shell.sv#L66-L67)); `LENGTH = 4K` in [`link.ld:17`](../fw/link.ld#L17); the 1024-word guard in [`build.sh:31`](../fw/build.sh#L31); `SP = 0x800` in [`start.S:12`](../fw/start.S#L12); result addresses `0x100–0x140` in [`fw.c:70-75`](../fw/fw.c#L70-L75) and mirrored as word indices in [`tb_agriasic_rv32i_e2e.sv:100-105`](../tb/tb_agriasic_rv32i_e2e.sv#L100-L105).
- `addr_to_dmem = {mem_addr[31:2], 2'b00}` — word-aligned bus, byte lanes via `we` ([`core.sv:1086`](../rtl/rv32i/agriasic_rv32i_core.sv#L1086)).

---

## 2. Firmware build

Only one application exists: [`fw/fw.c`](../fw/fw.c) (3-frequency I/Q sweep).
riscv-tests and Dhrystone are ISA-regression workloads run through the
verification-only `Processor` wrapper and are not the AGRASIC application.

Clean rebuild (in WSL; `-march=rv32im -mabi=ilp32 -Os -ffreestanding -nostdlib -nodefaultlibs`):

```bash
cd agrasic/agriasic_digital_v2/fw
rm -f agriasic_fw.elf agriasic_fw.bin agriasic_fw.map agriasic_fw.elf-fw.su
bash build.sh                      # emits -Wl,-Map=agriasic_fw.map,--cref and -fstack-usage
riscv64-unknown-elf-size -A agriasic_fw.elf
riscv64-unknown-elf-readelf -W -S -l agriasic_fw.elf
riscv64-unknown-elf-objdump -h agriasic_fw.elf
riscv64-unknown-elf-nm -n -S agriasic_fw.elf
```

The regenerated `agriasic_fw.hex` is byte-identical to the committed one
(md5 `ef9cdae8f7c38c5f76f7e4e26b916286`).

| Section | Size | VMA / LMA | Flags | Notes |
|---|---:|---|---|---|
| `.text` | **384 B** | `0x0000_0000` | AX, align 4 | The only allocated section |
| `.rodata` | 0 | — | | asserted empty |
| `.data` | 0 | `0x180` (empty) | | asserted empty |
| `.bss` | 0 | `0x180` (empty) | | asserted empty |
| `.symtab/.strtab/.shstrtab` | 0xB0 + 0x4B + 0x21 | non-alloc | | metadata only |

`size`: `text=384 data=0 bss=0 dec=384`. The one `PT_LOAD` segment has
`FileSiz=MemSiz=0x180`; its `Align 0x1000` is a file/page alignment and does
not imply 4 KiB of IMEM.

- **Instruction-memory footprint: 384 B (96 words)**
- **Statically allocated data-memory footprint (linker): 0 B**; plus 48 B of absolute-address result words (see §5).

### Linker map — highest occupied address, alignment, gaps

Source: [`fw/agriasic_fw.map`](../fw/agriasic_fw.map).

**IMEM (ROM region, origin 0x0, length 0x1000):**

| Input section | Start | End (incl.) | Size | Symbol |
|---|---|---|---:|---|
| `.start` (start.S) | `0x000` | `0x013` | 20 | `_start`, `halt`@0xC |
| `.text` (fw.c) | `0x014` | `0x09F` | 140 | `run_sweep_point` |
| `.text.startup` (fw.c) | `0x0A0` | `0x17F` | 224 | `main` |

- Highest occupied byte: **`0x0000_017F`**; exclusive end **`0x180`**; span from origin **384 B**.
- Alignment: all input sections 4-byte aligned; every boundary falls naturally on a multiple of 4, so **zero padding bytes and zero gaps** — section sum (384) equals span (384).
- Unused ROM: `0x180–0xFFF` (3,712 B of the configured 4 KiB).

**DMEM (not linker-managed — placement is by absolute addresses and SP):**

| Region | Bytes | Payload | Holes inside region |
|---|---|---:|---|
| Unused low | `0x000–0x0FF` | 0 | 256 B (deliberately avoids NULL, fw.c:62-64) |
| OUT_COUNT, OUT_NUM_POINTS | `0x100–0x107` | 8 | — |
| hole | `0x108–0x10F` | 0 | 8 B |
| OUT_DIV[0..2] | `0x110–0x11B` | 12 | hole `0x11C–0x11F` (4 B) |
| OUT_I[0..2] | `0x120–0x12B` | 12 | hole `0x12C–0x12F` (4 B) |
| OUT_Q[0..2] | `0x130–0x13B` | 12 | hole `0x13C–0x13F` (4 B) |
| OUT_TEMP | `0x140–0x143` | 4 | — |
| gap | `0x144–0x7DF` | 0 | 1,692 B |
| `main` stack frame | `0x7E0–0x7FF` | 20 touched of 32 reserved | `0x7E0–0x7E7`, `0x7F0–0x7F3` never touched |

- Highest occupied DMEM byte: **`0x0000_07FF`** (stack); highest non-stack byte: **`0x143`**.
- Result payload 48 B inside a 68 B interval (20 B of holes); required extent from origin **2,048 B** because of where SP sits.

**MMIO:** `0x8000_0000–0x8000_001F`, all 8 words used, no gaps.

---

## 3. Stack usage

Call graph from disassembly and `nm`: `_start → main → run_sweep_point`
(leaf). `run_one_measurement` is inlined. No recursion, no function pointers,
no large locals, no `alloca`.

GCC `-fstack-usage` ([`fw/agriasic_fw.elf-fw.su`](../fw/agriasic_fw.elf-fw.su)):

```
fw.c:106:13:run_sweep_point   0   static
fw.c:125:5:main              32   static
```

`main` prologue at `0xA0`: `addi sp,sp,-32`; saves `ra`@+28, `s0`@+24,
`s1`@+20; locals `i`@+8, `q`@+12. `run_sweep_point` uses only registers and
writes through `a1/a2` into `main`'s frame.

- **Likely normal usage: 32 B** (proven maximum for this image: it is the only frame, and it is static).
- **Largest contributor:** `main` (3 callee-saved regs + 2 locals, padded to 16-byte ABI alignment).
- **Interrupt/trap stack: 0** — no trap mechanism exists in the RTL.
- **Conservative recommendation: reserve 256 B.** That covers one future trap handler saving all 31 GPRs (124 B) plus a couple of extra call levels. Assumptions: still `-Os`, still no libgcc/printf, still no ISRs.

---

## 4. Heap

```bash
grep -rnE "\b(malloc|calloc|realloc|free|new|delete|sbrk|alloca|printf|memcpy|memset)\b" fw/ rtl/ tb/
```

Zero hits. Build uses `-nostdlib -nodefaultlibs`; no crt0, no
`_end`/`__heap_start` symbols exist. **Heap = 0 B, and it can stay 0.**

---

## 5. Measurement / result buffers

**Inside the accelerator (not CPU memory):**

- Two 16-bit signed live accumulators + two 16-bit shadow registers = 64 bits ([`measurement_fsm.sv:97-100`](../rtl/ctrl/measurement_fsm.sv#L97-L100)); `ACC_WIDTH=16`, M clamped to 64 pairs so |acc| ≤ 16,320 ([`:104-109`](../rtl/ctrl/measurement_fsm.sv#L104-L109)).
- SAR holds one 8-bit DAC code + bit index + regen counter ([`sar_controller.sv:77-79`](../rtl/ctrl/sar_controller.sv#L77-L79)); `d_plus/d_minus` are 8-bit outputs.
- **Raw ADC samples are never stored** — each pair is subtracted and accumulated on the fly. Only the final 16-bit I and Q are exposed via MMIO.

**In CPU DMEM:** 3 frequency points × (divider, I, Q) + count + num_points +
temp sentinel = **12 words = 48 B**. Firmware holds per-run `sample_i/sample_q`
in registers/one stack frame; no temporary arrays. CPU-visible SRAM actually
needed for results: **48 B** (68 B with the current one-word gaps).

---

## 6. Minimum IMEM/DMEM sizes

| Memory | Current usage | Minimum practical | Recommended | Headroom (recommended) |
|---|---:|---:|---:|---:|
| Instruction memory | 384 B linked (fetch span 392 B, see §9) | **512 B** (128×32) | **1 KiB** (256×32) | 640 B free / 62.5 % |
| Data memory static (results) | 48 B payload, ends at `0x143` | — | keep at `0x100` | — |
| Stack | 32 B measured | — | reserve 256 B | 8× |
| Heap | 0 B | 0 | **0** | — |
| **Total DMEM** | 80 B payload, but **2,048 B addressed** (SP=0x800) | **512 B** *(requires SP→0x200)* or **2 KiB** *(no change)* | **1 KiB** (256×32) with SP→0x400, or 2 KiB unchanged if a macro is used | 1 KiB: ~700 B free |

- **A. Absolute minimum IMEM** for the unchanged binary: 392 B addressed → **512 B**.
- **B. Absolute minimum DMEM:** for the unchanged binary **2 KiB** (only because `SP=0x800`); with a one-line SP change, 512 B holds results (`0x100–0x143`) + 188 B stack.
- **C. Recommended with margin:** **IMEM 1 KiB, DMEM 1 KiB** (SP rebased) — or DMEM 2 KiB if the firmware/startup stay untouched.

---

## 7. Implementation options (TSMC 180 nm)

Context from the existing generic synthesis
([`power/results/structure.json`](../power/results/structure.json)): the
entire digital block *excluding* memories is **2,800 register bits**; the core
is clock-enabled off 99.99 % of the sweep, so memory *dynamic* power is nearly
irrelevant — **area and clock-tree load are what matter**. Both memory address
inputs are driven straight from pipeline registers (`f_pc_current`,
`memory_state.mem_addr`), so macro setup time is not on a long combinational
path.

The following are qualitative engineering comparisons, not TSMC area/timing
results. An RTL array does not automatically become a dense ASIC memory —
without a compiler mapping, generic synthesis produces flops and decode logic.

### Instruction memory (1 KiB recommended, 384 B content)

| Option | Practical? | Storage bits | Area | Power | Timing @160 MHz (6.25 ns) | 180 nm concerns |
|---|---|---:|---|---|---|---|
| FF/register array | Technically, but wasteful: pays for writability the CPU cannot use | 8,192 FF + mux | Large: ~8k DFFs ≈ 3× all other registers in the design | Clock-tree load of 8k flops; needs ICG gating | Read mux 8 levels — fine | No reason to choose over ROM unless loadable; if loadable, needs a write port that does not exist |
| **Synthesized ROM** (constant `case`/mux, registered output) | **Yes — this is the sweet spot** | 3,072 constant bits (96 used words); logic optimizes heavily | Small: constant-table logic + 32 output FFs; est. low-thousands of gates | Negligible (fetches only 222 words in a whole sweep) | Trivially fast; registered output already matches the `ce/hold` contract | Firmware frozen at tapeout; unused words must be defined (e.g. NOP `0x13`); `$readmemh` must be replaced by an explicit constant table for synthesis |
| Synthesized RAM (behavioral array w/o macro) | Only becomes an FF array in ASIC flow | 8,192 | Same as FF array | Same | Same | No dense mapping without a compiler; "works in Yosys/FPGA" ≠ dense silicon |
| SRAM compiler macro | Yes if compiler is available; 1 KiB is near or below many compilers' minimum instance | 8,192 (or macro minimum) | Periphery-dominated at this size; a 4 KiB instance may cost little more than 1 KiB | Leakage small at 180 nm; per-access energy > ROM | Typical small-macro t_acc 2–4 ns — OK | Needs loader (IMEM has no write port), macro views/LEF/LIB, BIST/repair policy, PDK access |
| ROM compiler macro | Yes but marginal benefit | 8,192 | Fixed periphery ≈ area of the synthesized ROM at this size | Low | OK | Extra qualification for ~no gain at 384 B |

### Data memory (writable, 48 B results + stack)

| Option | Practical? | Storage bits | Area | Power | Timing | 180 nm concerns |
|---|---|---:|---|---|---|---|
| **FF/register array** | **Yes at 512 B–1 KiB; heavy at 2 KiB** | 4,096 / 8,192 / 16,384 | 512 B ≈ 1.5×, 1 KiB ≈ 3×, 2 KiB ≈ 6× the rest of the design's registers, plus byte-lane write muxing | Clock-tree dominated → must use per-word clock gating (ICG) or enable-gated latches | Read mux 8–9 levels + output reg — fine | Latch-based (not DFF) array roughly halves area; verify the std-cell lib has a usable latch and CTS handles it |
| Synthesized ROM | Not applicable (writable) | — | — | — | — | Could hold future constants only if a data-side ROM path were added |
| Synthesized RAM | Same as FF array in ASIC flow | as above | as above | | | |
| **SRAM compiler macro** | **Yes, preferred at 2 KiB if the compiler is available** | 16,384 | Much denser than flops; 512×32 SP SRAM is a common compiler point | Low idle | OK | Availability of the TSMC 180 SRAM compiler to the project is the gating question; matches the existing `ce`/byte-we/no-change contract almost exactly |
| ROM compiler macro | Not applicable | | | | | |

**Bottom line:** the code is small enough that a synthesized ROM is not just
realistic but the obvious choice for IMEM. DMEM is where macro-vs-no-macro is
a real decision — and it is only a hard decision because SP currently forces
2 KiB; at 1 KiB (SP=0x400) a gated FF/latch array is plausible in 180 nm.

---

## 8. Boot architecture

Facts that constrain every option:

- (a) IMEM has no write port.
- (b) The current RTL has an SPI **slave** only ([`rtl/ctrl/spi_slave.sv`](../rtl/ctrl/spi_slave.sv)) and it lives in `agriasic_digital_spi_top`, which is *not* composed with the RV32I top (MAS GAP-11).
- (c) DMEM needs **no** initialization — `.data/.bss` are empty and the simulation confirmed zero loads-before-store.
- (d) The shell already holds the core in reset until `start_i` ([`control_shell.sv:79-85`](../rtl/agriasic_rv32i_control_shell.sv#L79-L85)), which is a ready-made "release CPU after load" hook.

| | A: Boot ROM + SW SPI loader | B: HW SPI boot FSM | **C: Firmware in synthesized ROM** | D: Host programs IMEM via existing SPI slave |
|---|---|---|---|---|
| Extra memory | Boot ROM (~0.5–1 KiB, not yet written) + writable IMEM (1–4 KiB SRAM) + boot stack/word buffer in DMEM | Writable IMEM + a few loader registers (addr/count/shift) | **None** — 1 KiB ROM holds reset vector + app | Writable IMEM + addr/data/we registers |
| IMEM writable? | Yes (needs a data-side write path to IMEM — new) | Yes (dedicated load port + mux) | **No** | Yes |
| DMEM init? | No (app); yes if boot code uses `.data` | No | **No** | No |
| HW changes | SPI master, IMEM write port, boot/app address mux, flash protocol | SPI master FSM, IMEM write port, length/CRC check, reset release | Replace `$readmemh` array with constant table; define unused words | Compose SPI slave with RV32I top, add IMEM write port, use `start_i` as release |
| Complexity | Highest (SW + HW + two images) | Medium | **Lowest** | Low-medium |
| First-silicon pros | Field-updatable firmware, flexible boot policy | Updatable firmware without a second CPU program | No loader, no external flash, no boot-time failure modes; smallest area; simplest verification | Reuses the SPI ingress that must exist anyway (GAP-11); good for bring-up |
| First-silicon cons | Most new untested logic; two failure domains | Needs flash protocol + error handling; loader bugs brick the chip | **Firmware frozen at tapeout** — the roadmap still has SPI result packing and temperature work unbuilt | Host must be present at every boot (fine for a lab die, not for a deployed node) |

A separate Boot ROM is **not necessary**: nothing in the current design needs
it. The smallest reasonable architecture is C. If updatable firmware is
wanted, D is the least new logic because the shell's reset-until-`start_i`
behavior already exists; B is the right choice for a deployed node.

---

## 9. Out-of-range access check (simulation)

Method: [`memory/prepare_sim.py`](prepare_sim.py) injects **read-only
monitors** into a *generated copy* of `tb_agriasic_rv32i_e2e.sv`; functional
RTL is untouched. It samples `imem_ce/pc_to_imem`,
`mem_read_en|store_we/addr_to_dmem` (pre-NBA, i.e. exactly what the memory
latched), SP, and retired PCs each posedge, with `$fatal` on
`imem > 0xFFC`, `dmem > 0x7FC`, `mmio > 0x8000001C`. Verilator `--assert` also
enables the RTL's own `ifndef SYNTHESIS` bounds assertions.

```bash
cd agrasic/agriasic_digital_v2
bash memory/run_sim.sh          # verilator --binary --timing --assert ... → results/simulation.log, accesses.csv
python3 memory/summarize.py     # → results/address_summary.json
```

Result: `[TB] PASS`, 6 measurements, I=400/Q=280 at all points,
3,152,965 cycles, **no assertion failures, `invalid_accesses: []`,
`data_loads_before_observed_store: []`**. Raw data:
[`results/accesses.csv`](results/accesses.csv),
[`results/address_summary.json`](results/address_summary.json),
[`results/simulation.log`](results/simulation.log).

| Quantity | Observed |
|---|---|
| Highest **retired** instruction address | `0x17C` (final `ret`) |
| Highest **fetched** word address | **`0x184`** (bytes through `0x187`) — pipeline lookahead of 2 words past `0x17F` after `ret`, before the redirect to `0xC`; neither retires |
| Lowest / highest stack byte touched | **`0x7E8` / `0x7FF`** (20 bytes; SP sequence `0x1000→0x800→0x7E0→0x800`; the transient `0x1000` never issues an access) |
| Highest normal (non-stack) DMEM byte | **`0x143`** |
| Distinct DMEM bytes touched | 68 (48 result + 20 stack) |
| MMIO accesses | `0x80000000` CTRL ×7 W, `0x04` PAIR_LOG2 ×1 W, `0x08` SETTLE ×1 W, `0x0C` DIVIDER ×3 W, `0x10` CONV ×1 W, `0x14` STATUS ×6 R, `0x18` RESULT_I ×6 R, `0x1C` RESULT_Q ×6 R — all inside `0x8000_0000–0x8000_001F` |
| Accesses outside valid regions | **None** |

Two things to carry into silicon:

1. ROM words `0x180` and `0x184` **are fetched**, so a 512 B ROM must still exist there and should be defined (NOP).
2. In hardware nothing traps — an out-of-map address aliases silently (e.g. SP underflow below 0 would land in MMIO because bit 31 sets). The simulation assertions are the only guard; keep them in the regression.

Post-`ecall` behavior observed: the core does not stop. It keeps retiring
`ecall`/`j halt` (`0xC`/`0x10`) with lookahead fetches of `0x14`/`0x18`;
`halt` only drives `done_o`.

---

## 10. Final recommendation

**Current firmware:**

- Code/constant footprint: **384 B** (`.text`, no `.rodata`), highest linked byte `0x17F`, highest fetched byte `0x187`
- Static RAM footprint: **0 B linker-allocated + 48 B absolute-address results** (`0x100–0x143`)
- Estimated stack: **32 B** (proven for this image); reserve 256 B
- Heap: **0 B**
- Total required CPU RAM: **80 B payload**; **2 KiB as currently addressed** (SP=0x800); **512 B–1 KiB** after a one-line SP rebase

**Recommended initial memory configuration:**

- Boot ROM: **none**
- Instruction memory: **1 KiB (256×32)**
- Data memory: **1 KiB (256×32) with `SP=0x400`** if macro-free; **2 KiB (512×32) unchanged** if an SRAM macro is used

**Recommended implementation:**

- Boot ROM technology: N/A (Option C); if updatability is needed later, add Option D/B loader hardware — not a boot ROM
- IMEM technology: **synthesized constant ROM with registered output** (replace the `$readmemh` array with an explicit constant table; pad to NOP)
- DMEM technology: **SRAM compiler macro (512×32) if the TSMC 180 compiler is available to the project; otherwise a clock-gated FF/latch array at 1 KiB (SP=0x400)** — synthesize and time it before committing; 2 KiB of flops (16,384 bits ≈ 6× the rest of the design) is the one configuration not to do without a macro

**Can this avoid SRAM macros?** For IMEM, unambiguously yes — 384 B of frozen
code as a logic ROM is tiny. For DMEM, yes *if* the SP rebase to 1 KiB (or
512 B) is accepted and the array's clock is gated; the working set is 80 B, so
the only reason DMEM is "2 KiB" today is a stack-pointer constant. The whole
design can plausibly be macro-free.

**Biggest uncertainties that could grow memory before tapeout:**

1. **Host-facing result path (GAP-11)** — SPI service loop, 13-byte result packing, and any command parsing move into firmware and may add MMIO/buffer state; plausibly +0.5–1 KiB code.
2. **Temperature/PTAT read and compensation math** — if calibration coefficients or lookup tables appear they are `.rodata`, which the Harvard split currently *forbids*; that forces either a data-side ROM path or a copy-to-RAM startup, i.e. an architectural change, not just bytes.
3. **Boot/loader firmware** if Option A is chosen — a second image plus buffer and stack, and IMEM becomes writable SRAM.
4. **Toolchain drift** — dropping `-Os`, pulling libgcc (64-bit or float ops), or adding any debug `printf` can multiply code size 5–20× and add `.rodata` strings.
5. **Interrupts/traps** — none exist; adding a wake-up timer or SPI interrupt adds a trap vector, handler code, and ~128 B/level of context-save stack.

---

## Reproduction

From the repository root, in WSL with the RISC-V toolchain and Verilator:

```bash
bash agriasic_digital_v2/memory/collect_build.sh    # rebuild fw, save readelf/objdump/size output
bash agriasic_digital_v2/memory/run_sim.sh          # instrumented e2e sim → accesses.csv
python3 agriasic_digital_v2/memory/summarize.py     # → address_summary.json
```

Artifacts regenerated by this analysis (all uncommitted; no functional RTL,
C, startup, or linker changes):
`fw/agriasic_fw.{elf,bin,map,dis,elf-fw.su,memory.json,memory.txt}`,
`memory/results/{accesses.csv,address_summary.json,simulation.log}`.

---

## Addendum — after the Ibex core swap

The analysis above was performed on the Penn CIS 5710 core. The control core
was subsequently replaced by lowRISC Ibex (see `../README.md`, "Processor
provenance"). Re-running the same build and audit flow on the Ibex firmware:

| Quantity | Penn core | Ibex core |
|---|---|---|
| `.text` (only allocated section) | 384 B | **434 B** (109 words); `-march=rv32imc_zicsr` |
| Layout | code from 0x0 | vector table `0x00–0x7F` (128 B, never fetched unless a trap occurs), `_start` at `0x80`, `run_sweep_point` `0xB4`, `main` `0x11A–0x1B1` |
| Highest linked byte | `0x17F` | **`0x1B1`** (2-byte aligned; C extension) |
| Fetch span observed | `0x000–0x187` | **`0x080–0x1BB`** (prefetch lookahead of up to 3 words past the image) |
| Highest retired instruction | `0x17C` | **`0x1B0`** |
| `main` stack frame / max stack | 32 B / 32 B | 32 B / 32 B (unchanged; `-fstack-usage`) |
| Result buffers | `0x100–0x143`, 48 B | identical |
| Stack bytes touched | `0x7E8–0x7FF` | identical |
| MMIO accesses | 8 words, 20 W / 18 R | identical + 1 extra CTRL write (`FW_DONE`) |
| Out-of-map accesses | none | none (and now a bus-error trap would fire in silicon) |
| Heap | 0 | 0 |
| Sleep during measurement | `clk_en` low 3,152,726 cycles | `core_sleep_o` high 3,152,721 cycles |
| Generic synthesis (memories blackboxed) | 33,535 comb + 2,800 FF | **16,919 comb + 2,138 FF** (FF regfile; latch regfile for ASIC) |

Sizing conclusions are unchanged: the image still fits a **512 B** IMEM with
the observed lookahead (`0x1BB` < `0x200`), **1 KiB** remains the recommended
ROM with 590 B of headroom, and DMEM requirements are byte-for-byte the same.
Two things did change qualitatively: the trap handler now makes the 256 B
stack reservation a real requirement rather than a hypothetical one, and the
debug-module window at `0x1A11_0000` (reserved, not yet populated) is a third
decoded region on both ports that any future memory map must keep clear.

### Phase 2 (debug module) update

The debug integration changed the **address map**, not the memory sizes:

- DMEM moved from `0x0000_0000` to **`0x0001_0000`** (`agriasic_rv32i_bus.sv`);
  `SP = 0x0001_0800`, results at `0x0001_0100–0x0001_0143`. Re-running the
  audit (`memory/run_sim.sh`, now reporting RAM bytes as offsets from the RAM
  base): results `+0x100–0x143`, stack `+0x7E8–0x7FF`, 68 distinct bytes,
  zero invalid accesses — byte-for-byte the Phase 1 footprint.
- IMEM is now **writable** through the bus (debugger `load`, or the core's own
  data port), so the "synthesized ROM" option for IMEM now competes with "RAM
  loaded over JTAG at bring-up". Code is 482 B (121 words); fetch span
  `0x080–0x1EB`.
- A third decoded region, the debug module at `0x1A11_0000–0x1A11_0FFF`, is
  reachable from both core ports and must stay clear of any future memory.
- Generic synthesis: 25,043 combinational + 3,254 register bits, of which the
  debug module is 1,076 register bits (abstract data, program buffer, SBA,
  DTM) — the price of a standard debug port, independent of memory choices.

### Phase 3 (SPI-flash boot) update

Option C is now implemented (`agriasic_spi_boot.sv`), which settles the
IMEM technology question from §7: **program memory is writable SRAM**, loaded
at reset from external flash (or over JTAG), so the synthesized-ROM option is
retired. Sizing is unchanged — the 484 B image boots in 65.7k cycles at
SCK = clk/16 — but the loader enforces `length <= 4096` (the 4 KiB IMEM); if
IMEM is shrunk to 2 KiB the `IMEM_BYTES` parameter must follow. The loader
adds 342 register bits (header, CRC, byte/word staging, SPI engine) and no
memory of its own. DMEM is untouched.

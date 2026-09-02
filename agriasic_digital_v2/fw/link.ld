/*
 * Linker script for AgriASIC RV32I control firmware.
 *
 * IMPORTANT -- Harvard split:
 *   The instruction ROM (agriasic_imem) and data RAM (agriasic_dmem) are
 *   SEPARATE address spaces on separate ports. Anything the linker places in
 *   ROM is reachable only by instruction fetch, never by a load. So .rodata,
 *   .data and .sdata must all be empty: no string literals, no lookup tables,
 *   no initialized globals. Keep constants as immediates and state on the stack.
 *
 *   The ASSERTs below turn that constraint into a build error instead of a
 *   silent read of garbage at run time.
 */

MEMORY
{
    ROM : ORIGIN = 0x00000000, LENGTH = 4K   /* agriasic_imem, 1024 words */
}

SECTIONS
{
    .text : {
        *(.start*)
        *(.text*)
    } > ROM

    .rodata : { *(.rodata*) *(.srodata*) } > ROM
    .data   : { *(.data*)   *(.sdata*)   } > ROM
    .bss    : { *(.bss*)    *(.sbss*)    } > ROM

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) }
}

ASSERT(SIZEOF(.rodata) == 0,
  "Harvard split: .rodata is non-empty and would be unreachable from the data port")
ASSERT(SIZEOF(.data) == 0,
  "Harvard split: .data is non-empty and would be unreachable from the data port")
ASSERT(SIZEOF(.bss) == 0,
  "Harvard split: .bss is non-empty; it lives in RAM and needs runtime zeroing")

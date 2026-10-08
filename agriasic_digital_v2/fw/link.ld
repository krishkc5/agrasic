/*
 * Linker script for AgriASIC RV32I control firmware (Ibex core).
 *
 * IMPORTANT -- Harvard split:
 *   The instruction memory (agriasic_imem) and data RAM (agriasic_dmem) are
 *   separate single-port memories. Since Phase 2 the bus CAN route a core
 *   data-port read to the instruction memory, but this firmware still keeps
 *   .rodata, .data and .sdata empty (no string literals, no lookup tables, no
 *   initialized globals): constants stay immediates and state stays on the
 *   stack, so no startup copy/zero code is needed. Relax the ASSERTs when
 *   that changes.
 *
 *   The ASSERTs below turn that constraint into a build error instead of a
 *   silent read of garbage at run time.
 *
 * Ibex boot layout (boot_addr_i = 0):
 *   0x00-0x7F  .vectors  32-entry trap vector table (mtvec = 0, vectored)
 *   0x80       .start    reset entry
 */

MEMORY
{
    ROM : ORIGIN = 0x00000000, LENGTH = 1K   /* agriasic_imem, 256 words    */
    RAM : ORIGIN = 0x00010000, LENGTH = 512  /* agriasic_dmem, 128 words    */
    /* Phase 2 flat map (agriasic_rv32i_bus.sv). RAM is documented here so a
       debugger and future .data/.bss placement see one consistent picture;
       nothing is placed in it by this script today (Harvard ASSERTs below).
       Also present on the bus: DM 0x1A110000 (debug module), MMIO 0x80000000. */
}

SECTIONS
{
    .text : {
        KEEP(*(.vectors))
        . = 0x80;                /* Ibex reset PC = boot_addr_i + 0x80 */
        *(.start*)
        *(.text*)
    } > ROM

    .rodata : { *(.rodata*) *(.srodata*) } > ROM
    .data   : { *(.data*)   *(.sdata*)   } > ROM
    .bss    : { *(.bss*)    *(.sbss*)    } > ROM

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) }
}

ASSERT(_vectors == 0x0,
  "Ibex boot: vector table must sit at boot_addr_i (0x0)")
ASSERT(_start == 0x80,
  "Ibex boot: _start must sit at boot_addr_i + 0x80")
ASSERT(SIZEOF(.rodata) == 0,
  "Harvard split: .rodata is non-empty and would be unreachable from the data port")
ASSERT(SIZEOF(.data) == 0,
  "Harvard split: .data is non-empty and would be unreachable from the data port")
ASSERT(SIZEOF(.bss) == 0,
  "Harvard split: .bss is non-empty; it lives in RAM and needs runtime zeroing")

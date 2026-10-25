/*
 * Reset entry and trap vectors for the AgriASIC Ibex control core.
 *
 * Ibex boot convention (boot_addr_i = 0 in the shell):
 *   0x00 - 0x7F : 32-entry trap vector table; mtvec = boot_addr_i (vectored).
 *                 Exceptions use entry 0, interrupt id i uses entry i,
 *                 NMI uses entry 31.
 *   0x80        : reset entry (_start).
 *
 * The shell holds the core in reset until start_i is asserted, so execution
 * always begins at _start with a clean register file.
 *
 * Sleep/wake contract with the shell (see agriasic_rv32i_control_shell.sv):
 *   mie.fast0 (bit 16) is set so wfi wakes when the measurement DONE latch
 *   goes pending; mstatus.MIE stays clear so no interrupt is ever TAKEN --
 *   the core just resumes after the wfi. Nothing here is cycle-accurate.
 */

    /* ---- Trap vector table: must be exactly 128 bytes, 4 bytes per entry.
       C is enabled in the toolchain, so force 32-bit encodings here. ---- */
    .section .vectors, "ax"
    .option push
    .option norvc
    .global _vectors
_vectors:
    .rept 32
    j       trap_handler
    .endr
    .option pop

    /* ---- Reset entry at 0x80 ---- */
    .section .start, "ax"
    .global _start
_start:
    /* Stack lives at the top of the scratch RAM and grows down. _stack_top
       comes from link.ld (ORIGIN(RAM) + LENGTH(RAM)), so the RAM size is
       stated in exactly one place; this used to be the literal 0x00010200,
       which silently went stale whenever the RAM was resized. RAM moved off 0
       in Phase 2 so a debugger's single address space does not overlap the
       program memory at 0. See agriasic_rv32i_bus.sv. */
    la      sp, _stack_top

    /* Enable fast interrupt 0 (measurement DONE) as a wfi wake source. */
    li      t0, (1 << 16)
    csrw    mie, t0

    call    main

    /* Firmware finished: raise CTRL.FW_DONE (sticky), which the shell exposes
       as done_o, then park. The previous core used ecall for this; on Ibex
       ecall is a trap. */
    li      t0, 0x80000000
    li      t1, (1 << 8)
    sw      t1, 0(t0)
park:
    wfi
    j       park

    /* ---- Trap handler: any exception lands here (vector entry 0).
       Record it host-visibly via CTRL.TRAP_SEEN and park. No recovery is
       attempted; a trap in this firmware is a bug or a bus error. ---- */
    .global trap_handler
trap_handler:
    li      t0, 0x80000000
    li      t1, (1 << 9)
    sw      t1, 0(t0)
trap_park:
    wfi
    j       trap_park

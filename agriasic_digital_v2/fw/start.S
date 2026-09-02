/*
 * Reset entry for the AgriASIC RV32I control core.
 *
 * The shell holds the core in reset until start_i is asserted, so execution
 * always begins here at PC 0 with a clean register file.
 */
    .section .start, "ax"
    .global _start
_start:
    /* Stack lives at the top of the 2 KB scratch RAM and grows down.
       This is the DATA address space, distinct from the ROM this code is in. */
    li      sp, 0x800

    call    main

    /* ecall drives the core's halt output, which the shell exposes as done_o. */
halt:
    ecall
    j       halt

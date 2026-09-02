/*
 * AgriASIC RV32I control firmware.
 *
 * This is the POLICY layer. It decides when to measure, with what
 * configuration, and what to do with the results. It contains no cycle-accurate
 * timing: excitation polarity, settle qualification, conversion trigger and
 * accumulation all stay in the measurement FSM, so the sample instant has no
 * software-induced jitter and the +/- chop stays time-symmetric.
 *
 * Harvard-split constraint (see link.ld): no .rodata, .data or .bss. All
 * constants are immediates; all state is on the stack.
 */

#define PERIPH_BASE   0x80000000u
#define REG(off)      (*(volatile int *)(PERIPH_BASE + (off)))

#define REG_CTRL      REG(0x00)   /* W  bit0 = start, bit7 = clear errors */
#define REG_PAIR_LOG2 REG(0x04)   /* RW */
#define REG_SETTLE    REG(0x08)   /* RW */
#define REG_DIVIDER   REG(0x0C)   /* RW */
#define REG_CONV      REG(0x10)   /* RW */
#define REG_STATUS    REG(0x14)   /* R   bit0 = busy, bit1 = done */
#define REG_RESULT    REG(0x18)   /* R   sign-extended 16-bit accumulator */

#define CTRL_START      (1 << 0)
#define CTRL_CLEAR_ERR  (1 << 7)
#define STATUS_BUSY     (1 << 0)
#define STATUS_DONE     (1 << 1)

/* Scratch RAM locations the testbench can inspect. Data address space.
 *
 * Deliberately NOT at address 0: the compiler treats address 0 as NULL and is
 * entitled to assume a null dereference is undefined, which lets it discard
 * these stores. 0x100 is a valid RAM address well below the stack at 0x800. */
#define OUT_AVERAGE   (*(volatile int *)0x00000100)
#define OUT_COUNT     (*(volatile int *)0x00000104)
#define OUT_SAMPLES   ((volatile int *)0x00000110)

#define NUM_MEASUREMENTS 4

/*
 * Run one measurement and return the accumulated result.
 *
 * Polls BUSY rather than DONE. The FSM's raw done_o is a single-cycle pulse;
 * the shell latches both flags so either is safe to poll, but BUSY going low is
 * the more natural completion condition.
 */
static int run_one_measurement(void)
{
    REG_CTRL = CTRL_START;

    while (REG_STATUS & STATUS_BUSY) {
        /* spin */
    }

    return REG_RESULT;
}

int main(void)
{
    int acc = 0;
    int i;

    /* Clear any sticky protocol errors left over from the host interface. */
    REG_CTRL = CTRL_CLEAR_ERR;

    /* Measurement configuration. These are the knobs the FSM exposes; changing
       them here is exactly the post-silicon flexibility the hardware already
       provides, without moving timing into software. */
    REG_PAIR_LOG2 = 2;   /* 2^2 = 4 sample pairs per measurement */
    REG_SETTLE    = 2;   /* settle ticks after each polarity flip */
    REG_DIVIDER   = 0;   /* settle tick = core clock */
    REG_CONV      = 1;   /* SAR conversion latency in cycles */

    /* Take several measurements and average them. Averaging across runs is the
       kind of work that belongs in software: it needs no cycle accuracy and
       benefits from being changeable. */
    for (i = 0; i < NUM_MEASUREMENTS; i++) {
        int sample = run_one_measurement();
        OUT_SAMPLES[i] = sample;
        acc += sample;
    }

    OUT_AVERAGE = acc / NUM_MEASUREMENTS;
    OUT_COUNT   = NUM_MEASUREMENTS;

    return 0;
}

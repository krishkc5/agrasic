/*
 * AgriASIC RV32I control firmware.
 *
 * This is the POLICY layer. It decides when to measure, with what
 * configuration, and what to do with the results. It contains no cycle-accurate
 * timing: excitation polarity, settle qualification, conversion trigger and
 * accumulation all stay in the measurement FSM, so the sample instant has no
 * software-induced jitter and the +/- chop stays time-symmetric.
 *
 * Rev 4.3 Phase 7 -- frequency sweep:
 *   Sweeps the three real excitation points (10 MHz / 100 kHz / 1 kHz --
 *   f_exc = f_clk/(16*N) at f_clk=160 MHz gives N=1/100/10000 exactly, the
 *   same three presets REG_FREQ_SEL exposes as a selector on the SPI and
 *   parallel programming interfaces). This firmware writes N directly to
 *   REG_DIVIDER because MMIO has no byte-width constraint forcing a
 *   selector encoding (see the MAS section 7.1 note on why SPI and MMIO
 *   deliberately use different registers for this). Each point is averaged
 *   over NUM_MEASUREMENTS runs and stored per-point in scratch RAM.
 *
 *   Settle_cycles_i counts excitation PERIODS, not raw cycles (Phase 4), so
 *   REG_SETTLE=2 means the same *proportional* settle time at every
 *   frequency point without needing per-point tuning here.
 *
 *   Temperature read (Phase 7.3) is NOT implemented: no PTAT/ADC-test-mux
 *   interface exists anywhere in the digital RTL yet -- this is an analog
 *   dependency (Krishna/Vidhu's side), not a firmware gap. OUT_TEMP is
 *   written with a sentinel so nothing downstream mistakes an unread value
 *   for a real reading.
 *
 *   Known architecture gap (MAS GAP-11, found while implementing this):
 *   these results land only in scratch RAM, inspectable in simulation but
 *   not reachable by any real external host today. agriasic_digital_rv32i_top
 *   has no SPI (or any other) host-facing interface at all, and
 *   agriasic_digital_spi_top has no RV32I core -- the two integrations are
 *   separate top-level modules, never composed. Phase 6's indexed SPI
 *   readout and this sweep therefore do not connect to each other on any
 *   chip variant that exists in this tree yet.
 *
 * Harvard-split constraint (see link.ld): no .rodata, .data or .bss. All
 * constants are immediates; all state is on the stack.
 */

#define PERIPH_BASE   0x80000000u
#define REG(off)      (*(volatile int *)(PERIPH_BASE + (off)))

#define REG_CTRL      REG(0x00)   /* W  bit0 = start, bit7 = clear errors */
#define REG_PAIR_LOG2 REG(0x04)   /* RW */
#define REG_SETTLE    REG(0x08)   /* RW */
#define REG_DIVIDER   REG(0x0C)   /* RW  raw N, unlike SPI's selector-based REG_FREQ_SEL */
#define REG_CONV      REG(0x10)   /* RW */
#define REG_STATUS    REG(0x14)   /* R   bit0 = busy, bit1 = done */
#define REG_RESULT_I  REG(0x18)   /* R   sign-extended 16-bit I-channel accumulator */
#define REG_RESULT_Q  REG(0x1C)   /* R   sign-extended 16-bit Q-channel accumulator (Rev 4.3 Phase 5) */

#define CTRL_START      (1 << 0)
#define CTRL_CLEAR_ERR  (1 << 7)
#define STATUS_BUSY     (1 << 0)
#define STATUS_DONE     (1 << 1)

/* Scratch RAM locations the testbench can inspect. Data address space.
 *
 * Deliberately NOT at address 0: the compiler treats address 0 as NULL and is
 * entitled to assume a null dereference is undefined, which lets it discard
 * these stores. 0x100 is a valid RAM address well below the stack at 0x800.
 *
 * Rev 4.3 Phase 7 layout (supersedes the Phase 1-6 single-frequency-demo
 * layout: OUT_AVERAGE/OUT_AVERAGE_Q/OUT_SAMPLES/OUT_SAMPLES_Q are retired --
 * a real 3-point sweep replaces the placeholder one-frequency loop those
 * existed to demonstrate). One word of gap is left between arrays. */
#define OUT_COUNT      (*(volatile int *)0x00000100)  /* measurements averaged, per point */
#define OUT_NUM_POINTS (*(volatile int *)0x00000104)  /* frequency points swept (3) */
#define OUT_DIV        ((volatile int *)0x00000110)   /* [3]: divider N used per point */
#define OUT_I          ((volatile int *)0x00000120)   /* [3]: I average per point */
#define OUT_Q          ((volatile int *)0x00000130)   /* [3]: Q average per point */
#define OUT_TEMP       (*(volatile int *)0x00000140)  /* sentinel -1: not implemented, see header (GAP-11) */

#define NUM_FREQ_POINTS  3
#define NUM_MEASUREMENTS 2   /* averaged per frequency point */

/*
 * Run one measurement and return both accumulated results (I and Q,
 * Rev 4.3 Phase 5) via the output pointers.
 *
 * Polls BUSY rather than DONE. The FSM's raw done_o is a single-cycle pulse;
 * the shell latches both flags so either is safe to poll, but BUSY going low is
 * the more natural completion condition.
 */
static void run_one_measurement(int *out_i, int *out_q)
{
    REG_CTRL = CTRL_START;

    while (REG_STATUS & STATUS_BUSY) {
        /* spin */
    }

    *out_i = REG_RESULT_I;
    *out_q = REG_RESULT_Q;
}

/*
 * Configure the excitation divider for one sweep point, run
 * NUM_MEASUREMENTS measurements at it, and average the I/Q results.
 * Averaging across runs is software's job: no cycle accuracy needed, and
 * it stays changeable without touching the FSM.
 */
static void run_sweep_point(int divider_n, int *out_i, int *out_q)
{
    int acc_i = 0;
    int acc_q = 0;
    int i;

    REG_DIVIDER = divider_n;

    for (i = 0; i < NUM_MEASUREMENTS; i++) {
        int sample_i, sample_q;
        run_one_measurement(&sample_i, &sample_q);
        acc_i += sample_i;
        acc_q += sample_q;
    }

    *out_i = acc_i / NUM_MEASUREMENTS;
    *out_q = acc_q / NUM_MEASUREMENTS;
}

int main(void)
{
    int i, q;

    /* Clear any sticky protocol errors left over from the host interface. */
    REG_CTRL = CTRL_CLEAR_ERR;

    /* Measurement configuration shared across all sweep points. These are
       the knobs the FSM exposes; changing them here is exactly the
       post-silicon flexibility the hardware already provides, without
       moving timing into software. */
    REG_PAIR_LOG2 = 2;   /* 2^2 = 4 sample pairs per measurement */
    REG_SETTLE    = 2;   /* settle periods after start/freq change (Rev 4.3 Phase 4) */
    REG_CONV      = 1;   /* SAR conversion latency in cycles */

    /* Point 0: 10 MHz (N=1). */
    run_sweep_point(1, &i, &q);
    OUT_DIV[0] = 1;
    OUT_I[0]   = i;
    OUT_Q[0]   = q;

    /* Point 1: 100 kHz (N=100). */
    run_sweep_point(100, &i, &q);
    OUT_DIV[1] = 100;
    OUT_I[1]   = i;
    OUT_Q[1]   = q;

    /* Point 2: 1 kHz (N=10000) -- the point carrying most of the ionic
       (nutrient/salt) information, unreachable before Phase 4/6 widened the
       divider path end to end. */
    run_sweep_point(10000, &i, &q);
    OUT_DIV[2] = 10000;
    OUT_I[2]   = i;
    OUT_Q[2]   = q;

    /* Phase 7.3, not implemented -- see header. */
    OUT_TEMP = -1;

    OUT_COUNT      = NUM_MEASUREMENTS;
    OUT_NUM_POINTS = NUM_FREQ_POINTS;

    return 0;
}

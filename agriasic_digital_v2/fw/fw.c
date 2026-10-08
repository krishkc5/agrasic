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
 *   Rev 5: the front end is tetrapolar, so every measurement returns TWO
 *   complex results -- the differential voltage across the inner electrodes
 *   and the current returning through the outer one. This firmware stores
 *   both per frequency point; the host divides them to get impedance.
 *
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
 *
 * Ibex core (replaces the Penn CIS 5710 core): the wait for a measurement is
 * now a wfi. start.S enables mie.fast0 and the shell feeds the DONE latch to
 * irq_fast[0]; mstatus.MIE is never set, so wfi simply returns when DONE is
 * pending and no interrupt is taken. The BUSY poll is kept after the wfi as
 * a guard (it costs one load in the normal case) so the sequence is correct
 * even if wfi is a no-op, e.g. under a debugger with single-step enabled.
 * Completion is signalled by start.S writing CTRL.FW_DONE, not by ecall.
 */

#define PERIPH_BASE   0x80000000u
#define REG(off)      (*(volatile int *)(PERIPH_BASE + (off)))

#define REG_CTRL      REG(0x00)   /* W  bit0 = start, bit7 = clear errors, bit8 = fw_done, bit9 = trap_seen */
#define REG_PAIR_LOG2 REG(0x04)   /* RW */
#define REG_SETTLE    REG(0x08)   /* RW */
#define REG_DIVIDER   REG(0x0C)   /* RW  raw N, unlike SPI's selector-based REG_FREQ_SEL */
#define REG_CONV      REG(0x10)   /* RW */
#define REG_STATUS    REG(0x14)   /* R   bit0 = busy, bit1 = done, bit4 = overrange, bit5 = trap_seen, bit6 = fw_done */
#define REG_RESULT_I  REG(0x18)   /* R   sign-extended dV in-phase accumulator */
#define REG_RESULT_Q  REG(0x1C)   /* R   sign-extended dV quadrature accumulator */
/* Rev 5 tetrapolar front end: the return-current channel is a second complex
   pair. Impedance is their ratio, Z(f) = dV(f) / I(f) -- computed host-side,
   not here (no floating point, and the host already does magnitude/phase). */
#define REG_RESULT_CUR_I REG(0x34) /* R   sign-extended current in-phase accumulator */
#define REG_RESULT_CUR_Q REG(0x38) /* R   sign-extended current quadrature accumulator */
#define REG_AFE_CTRL     REG(0x3C) /* RW  [1:0] pga_gain, [3:2] tia_rf, [5:4] amplitude, [15:8] mux_settle */

#define CTRL_START      (1 << 0)
#define CTRL_CLEAR_ERR  (1 << 7)
#define STATUS_BUSY     (1 << 0)
#define STATUS_DONE     (1 << 1)

/* Scratch RAM locations the testbench (and a debugger over JTAG) can inspect.
 *
 * Phase 2 flat map: RAM lives at DMEM_BASE = 0x0001_0000 (2 KiB), so the
 * debugger's single address space has program memory at 0 and RAM at
 * 0x10000 with no overlap. Results sit at DMEM_BASE + 0x100, well below the
 * stack top at DMEM_BASE + 0x200.
 *
 * Rev 4.3 Phase 7 layout (supersedes the Phase 1-6 single-frequency-demo
 * layout: OUT_AVERAGE/OUT_AVERAGE_Q/OUT_SAMPLES/OUT_SAMPLES_Q are retired --
 * a real 3-point sweep replaces the placeholder one-frequency loop those
 * existed to demonstrate). One word of gap is left between arrays. */
#define DMEM_BASE      0x00010000u
#define OUT_COUNT      (*(volatile int *)(DMEM_BASE + 0x100))  /* measurements averaged, per point */
#define OUT_NUM_POINTS (*(volatile int *)(DMEM_BASE + 0x104))  /* frequency points swept (3) */
#define OUT_DIV        ((volatile int *)(DMEM_BASE + 0x110))   /* [3]: divider N used per point */
#define OUT_DV_I       ((volatile int *)(DMEM_BASE + 0x120))   /* [3]: dV in-phase average per point */
#define OUT_DV_Q       ((volatile int *)(DMEM_BASE + 0x130))   /* [3]: dV quadrature average per point */
#define OUT_CUR_I      ((volatile int *)(DMEM_BASE + 0x150))   /* [3]: current in-phase average per point */
#define OUT_CUR_Q      ((volatile int *)(DMEM_BASE + 0x160))   /* [3]: current quadrature average per point */
#define OUT_TEMP       (*(volatile int *)(DMEM_BASE + 0x140))  /* sentinel -1: not implemented, see header (GAP-11) */

#define NUM_FREQ_POINTS  3
#define NUM_MEASUREMENTS 2   /* averaged per frequency point */

/*
 * Run one measurement and return both accumulated results (I and Q,
 * Rev 4.3 Phase 5) via the output pointers.
 *
 * Sleeps in wfi until the DONE latch wakes the core (see the header), then
 * confirms BUSY is low. The FSM's raw done_o is a single-cycle pulse; the
 * bridge latches both flags so either is safe to check.
 */
static inline void wfi(void)
{
    __asm__ volatile ("wfi" ::: "memory");
}

struct iq_pair {
    int dv_i;
    int dv_q;
    int cur_i;
    int cur_q;
};

static void run_one_measurement(struct iq_pair *out)
{
    REG_CTRL = CTRL_START;

    wfi();

    while (REG_STATUS & STATUS_BUSY) {
        /* guard: only spins if wfi returned early */
    }

    out->dv_i  = REG_RESULT_I;
    out->dv_q  = REG_RESULT_Q;
    out->cur_i = REG_RESULT_CUR_I;
    out->cur_q = REG_RESULT_CUR_Q;
}

/*
 * Configure the excitation divider for one sweep point, run
 * NUM_MEASUREMENTS measurements at it, and average the I/Q results.
 * Averaging across runs is software's job: no cycle accuracy needed, and
 * it stays changeable without touching the FSM.
 */
static void run_sweep_point(int divider_n, struct iq_pair *out)
{
    struct iq_pair acc = { 0, 0, 0, 0 };
    int i;

    REG_DIVIDER = divider_n;

    for (i = 0; i < NUM_MEASUREMENTS; i++) {
        struct iq_pair s;
        run_one_measurement(&s);
        acc.dv_i  += s.dv_i;
        acc.dv_q  += s.dv_q;
        acc.cur_i += s.cur_i;
        acc.cur_q += s.cur_q;
    }

    out->dv_i  = acc.dv_i  / NUM_MEASUREMENTS;
    out->dv_q  = acc.dv_q  / NUM_MEASUREMENTS;
    out->cur_i = acc.cur_i / NUM_MEASUREMENTS;
    out->cur_q = acc.cur_q / NUM_MEASUREMENTS;
}

static void store_point(int point, int divider_n, const struct iq_pair *r)
{
    OUT_DIV[point]    = divider_n;
    OUT_DV_I[point]   = r->dv_i;
    OUT_DV_Q[point]   = r->dv_q;
    OUT_CUR_I[point]  = r->cur_i;
    OUT_CUR_Q[point]  = r->cur_q;
}

int main(void)
{
    struct iq_pair r;

    /* Clear any sticky protocol errors left over from the host interface. */
    REG_CTRL = CTRL_CLEAR_ERR;

    /* Measurement configuration shared across all sweep points. These are
       the knobs the FSM exposes; changing them here is exactly the
       post-silicon flexibility the hardware already provides, without
       moving timing into software. */
    REG_PAIR_LOG2 = 2;   /* 2^2 = 4 sample pairs per measurement */
    REG_SETTLE    = 2;   /* settle periods after start/freq change (Rev 4.3 Phase 4) */
    REG_CONV      = 1;   /* SAR conversion latency in cycles */

    /* Rev 5 analog front end: lowest PGA gain and TIA transimpedance, full
       sine amplitude, 2 cycles of mux/S-H settling. These are the bring-up
       defaults the bridge already resets to; written explicitly so the
       firmware's assumption is visible rather than inherited. */
    REG_AFE_CTRL  = (2 << 8) | (0 << 4) | (0 << 2) | 0;

    /* Point 0: 10 MHz (N=1). */
    run_sweep_point(1, &r);
    store_point(0, 1, &r);

    /* Point 1: 100 kHz (N=100). */
    run_sweep_point(100, &r);
    store_point(1, 100, &r);

    /* Point 2: 1 kHz (N=10000) -- the point carrying most of the ionic
       (nutrient/salt) information, unreachable before Phase 4/6 widened the
       divider path end to end. */
    run_sweep_point(10000, &r);
    store_point(2, 10000, &r);

    /* Phase 7.3, not implemented -- see header. */
    OUT_TEMP = -1;

    OUT_COUNT      = NUM_MEASUREMENTS;
    OUT_NUM_POINTS = NUM_FREQ_POINTS;

    return 0;
}

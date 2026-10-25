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

#define REG_CTRL      REG(0x00)   /* W  bit0 = start (rejected while busy -- write bit1 abort
                                   *       first to restart early; firmware never needs to,
                                   *       it starts one run and sleeps until that run ends),
                                   *    bit1 = abort, bit7 = clear errors,
                                   *    bit8 = fw_done, bit9 = trap_seen */
#define REG_PAIR_LOG2 REG(0x04)   /* RW */
#define REG_SETTLE    REG(0x08)   /* RW */
#define REG_DIVIDER   REG(0x0C)   /* RW  raw N, unlike SPI's selector-based REG_FREQ_SEL */
#define REG_CONV      REG(0x10)   /* RW */
#define REG_STATUS    REG(0x14)   /* R   bit0 = busy, bit1 = done, bit2/3 = ADC overrange dV/current,
                                   *     bit4 = pair-count guard, bit5 = trap_seen, bit6 = fw_done,
                                   *     bit7 = a START was written while busy and discarded (sticky) */
#define REG_RESULT_I  REG(0x18)   /* R   sign-extended dV in-phase accumulator */
#define REG_RESULT_Q  REG(0x1C)   /* R   sign-extended dV quadrature accumulator */
/* Rev 5 tetrapolar front end: the return-current channel is a second complex
   pair. Impedance is their ratio, Z(f) = dV(f) / I(f) -- computed host-side,
   not here (no floating point, and the host already does magnitude/phase). */
#define REG_RESULT_CUR_I REG(0x34) /* R   sign-extended current in-phase accumulator */
#define REG_RESULT_CUR_Q REG(0x38) /* R   sign-extended current quadrature accumulator */
#define REG_AFE_CTRL     REG(0x3C) /* RW  [1:0] reserved (PGA gain is fixed in analog),
                                    *     [3:2] tia_rf, [5:4] amplitude, [15:8] mux_settle */

#define CTRL_START      (1 << 0)
#define CTRL_ABORT      (1 << 1)
#define CTRL_CLEAR_ERR  (1 << 7)
#define STATUS_BUSY     (1 << 0)
#define STATUS_DONE     (1 << 1)
#define STATUS_ABORTED  (1 << 8)

/* Scratch RAM locations the testbench (and a debugger over JTAG) can inspect.
 *
 * Phase 2 flat map: RAM lives at DMEM_BASE = 0x0001_0000, so the debugger's
 * single address space has program memory at 0 and RAM at 0x10000 with no
 * overlap.
 *
 * RAM is 384 B / 96 words (DMEM_WORDS in agriasic_rv32i_control_shell.sv,
 * LENGTH in link.ld). Comments here used to say 2 KiB; that was the bus
 * WINDOW, never the memory.
 *
 * Layout, sized for OUT_MAX_POINTS sweep points:
 *
 *   0x000  OUT_COUNT
 *   0x004  OUT_NUM_POINTS
 *   0x008  OUT_TEMP
 *   0x00C  (reserved, 5 words -- room for scalars without moving the arrays)
 *   0x020  OUT_DIV    [8]
 *   0x040  OUT_DV_I   [8]
 *   0x060  OUT_DV_Q   [8]
 *   0x080  OUT_CUR_I  [8]
 *   0x0A0  OUT_CUR_Q  [8]
 *   0x0C0  OUT_AFE    [8]
 *   0x0E0  end of results
 *   ....   28-word guard
 *   0x150  stack grows down from _stack_top = 0x180 (main's frame is 48 B)
 *
 * The old layout packed the arrays 0x10 apart, i.e. FOUR words each, while
 * advertising "[3]". At five points OUT_DIV[4] would have landed on
 * OUT_DV_I[0] -- silent corruption, no trap, no warning, just wrong results.
 * Arrays are now a full OUT_MAX_POINTS apart and the static assertions below
 * turn both overflow modes into build errors. Do NOT raise NUM_FREQ_POINTS
 * past OUT_MAX_POINTS without widening the stride.
 *
 * (Supersedes the Phase 1-6 single-frequency-demo layout: OUT_AVERAGE/
 * OUT_AVERAGE_Q/OUT_SAMPLES/OUT_SAMPLES_Q are retired.) */
#define DMEM_BASE        0x00010000u
#define DMEM_WORDS       96      /* == DMEM_WORDS in agriasic_rv32i_control_shell.sv */
#define DMEM_BYTES       (DMEM_WORDS * 4)
#define STACK_RESERVE    64      /* main's frame is 48 B per fw.su; rounded up */

#define OUT_MAX_POINTS   8       /* per-array stride, in words */
#define OUT_ARRAY_BASE   0x020u
#define OUT_NUM_ARRAYS   6       /* DIV, DV_I, DV_Q, CUR_I, CUR_Q, AFE */
#define OUT_END          (OUT_ARRAY_BASE + OUT_NUM_ARRAYS * OUT_MAX_POINTS * 4)

#define OUT_COUNT      (*(volatile int *)(DMEM_BASE + 0x000))  /* measurements averaged, per point */
#define OUT_NUM_POINTS (*(volatile int *)(DMEM_BASE + 0x004))  /* frequency points actually swept */
#define OUT_TEMP       (*(volatile int *)(DMEM_BASE + 0x008))  /* sentinel -1: not implemented (GAP-11) */
#define OUT_DIV        ((volatile int *)(DMEM_BASE + 0x020))   /* [8]: divider N used per point */
#define OUT_DV_I       ((volatile int *)(DMEM_BASE + 0x040))   /* [8]: dV in-phase average per point */
#define OUT_DV_Q       ((volatile int *)(DMEM_BASE + 0x060))   /* [8]: dV quadrature average per point */
#define OUT_CUR_I      ((volatile int *)(DMEM_BASE + 0x080))   /* [8]: current in-phase average per point */
#define OUT_CUR_Q      ((volatile int *)(DMEM_BASE + 0x0A0))   /* [8]: current quadrature average per point */
/* [3]: the analog conditions each point was measured under.
 *   [15:0]  AFE_CTRL as it stood (tia_rf, amplitude, mux_settle)
 *   [17:16] ADC overrange, bit16 = dV channel, bit17 = current channel
 * A host CANNOT compute Z = dV / I without this: the two channels have
 * independent gains, so the gains do not cancel in the ratio. Storing it
 * per point also keeps auto-ranging honest if gain ever varies by point. */
#define OUT_AFE        ((volatile int *)(DMEM_BASE + 0x0C0))   /* [8]: AFE_CTRL + overrange bits per point */

#define NUM_FREQ_POINTS  8
/* Build-time guards on the result map. These are the two ways it can go wrong,
 * and both used to be silent:
 *
 *   1. more sweep points than the per-array stride -> each array overruns into
 *      the next and every result after the first array is garbage. No trap, no
 *      warning. This is what the old 4-word stride would have done at 5 points.
 *   2. the result block plus the stack exceeding RAM -> the stack grows down
 *      into the results, or a store lands outside the RAM and the bridge
 *      returns data_err (which does at least trap, via STATUS.TRAP_SEEN).
 *
 * Raising NUM_FREQ_POINTS past OUT_MAX_POINTS is now a compile error, not a
 * debugging session. */
_Static_assert(NUM_FREQ_POINTS <= OUT_MAX_POINTS,
               "NUM_FREQ_POINTS exceeds the per-array stride OUT_MAX_POINTS: "
               "the result arrays would overlap. Widen the stride and the map.");
_Static_assert(OUT_END + STACK_RESERVE <= DMEM_BYTES,
               "result block plus stack reserve does not fit in DMEM: "
               "shrink the map or raise DMEM_WORDS here and in the RTL shell.");
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

/*
 * Returns 1 if a fresh result was produced, 0 if a host abort cut the run
 * short. The distinction matters: an abort deliberately emits no done pulse
 * and does NOT snapshot the accumulators, so the shadow registers still hold
 * the PREVIOUS measurement. Reading them here would average a stale point
 * into this one. The abort still wakes us -- the wake source is done OR
 * aborted -- which is why the check is on ABORTED and not on a timeout.
 */
static int run_one_measurement(struct iq_pair *out)
{
    REG_CTRL = CTRL_START;

    wfi();

    while (REG_STATUS & STATUS_BUSY) {
        /* guard: only spins if wfi returned early */
    }

    if (REG_STATUS & STATUS_ABORTED) {
        return 0;
    }

    out->dv_i  = REG_RESULT_I;
    out->dv_q  = REG_RESULT_Q;
    out->cur_i = REG_RESULT_CUR_I;
    out->cur_q = REG_RESULT_CUR_Q;
    return 1;
}

/*
 * Configure the excitation divider for one sweep point, run
 * NUM_MEASUREMENTS measurements at it, and average the I/Q results.
 * Averaging across runs is software's job: no cycle accuracy needed, and
 * it stays changeable without touching the FSM.
 */
static int run_sweep_point(int divider_n, struct iq_pair *out)
{
    struct iq_pair acc = { 0, 0, 0, 0 };
    int i;

    REG_DIVIDER = divider_n;

    for (i = 0; i < NUM_MEASUREMENTS; i++) {
        struct iq_pair s;
        if (!run_one_measurement(&s)) {
            return 0;       /* abandon the point: a partial average is worse
                               than no point at all, since the host cannot
                               tell how many runs went into it */
        }
        acc.dv_i  += s.dv_i;
        acc.dv_q  += s.dv_q;
        acc.cur_i += s.cur_i;
        acc.cur_q += s.cur_q;
    }

    out->dv_i  = acc.dv_i  / NUM_MEASUREMENTS;
    out->dv_q  = acc.dv_q  / NUM_MEASUREMENTS;
    out->cur_i = acc.cur_i / NUM_MEASUREMENTS;
    out->cur_q = acc.cur_q / NUM_MEASUREMENTS;
    return 1;
}

/*
 * Divider for each sweep point. f_exc = f_clk / (16 * N) = 10 MHz / N.
 *
 * Half-decade (sqrt(10)) log ladder covering 1 kHz to 1 MHz, plus a 10 MHz
 * anchor. LOG spacing, not uniform in Hz: a dielectric dispersion is a feature
 * in log frequency, so uniform spacing would crowd the top decade and leave
 * the bottom -- where the ionic/nutrient information sits -- with almost no
 * resolution. Three points could not locate a dispersion at all; they could
 * only sample it.
 *
 * Ordered cheapest (highest frequency) first. Run time is nearly linear in N,
 * so this maximises the number of points already stored if a host abort cuts
 * the sweep short.
 *
 * Cost: sum(N) = 14621 against the old 3-point sweep's 10101, so eight points
 * take about 1.45x the time, not 2.7x -- the 1 kHz point dominated the old
 * sweep as well. Measured 3-point sweep was ~3.16 Mcycles; this is ~4.6 M.
 *
 * Immediates and an if-chain rather than a lookup table or a switch: link.ld
 * ASSERTs that .rodata stays empty (Harvard split, no startup copy), and a
 * const array -- or a switch that the compiler lowers to a jump table -- would
 * be a deliberate build error.
 *
 * To re-band the sweep, change ONLY this function. If you need more than
 * OUT_MAX_POINTS points, widen the result-array stride in the map above too;
 * the _Static_assert on NUM_FREQ_POINTS enforces that.
 */
static int sweep_divider(int point)
{
    if (point == 0) return 1;       /*  10    MHz */
    if (point == 1) return 10;      /*   1    MHz */
    if (point == 2) return 32;      /* 312.5  kHz */
    if (point == 3) return 100;     /* 100    kHz */
    if (point == 4) return 316;     /*  31.6  kHz */
    if (point == 5) return 1000;    /*  10    kHz */
    if (point == 6) return 3162;    /*   3.16 kHz */
    return 10000;                   /*   1    kHz -- carries most of the ionic
                                       (nutrient/salt) information, and was
                                       unreachable before Phase 4/6 widened
                                       the divider path end to end */
}

static void store_point(int point, int divider_n, const struct iq_pair *r)
{
    OUT_DIV[point]    = divider_n;
    OUT_AFE[point]    = (int)(REG_AFE_CTRL & 0xFFFF) |
                        (int)((REG_STATUS & 0x0000000C) << 14);
    OUT_DV_I[point]   = r->dv_i;
    OUT_DV_Q[point]   = r->dv_q;
    OUT_CUR_I[point]  = r->cur_i;
    OUT_CUR_Q[point]  = r->cur_q;
}

int main(void)
{
    struct iq_pair r;
    int points_done;

    /* Start from a known engine state, not just clean flags.
     *
     * A core reset (gpio_start_i dropped, or a debugger's ndmreset) does NOT
     * reset the measurement engine or the bridge's run state -- the bridge
     * deliberately survives a core reset so a debugger can still read results,
     * and run_clear_i only clears the firmware-owned FW_DONE/TRAP_SEEN bits.
     * So this firmware can start up with a measurement still in flight from
     * its previous incarnation. Without the abort, our first CTRL.START would
     * be rejected as busy, we would sleep, and we would then wake on the OLD
     * run's done and store a result measured under the previous configuration
     * as point 0.
     *
     * ABORT forces the engine to S_IDLE and clears busy; CLEAR_ERR drops the
     * sticky flags, including the ABORTED bit this very write sets. On a cold
     * boot both are no-ops. */
    REG_CTRL = CTRL_ABORT | CTRL_CLEAR_ERR;

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

    /* Sweep the frequency points, stopping early if a host abort cuts a run
       short. Stopping rather than continuing is deliberate: an abort is a
       host command to stand down, so the right response is to report how far
       the sweep got and let the host decide. */
    for (points_done = 0; points_done < NUM_FREQ_POINTS; points_done++) {
        int divider_n = sweep_divider(points_done);

        if (!run_sweep_point(divider_n, &r)) {
            break;
        }
        store_point(points_done, divider_n, &r);
    }

    /* Phase 7.3, not implemented -- see header. */
    OUT_TEMP = -1;

    OUT_COUNT      = NUM_MEASUREMENTS;
    /* Points actually completed, not the constant NUM_FREQ_POINTS: this is
       how a host sees that a sweep was aborted part way through. Equal to
       NUM_FREQ_POINTS on an uninterrupted sweep. */
    OUT_NUM_POINTS = points_done;

    /* Drop the sticky ABORTED bit before parking. It feeds the
       level-sensitive wake, so leaving it set would keep the final wfi in
       start.S from ever actually sleeping. */
    REG_CTRL = CTRL_CLEAR_ERR;

    return 0;
}

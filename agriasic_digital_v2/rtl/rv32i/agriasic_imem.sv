// -----------------------------------------------------------------------------
// Module: agriasic_imem
// Purpose:
//   Instruction memory wrapper presenting the timing contract of a real
//   foundry single-port synchronous SRAM macro to the core.
//
//   Phase 2 (debug): the memory is now LOADABLE. The single port carries both
//   instruction fetches and programming accesses (writes and read-back) that
//   arrive through agriasic_rv32i_bus from the debug module's system-bus
//   master (OpenOCD `load`) or from the core's own data port. The bus
//   arbitrates so at most one access reaches this port per cycle. Contents
//   are preloaded from INIT_FILE for simulation; on silicon a loader (JTAG,
//   or a future SPI boot path) fills it, or it is implemented as a ROM and the
//   write port is left unconnected.
//
// Timing contract (matches a standard single-port synchronous macro):
//   - Access is captured on the rising edge of clk when ce_i is asserted.
//   - Write cycle  (ce_i && |we_i): byte lanes selected by we_i are written.
//   - Read cycle   (ce_i && !|we_i): dout_o is valid the FOLLOWING cycle.
//   - "No-change" output policy: on a write cycle, and whenever ce_i is low,
//     the output register HOLDS its previous value.
//
// Integration intent:
//   The output register of this macro serves as the fetch data register for
//   the core (Ibex instr_rdata_i with rvalid = registered req). The core must
//   not re-register dout_o.
//
// Macro swap:
//   Define AGRIASIC_USE_SRAM_MACRO and fill in the vendor instance below when
//   memory-compiler output is available. Nothing outside this file changes.
// -----------------------------------------------------------------------------
module agriasic_imem #(
  parameter int unsigned NUM_WORDS = 256,
  parameter string       INIT_FILE = "agriasic_fw.hex"
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ce_i,
  input  logic [3:0]  we_i,     // per-byte write enables (programming port)
  input  logic [31:0] addr_i,   // byte address; [1:0] ignored (4B aligned)
  input  logic [31:0] din_i,
  output logic [31:0] dout_o
);

  localparam int unsigned AddrLsb = 2;
  localparam int unsigned AddrMsb = $clog2(NUM_WORDS) + AddrLsb - 1;

`ifdef AGRIASIC_USE_SRAM_MACRO
  // ---------------------------------------------------------------------------
  // Vendor macro instance goes here. Required behavior:
  //   posedge-capture of address under ce_i, byte write enables, 1-cycle read
  //   latency, output register holds while ce_i is low or during a write.
  // ---------------------------------------------------------------------------
  // PLACEHOLDER: no macro instance yet. dout_o is intentionally undriven so
  // that elaboration fails loudly if this define is set prematurely.
`elsif AGRIASIC_FLOP_MEM
  // Behavioural model with the identical timing contract. With no SRAM compiler
  // available this is what actually goes on the die, so it is written for
  // synthesis quality rather than brevity:
  //
  //   1. The array sits in its OWN always_ff with NO reset. A memory has no
  //      meaningful reset state -- the boot loader fills IMEM before the core
  //      is ever released -- and resetting NUM_WORDS*32 flops would put a reset
  //      input on every one of them plus a reset net spanning the whole array.
  //      This is the single largest saving available here.
  //   2. Each byte lane carries its own enable, so a sub-word write clock-gates
  //      the three lanes it does not touch instead of reading them back through
  //      a feedback mux, which would roughly double the mux count.
  //   3. The enable is ce_i & we_i[n] directly. we_i[n] already implies |we_i,
  //      so carrying the extra term would just be redundant logic.
  //   4. dout_o is a separate register that DOES reset: 32 flops, not
  //      NUM_WORDS*32.
  //
  // After the flops themselves the dominant cost is the NUM_WORDS:1 read mux,
  // which is also in the fetch critical path. That is why depth is kept to what
  // the image actually needs rather than to a round number.
  logic [31:0] mem_array [0:NUM_WORDS-1];

  wire [AddrMsb-AddrLsb:0] word_addr = addr_i[AddrMsb:AddrLsb];

  // Deliberately NOT guarded by `ifndef SYNTHESIS. That looks like the obvious
  // thing to do -- flops cannot be initialised on silicon, and on the real chip
  // the boot loader is what puts an image here -- but power/run_sim.sh compiles
  // a SIMULATION with -DSYNTHESIS on purpose, so the hierarchy it traces matches
  // the synthesized one. Guarding this on SYNTHESIS silently leaves IMEM empty
  // in that build and the core fetches nothing. The init is harmless in
  // synthesis: it becomes an init attribute, not logic.
  initial begin
    // Fill the WHOLE array first, then let $readmemh overwrite the words the
    // image occupies. The fill used to sit in an `else`, so with an INIT_FILE
    // every word past the image stayed uninitialised -- X in a 4-state
    // simulator, 0 under Verilator, which is why this never showed up here.
    //
    // Why it matters, measured rather than assumed. The firmware image is 136
    // words; main's `ret` is the last instruction, at 0x21c. Ibex prefetches
    // linearly and speculatively, so it reads past `ret` before the return
    // resolves. Instrumenting the e2e fetch bus shows EXACTLY two such
    // fetches, at 0x220 and 0x224, and no more -- the prefetch buffer is
    // NUM_REQS=2 / FIFO DEPTH=3, so it cannot run further ahead than that.
    // Both are discarded by the branch flush.
    //
    // With X in those two words, though, the overrun stops being bounded.
    // ibex_fetch_fifo derives aligned_is_compressed from rdata[1:0], and that
    // signal gates pop_fifo and addr_incr_two. X on rdata[1:0] puts X on
    // pop_fifo, the FIFO never cleanly stalls, the prefetcher keeps issuing,
    // and fetch_addr_q marches +4 per grant into more unwritten words -- which
    // are also X. The corruption feeds itself and the fetch address walks to
    // the top of IMEM. A two-word speculative peek becomes a runaway.
    //
    // So the fill is not cosmetic X-cleanliness; it is what keeps a bounded
    // discarded prefetch from turning into an unbounded one. NOP (0x13) has
    // [1:0] == 2'b11, so aligned_is_compressed reads a clean 0.
    //
    // NOTE this is a SIMULATION fix only. On silicon these latches power up
    // undefined and the boot copier writes only ROM_USED_WORDS (136) of the
    // 256 words, so words 136..255 are genuinely undefined on the die and the
    // prefetcher still peeks at two of them. See agriasic_spi_boot.sv.
    for (int i = 0; i < NUM_WORDS; i++) mem_array[i] = 32'h0000_0013;  // NOP
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem_array);
  end

  // Storage: no reset, one enable per byte lane.
  //
  // KEEP always_ff. mem_array is written here AND by the initial preload
  // above, and IEEE 1800 9.2.2.4 says a variable assigned in an always_ff
  // shall not be written by any other process -- an initial block is one. A
  // strict front end (VCS, Xcelium, slang, Spyglass) can therefore reject
  // this. Neither of our tools does: verilator -Wall on this file is silent,
  // and power/build/synthesis blackboxes agriasic_imem, so it is not caught
  // here and the first report will come from someone else's flow.
  //
  // Do NOT answer that by downgrading to plain `always`. It silences the
  // message by discarding exactly the checking that makes this block safe --
  // single driver, no blocking assignments, flop inference -- and the latch
  // path below had a real write-address bug during bring-up that this class
  // of checking is what catches. agriasic_dmem has no preload and so no
  // conflict; only this module provokes it.
  //
  // Sanctioned handling, in order: waive it for this module (the preload is
  // simulation-only and runs at time 0, so it cannot race the clocked
  // writes); or blackbox the module, as synthesis already does. Only if a
  // tool refuses outright, move the $readmemh out to the testbench via a
  // hierarchical reference and delete the initial -- that also needs
  // power/run_sim.sh changed, since it compiles a simulation with -DSYNTHESIS
  // and relies on the image being here.
  always_ff @(posedge clk) begin
    if (ce_i) begin
      if (we_i[0]) mem_array[word_addr][7:0]   <= din_i[7:0];
      if (we_i[1]) mem_array[word_addr][15:8]  <= din_i[15:8];
      if (we_i[2]) mem_array[word_addr][23:16] <= din_i[23:16];
      if (we_i[3]) mem_array[word_addr][31:24] <= din_i[31:24];
    end
  end

  // Output register: resettable, 32 flops. Holds while ce_i is low and through
  // a write -- the no-change output policy a compiler macro would have given.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 dout_o <= 32'd0;
    else if (ce_i && !(|we_i))  dout_o <= mem_array[word_addr];
  end

`else
  // Latches are the DEFAULT. With no SRAM compiler available this is what goes
  // on the die: the flop array costs ~28 kGE more for the same 12,288 bits, and
  // at a 5 mm^2 budget that margin matters. Define AGRIASIC_FLOP_MEM to get the
  // flop array back -- it is simpler and needs nothing of the back end, so it
  // is the right choice if the ICG or latch-timing requirements below cannot be
  // met.
  // ---------------------------------------------------------------------------
  // Latch array. Same bits, smaller cells. Structure follows lowRISC's
  // ibex_register_file_latch.sv (proven silicon; already used here for the Ibex
  // register file). The ORDER is what makes it safe:
  //
  //   1. A global clock gate on "any write this cycle" -> clk_int.
  //   2. Write data, address and byte enables REGISTERED on clk_int. This is
  //      the critical step: the latches are transparent during the clk_int HIGH
  //      phase and these flops update on its RISING edge, so a latch sees
  //      stable data for its entire open window. Driving latches from
  //      combinational inputs instead is how latch arrays corrupt data.
  //   3. A per-word clock gate off the registered address.
  //   4. The latch, with registered byte enables picking lanes. A latch holds
  //      when not written, so unwritten lanes need no feedback mux -- which is
  //      the whole reason this is cheaper than flops.
  //
  // The array keeps the SAME NAME as the flop path so every testbench
  // hierarchical reference works against either build.
  //
  // Cost to the back end: prim_clock_gating must map to a real ICG cell, and
  // STA must treat these as latches with time borrowing. Both are already true
  // because of the Ibex latch register file.
  // ---------------------------------------------------------------------------
  localparam int unsigned AddrW = AddrMsb - AddrLsb + 1;

  logic [31:0] mem_array [0:NUM_WORDS-1];

  wire [AddrW-1:0] word_addr = addr_i[AddrMsb:AddrLsb];
  wire             any_write = ce_i && (|we_i);

  logic clk_int;
  prim_clock_gating u_cg_global (
    .clk_i (clk), .en_i (any_write), .test_en_i (1'b0), .clk_o (clk_int)
  );

  // Data and lane enables are registered; the ADDRESS is deliberately not.
  // The per-word gate below must see the address combinationally, the way
  // ibex_register_file_latch does: a clock-gating cell samples its enable
  // while the clock is low, so a registered address would arrive a cycle too
  // late and every write would land at the previous address.
  logic [31:0] din_q;
  logic [3:0]  we_q;

  always_ff @(posedge clk_int or negedge rst_n) begin
    if (!rst_n) begin
      din_q <= 32'd0; we_q <= 4'd0;
    end else begin
      din_q <= din_i; we_q <= we_i;
    end
  end

  logic [NUM_WORDS-1:0] word_clk;

  for (genvar w = 0; w < NUM_WORDS; w++) begin : gen_word
    prim_clock_gating u_cg_word (
      .clk_i (clk_int), .en_i (word_addr == AddrW'(w)), .test_en_i (1'b0),
      .clk_o (word_clk[w])
    );
    // KEEP always_latch -- same LRM 9.2.2.4 conflict with the initial preload
    // as the flop path above (always_latch carries the same single-process
    // restriction), and the same answer: waive or blackbox, never downgrade
    // to a plain `always`.
    always_latch begin
      if (word_clk[w]) begin
        if (we_q[0]) mem_array[w][7:0]   = din_q[7:0];
        if (we_q[1]) mem_array[w][15:8]  = din_q[15:8];
        if (we_q[2]) mem_array[w][23:16] = din_q[23:16];
        if (we_q[3]) mem_array[w][31:24] = din_q[31:24];
      end
    end
  end

  // Output register: identical policy to the flop path, so the one-cycle
  // latency and no-change output contract of section 6.16 do not move.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 dout_o <= 32'd0;
    else if (ce_i && !(|we_i))  dout_o <= mem_array[word_addr];
  end

  // Deliberately NOT guarded by `ifndef SYNTHESIS -- same trap as the flop
  // path above. power/run_sim.sh compiles a SIMULATION with -DSYNTHESIS so the
  // hierarchy it traces matches the synthesised one; guarding this leaves IMEM
  // empty in that build and the core fetches nothing. The init is harmless in
  // synthesis: it becomes an init attribute, not logic.
  initial begin
    // Fill the WHOLE array first, then let $readmemh overwrite the words the
    // image occupies. The fill used to sit in an `else`, so with an INIT_FILE
    // every word past the image stayed uninitialised -- X in a 4-state
    // simulator, 0 under Verilator, which is why this never showed up here.
    //
    // Why it matters, measured rather than assumed. The firmware image is 136
    // words; main's `ret` is the last instruction, at 0x21c. Ibex prefetches
    // linearly and speculatively, so it reads past `ret` before the return
    // resolves. Instrumenting the e2e fetch bus shows EXACTLY two such
    // fetches, at 0x220 and 0x224, and no more -- the prefetch buffer is
    // NUM_REQS=2 / FIFO DEPTH=3, so it cannot run further ahead than that.
    // Both are discarded by the branch flush.
    //
    // With X in those two words, though, the overrun stops being bounded.
    // ibex_fetch_fifo derives aligned_is_compressed from rdata[1:0], and that
    // signal gates pop_fifo and addr_incr_two. X on rdata[1:0] puts X on
    // pop_fifo, the FIFO never cleanly stalls, the prefetcher keeps issuing,
    // and fetch_addr_q marches +4 per grant into more unwritten words -- which
    // are also X. The corruption feeds itself and the fetch address walks to
    // the top of IMEM. A two-word speculative peek becomes a runaway.
    //
    // So the fill is not cosmetic X-cleanliness; it is what keeps a bounded
    // discarded prefetch from turning into an unbounded one. NOP (0x13) has
    // [1:0] == 2'b11, so aligned_is_compressed reads a clean 0.
    //
    // NOTE this is a SIMULATION fix only. On silicon these latches power up
    // undefined and the boot copier writes only ROM_USED_WORDS (136) of the
    // 256 words, so words 136..255 are genuinely undefined on the die and the
    // prefetcher still peeks at two of them. See agriasic_spi_boot.sv.
    for (int i = 0; i < NUM_WORDS; i++) mem_array[i] = 32'h0000_0013;  // NOP
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem_array);
  end
`endif

`ifndef SYNTHESIS
  // Accesses must be word aligned and in range.
  always_ff @(posedge clk) begin
    if (rst_n && ce_i) begin
      assert (addr_i[1:0] == 2'b00)
        else $error("agriasic_imem: unaligned addr 0x%08x", addr_i);
      // The low slice is exactly $clog2(NUM_WORDS) bits and cannot exceed the
      // bound, so the meaningful check is that no upper address bits are set,
      // i.e. the access actually falls inside this memory's region.
      assert (addr_i[31:AddrMsb+1] == '0)
        else $error("agriasic_imem: addr 0x%08x outside mapped region", addr_i);
    end
  end
`endif

endmodule

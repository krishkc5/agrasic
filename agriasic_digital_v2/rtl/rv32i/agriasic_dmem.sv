// -----------------------------------------------------------------------------
// Module: agriasic_dmem
// Purpose:
//   Data memory wrapper presenting the timing contract of a real foundry
//   single-port synchronous SRAM macro to the RV32I core.
//
// Timing contract:
//   - Access is captured on the rising edge of clk when ce_i is asserted.
//   - Write cycle  (ce_i && |we_i): byte lanes selected by we_i are written.
//   - Read cycle   (ce_i && !|we_i): dout_o is valid the FOLLOWING cycle.
//   - "No-change" output policy: on a write cycle, and whenever ce_i is low,
//     the output register HOLDS its previous value.
//
// Single-port note:
//   The core issues at most one load OR one store per cycle, never both, so a
//   single-port macro is sufficient. Do not assume read-during-write data.
//
// Integration intent:
//   The 1-cycle read latency places load data in the core's Writeback stage.
//   Byte extraction and sign extension happen there, not in Memory.
// -----------------------------------------------------------------------------
module agriasic_dmem #(
  parameter int unsigned NUM_WORDS = 128
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ce_i,
  input  logic [3:0]  we_i,    // per-byte write enables
  input  logic [31:0] addr_i,  // byte address; [1:0] ignored (4B aligned)
  input  logic [31:0] din_i,
  output logic [31:0] dout_o
);

  localparam int unsigned AddrLsb = 2;
  localparam int unsigned AddrMsb = $clog2(NUM_WORDS) + AddrLsb - 1;

`ifdef AGRIASIC_USE_SRAM_MACRO
  // ---------------------------------------------------------------------------
  // Vendor macro instance goes here. Required behavior:
  //   posedge-capture under ce_i, byte write enables, 1-cycle read latency,
  //   no-change output policy.
  // ---------------------------------------------------------------------------
  // PLACEHOLDER: no macro instance yet. dout_o is intentionally undriven so
  // that elaboration fails loudly if this define is set prematurely.
`elsif AGRIASIC_FLOP_MEM
  // Behavioural model with the identical timing contract. With no SRAM compiler
  // available this is what actually goes on the die, so it is written for
  // synthesis quality rather than brevity:
  //
  //   1. The array sits in its OWN always_ff with NO reset. A memory has no
  //      meaningful reset state -- scratch RAM is written before it is read -- and resetting NUM_WORDS*32 flops would put a reset
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
  logic [31:0] ram_array [0:NUM_WORDS-1];

  wire [AddrMsb-AddrLsb:0] word_addr = addr_i[AddrMsb:AddrLsb];

  // Storage: no reset, one enable per byte lane.
  always_ff @(posedge clk) begin
    if (ce_i) begin
      if (we_i[0]) ram_array[word_addr][7:0]   <= din_i[7:0];
      if (we_i[1]) ram_array[word_addr][15:8]  <= din_i[15:8];
      if (we_i[2]) ram_array[word_addr][23:16] <= din_i[23:16];
      if (we_i[3]) ram_array[word_addr][31:24] <= din_i[31:24];
    end
  end

  // Output register: resettable, 32 flops. Holds while ce_i is low and through
  // a write -- the no-change output policy a compiler macro would have given.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 dout_o <= 32'd0;
    else if (ce_i && !(|we_i))  dout_o <= ram_array[word_addr];
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

  logic [31:0] ram_array [0:NUM_WORDS-1];

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
    always_latch begin
      if (word_clk[w]) begin
        if (we_q[0]) ram_array[w][7:0]   = din_q[7:0];
        if (we_q[1]) ram_array[w][15:8]  = din_q[15:8];
        if (we_q[2]) ram_array[w][23:16] = din_q[23:16];
        if (we_q[3]) ram_array[w][31:24] = din_q[31:24];
      end
    end
  end

  // Output register: identical policy to the flop path, so the one-cycle
  // latency and no-change output contract of section 6.16 do not move.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 dout_o <= 32'd0;
    else if (ce_i && !(|we_i))  dout_o <= ram_array[word_addr];
  end
`endif

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && ce_i) begin
      assert (addr_i[1:0] == 2'b00)
        else $error("agriasic_dmem: unaligned data addr 0x%08x", addr_i);
      // The low slice is exactly $clog2(NUM_WORDS) bits and cannot exceed the
      // bound, so the meaningful check is that no upper address bits are set,
      // i.e. the access actually falls inside this memory's region.
      assert (addr_i[31:AddrMsb+1] == '0)
        else $error("agriasic_dmem: data addr 0x%08x outside mapped region", addr_i);
    end
  end
`endif

endmodule

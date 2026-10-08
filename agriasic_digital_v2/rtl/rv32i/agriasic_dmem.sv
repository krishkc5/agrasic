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
`else
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

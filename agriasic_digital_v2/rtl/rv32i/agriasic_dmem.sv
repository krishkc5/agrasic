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
  parameter int unsigned NUM_WORDS = 1024
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
  // Behavioral model with the identical timing contract.
  logic [31:0] ram_array [0:NUM_WORDS-1];

  wire [AddrMsb-AddrLsb:0] word_addr = addr_i[AddrMsb:AddrLsb];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dout_o <= 32'd0;
    end else if (ce_i) begin
      if (|we_i) begin
        // Write cycle: no-change output policy, dout_o holds.
        if (we_i[0]) ram_array[word_addr][7:0]   <= din_i[7:0];
        if (we_i[1]) ram_array[word_addr][15:8]  <= din_i[15:8];
        if (we_i[2]) ram_array[word_addr][23:16] <= din_i[23:16];
        if (we_i[3]) ram_array[word_addr][31:24] <= din_i[31:24];
      end else begin
        dout_o <= ram_array[word_addr];
      end
    end
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

// -----------------------------------------------------------------------------
// Module: agriasic_imem
// Purpose:
//   Instruction memory wrapper presenting the timing contract of a real
//   foundry SRAM/ROM macro to the RV32I core.
//
// Timing contract (matches a standard single-port synchronous macro):
//   - addr_i is captured on the rising edge of clk when ce_i is asserted.
//   - dout_o is valid throughout the FOLLOWING cycle.
//   - When ce_i is deasserted the output register HOLDS its previous value.
//
// Integration intent:
//   The output register of this macro serves as the Fetch/Decode pipeline
//   register for the instruction field. The core must not re-register dout_o.
//
// Macro swap:
//   Define AGRIASIC_USE_SRAM_MACRO and fill in the vendor instance below when
//   memory-compiler output is available. Nothing outside this file changes.
// -----------------------------------------------------------------------------
module agriasic_imem #(
  parameter int unsigned NUM_WORDS = 1024,
  parameter string       INIT_FILE = "agriasic_fw.hex"
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ce_i,
  input  logic [31:0] addr_i,   // byte address; [1:0] ignored (4B aligned)
  output logic [31:0] dout_o
);

  localparam int unsigned AddrLsb = 2;
  localparam int unsigned AddrMsb = $clog2(NUM_WORDS) + AddrLsb - 1;

`ifdef AGRIASIC_USE_SRAM_MACRO
  // ---------------------------------------------------------------------------
  // Vendor macro instance goes here. Required behavior:
  //   posedge-capture of address under ce_i, 1-cycle read latency,
  //   output register holds while ce_i is low.
  // ---------------------------------------------------------------------------
  // PLACEHOLDER: no macro instance yet. dout_o is intentionally undriven so
  // that elaboration fails loudly if this define is set prematurely.
`else
  // Behavioral model with the identical timing contract.
  logic [31:0] rom_array [0:NUM_WORDS-1];

  initial begin
    $readmemh(INIT_FILE, rom_array);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dout_o <= 32'd0;
    end else if (ce_i) begin
      dout_o <= rom_array[addr_i[AddrMsb:AddrLsb]];
    end
    // ce_i low: output register holds, matching macro behavior.
  end
`endif

`ifndef SYNTHESIS
  // Fetch addresses must be word aligned and in range.
  always_ff @(posedge clk) begin
    if (rst_n && ce_i) begin
      assert (addr_i[1:0] == 2'b00)
        else $error("agriasic_imem: unaligned fetch addr 0x%08x", addr_i);
      // The low slice is exactly $clog2(NUM_WORDS) bits and cannot exceed the
      // bound, so the meaningful check is that no upper address bits are set,
      // i.e. the access actually falls inside this memory's region.
      assert (addr_i[31:AddrMsb+1] == '0)
        else $error("agriasic_imem: fetch addr 0x%08x outside mapped region", addr_i);
    end
  end
`endif

endmodule

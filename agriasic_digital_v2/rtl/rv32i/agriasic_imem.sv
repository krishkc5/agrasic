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
  parameter int unsigned NUM_WORDS = 1024,
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
`else
  // Behavioral model with the identical timing contract.
  logic [31:0] mem_array [0:NUM_WORDS-1];

  wire [AddrMsb-AddrLsb:0] word_addr = addr_i[AddrMsb:AddrLsb];

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem_array);
    else for (int i = 0; i < NUM_WORDS; i++) mem_array[i] = 32'h0000_0013;  // NOP: empty part
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dout_o <= 32'd0;
    end else if (ce_i) begin
      if (|we_i) begin
        // Write cycle: no-change output policy, dout_o holds.
        if (we_i[0]) mem_array[word_addr][7:0]   <= din_i[7:0];
        if (we_i[1]) mem_array[word_addr][15:8]  <= din_i[15:8];
        if (we_i[2]) mem_array[word_addr][23:16] <= din_i[23:16];
        if (we_i[3]) mem_array[word_addr][31:24] <= din_i[31:24];
      end else begin
        dout_o <= mem_array[word_addr];
      end
    end
    // ce_i low: output register holds, matching macro behavior.
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

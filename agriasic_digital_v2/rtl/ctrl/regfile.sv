// -----------------------------------------------------------------------------
// Module: regfile
// Purpose:
//   Generic small register bank for control/status storage.
//
// Functionality in this skeleton:
//   - Synchronous write on wr_en_i.
//   - Asynchronous combinational read from rd_addr_i.
//   - Full register array reset to zero.
//
// Integration intent:
//   This block will host control registers (start/config), status bits (busy/
//   done/error), and result readout windows once register map is finalized.
// -----------------------------------------------------------------------------
module regfile #(
  parameter int unsigned AW = 4,
  parameter int unsigned DW = 32
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             wr_en_i,
  input  logic [AW-1:0]    wr_addr_i,
  input  logic [DW-1:0]    wr_data_i,
  input  logic [AW-1:0]    rd_addr_i,
  output logic [DW-1:0]    rd_data_o
);

  logic [DW-1:0] mem_q [0:(1<<AW)-1];
  int unsigned i;

  // Write/reset process for register storage.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < (1<<AW); i++) begin
        mem_q[i] <= '0;
      end
    end else if (wr_en_i) begin
      mem_q[wr_addr_i] <= wr_data_i;
    end
  end

  // Direct combinational read access.
  assign rd_data_o = mem_q[rd_addr_i];

endmodule

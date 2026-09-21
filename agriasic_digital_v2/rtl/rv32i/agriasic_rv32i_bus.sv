// -----------------------------------------------------------------------------
// Module: agriasic_rv32i_bus
// Purpose:
//   Interconnect for the Ibex control core and the RISC-V debug module.
//   Three OBI-style masters, three one-cycle slaves, fixed-priority
//   arbitration with grant back-pressure.
//
// Why it exists (Phase 2, debug):
//   Before the debug module the core's two memory ports went straight to two
//   private memories (a Harvard split with both starting at address 0). A
//   debugger sees ONE flat address space, and the debug module itself must be
//   reachable from the instruction port (debug ROM / program buffer) and the
//   data port (data0/1, flags), while its system-bus master must reach the
//   memories to load firmware. So the map is now flat and non-overlapping:
//
//     0x0000_0000 - 0x0000_0FFF  IMEM   fetch; programming reads/writes
//     0x0001_0000 - 0x0001_07FF  DMEM   } one slave: agriasic_rv32i_mmio,
//     0x8000_0000 - 0x8000_001F  MMIO   } which decodes RAM vs peripherals
//     0x1A11_0000 - 0x1A11_0FFF  DM     debug module (dm_top slave port)
//     everything else            bus error (Ibex: access-fault trap;
//                                          SBA: sberror)
//
// Masters (priority for a contended slave, highest first):
//   M1  core data port     may target IMEM, DMEM/MMIO, DM
//   M2  debug SBA master   may target IMEM, DMEM/MMIO       (DM -> error)
//   M0  core instr port    may target IMEM, DM              (else -> error)
//
//   Data before fetch keeps a load/store from being starved by the prefetcher;
//   the debugger's SBA sits between them because it is only active while the
//   user is poking memory. A master that loses arbitration simply sees gnt=0
//   and holds its request (OBI semantics); Ibex and dm_sba both do this.
//
// Slaves:
//   All three complete every accepted access in exactly one cycle (address
//   captured at the edge that sees req && gnt, data valid the next cycle), so
//   each master's response is a registered copy of its grant plus a mux
//   select. IMEM and DM are always ready; the DMEM/MMIO bridge exposes gnt
//   and is also always ready today, but is honoured generically.
//
// Response contract to each master: rvalid one cycle after gnt; err with
// rvalid for an unmapped or disallowed target, or a bridge-reported error.
// -----------------------------------------------------------------------------
module agriasic_rv32i_bus #(
  parameter int unsigned  IMEM_BYTES   = 32'h0000_1000,
  parameter logic [31:0]  DMEM_BASE    = 32'h0001_0000,
  parameter int unsigned  DMEM_BYTES   = 32'h0000_0800,
  parameter logic [31:0]  PERIPH_BASE  = 32'h8000_0000,
  parameter int unsigned  PERIPH_BYTES = 32'h0000_0020,
  parameter logic [31:0]  DM_BASE      = 32'h1A11_0000,
  parameter int unsigned  DM_BYTES     = 32'h0000_1000
) (
  input  logic        clk,
  input  logic        rst_n,

  // M0: core instruction port (read only)
  input  logic        instr_req_i,
  input  logic [31:0] instr_addr_i,
  output logic        instr_gnt_o,
  output logic        instr_rvalid_o,
  output logic [31:0] instr_rdata_o,
  output logic        instr_err_o,

  // M1: core data port
  input  logic        data_req_i,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_addr_i,
  input  logic [31:0] data_wdata_i,
  output logic        data_gnt_o,
  output logic        data_rvalid_o,
  output logic [31:0] data_rdata_o,
  output logic        data_err_o,

  // M2: debug module system-bus master
  input  logic        sba_req_i,
  input  logic        sba_we_i,
  input  logic [3:0]  sba_be_i,
  input  logic [31:0] sba_addr_i,
  input  logic [31:0] sba_wdata_i,
  output logic        sba_gnt_o,
  output logic        sba_rvalid_o,
  output logic [31:0] sba_rdata_o,
  output logic        sba_err_o,

  // S0: instruction memory (single port, always ready, 1-cycle)
  output logic        imem_ce_o,
  output logic [3:0]  imem_we_o,
  output logic [31:0] imem_addr_o,
  output logic [31:0] imem_wdata_o,
  input  logic [31:0] imem_rdata_i,

  // S1: DMEM + peripheral bridge (OBI slave, 1-cycle)
  output logic        mmio_req_o,
  output logic        mmio_we_o,
  output logic [3:0]  mmio_be_o,
  output logic [31:0] mmio_addr_o,
  output logic [31:0] mmio_wdata_o,
  input  logic        mmio_gnt_i,
  input  logic        mmio_rvalid_i,
  input  logic [31:0] mmio_rdata_i,
  input  logic        mmio_err_i,

  // S2: debug module slave port (always ready, 1-cycle)
  output logic        dm_req_o,
  output logic        dm_we_o,
  output logic [3:0]  dm_be_o,
  output logic [31:0] dm_addr_o,
  output logic [31:0] dm_wdata_o,
  input  logic [31:0] dm_rdata_i
);

  typedef enum logic [1:0] {
    TGT_ERR  = 2'd0,
    TGT_IMEM = 2'd1,
    TGT_MMIO = 2'd2,
    TGT_DM   = 2'd3
  } target_e;

  function automatic target_e decode(input logic [31:0] addr);
    if (addr < IMEM_BYTES)                                            return TGT_IMEM;
    if (addr >= DMEM_BASE   && addr < DMEM_BASE   + DMEM_BYTES)       return TGT_MMIO;
    if (addr >= PERIPH_BASE && addr < PERIPH_BASE + PERIPH_BYTES)     return TGT_MMIO;
    if (addr >= DM_BASE     && addr < DM_BASE     + DM_BYTES)         return TGT_DM;
    return TGT_ERR;
  endfunction

  // --------------------------------------------------------------------------
  // Decode, with per-master permission
  // --------------------------------------------------------------------------
  target_e m0_tgt, m1_tgt, m2_tgt;

  always_comb begin
    m0_tgt = decode(instr_addr_i);
    if (m0_tgt == TGT_MMIO) m0_tgt = TGT_ERR;   // no fetch from RAM/peripherals
    m1_tgt = decode(data_addr_i);
    m2_tgt = decode(sba_addr_i);
    if (m2_tgt == TGT_DM)   m2_tgt = TGT_ERR;   // SBA never targets the DM itself
  end

  // --------------------------------------------------------------------------
  // Arbitration: M1 > M2 > M0 on every contended slave
  // --------------------------------------------------------------------------
  wire m0_req_imem = instr_req_i && (m0_tgt == TGT_IMEM);
  wire m0_req_dm   = instr_req_i && (m0_tgt == TGT_DM);
  wire m1_req_imem = data_req_i  && (m1_tgt == TGT_IMEM);
  wire m1_req_mmio = data_req_i  && (m1_tgt == TGT_MMIO);
  wire m1_req_dm   = data_req_i  && (m1_tgt == TGT_DM);
  wire m2_req_imem = sba_req_i   && (m2_tgt == TGT_IMEM);
  wire m2_req_mmio = sba_req_i   && (m2_tgt == TGT_MMIO);

  wire imem_sel_m1 = m1_req_imem;
  wire imem_sel_m2 = m2_req_imem && !imem_sel_m1;
  wire imem_sel_m0 = m0_req_imem && !imem_sel_m1 && !imem_sel_m2;

  wire mmio_sel_m1 = m1_req_mmio;
  wire mmio_sel_m2 = m2_req_mmio && !mmio_sel_m1;

  wire dm_sel_m1   = m1_req_dm;
  wire dm_sel_m0   = m0_req_dm && !dm_sel_m1;

  // Errors are "accepted" immediately and answered next cycle.
  assign instr_gnt_o = instr_req_i && ((m0_tgt == TGT_ERR) || imem_sel_m0 || dm_sel_m0);
  assign data_gnt_o  = data_req_i  && ((m1_tgt == TGT_ERR) || imem_sel_m1 || dm_sel_m1 ||
                                       (mmio_sel_m1 && mmio_gnt_i));
  assign sba_gnt_o   = sba_req_i   && ((m2_tgt == TGT_ERR) || imem_sel_m2 ||
                                       (mmio_sel_m2 && mmio_gnt_i));

  // --------------------------------------------------------------------------
  // Slave request muxes
  // --------------------------------------------------------------------------
  assign imem_ce_o    = imem_sel_m1 || imem_sel_m2 || imem_sel_m0;
  assign imem_we_o    = imem_sel_m1 ? (data_we_i ? data_be_i : 4'b0000) :
                        imem_sel_m2 ? (sba_we_i  ? sba_be_i  : 4'b0000) : 4'b0000;
  assign imem_addr_o  = imem_sel_m1 ? data_addr_i  : imem_sel_m2 ? sba_addr_i  : instr_addr_i;
  assign imem_wdata_o = imem_sel_m1 ? data_wdata_i : sba_wdata_i;

  assign mmio_req_o   = mmio_sel_m1 || mmio_sel_m2;
  assign mmio_we_o    = mmio_sel_m1 ? data_we_i    : sba_we_i;
  assign mmio_be_o    = mmio_sel_m1 ? data_be_i    : sba_be_i;
  assign mmio_addr_o  = mmio_sel_m1 ? data_addr_i  : sba_addr_i;
  assign mmio_wdata_o = mmio_sel_m1 ? data_wdata_i : sba_wdata_i;

  assign dm_req_o     = dm_sel_m1 || dm_sel_m0;
  assign dm_we_o      = dm_sel_m1 && data_we_i;
  assign dm_be_o      = dm_sel_m1 ? data_be_i    : 4'b1111;
  assign dm_addr_o    = dm_sel_m1 ? data_addr_i  : instr_addr_i;
  assign dm_wdata_o   = data_wdata_i;

  // --------------------------------------------------------------------------
  // Responses: one cycle after grant, muxed by the target that was granted
  // --------------------------------------------------------------------------
  logic    m0_rvalid_q, m1_rvalid_q, m2_rvalid_q;
  target_e m0_sel_q,    m1_sel_q,    m2_sel_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m0_rvalid_q <= 1'b0; m0_sel_q <= TGT_ERR;
      m1_rvalid_q <= 1'b0; m1_sel_q <= TGT_ERR;
      m2_rvalid_q <= 1'b0; m2_sel_q <= TGT_ERR;
    end else begin
      m0_rvalid_q <= instr_gnt_o; m0_sel_q <= m0_tgt;
      m1_rvalid_q <= data_gnt_o;  m1_sel_q <= m1_tgt;
      m2_rvalid_q <= sba_gnt_o;   m2_sel_q <= m2_tgt;
    end
  end

  function automatic logic [31:0] rdata_mux(input target_e     sel,
                                            input logic [31:0] imem_d,
                                            input logic [31:0] mmio_d,
                                            input logic [31:0] dm_d);
    unique case (sel)
      TGT_IMEM: return imem_d;
      TGT_MMIO: return mmio_d;
      TGT_DM:   return dm_d;
      default:  return 32'd0;
    endcase
  endfunction

  assign instr_rvalid_o = m0_rvalid_q;
  assign instr_rdata_o  = rdata_mux(m0_sel_q, imem_rdata_i, mmio_rdata_i, dm_rdata_i);
  assign instr_err_o    = m0_rvalid_q && (m0_sel_q == TGT_ERR);

  assign data_rvalid_o  = m1_rvalid_q;
  assign data_rdata_o   = rdata_mux(m1_sel_q, imem_rdata_i, mmio_rdata_i, dm_rdata_i);
  assign data_err_o     = m1_rvalid_q && ((m1_sel_q == TGT_ERR) ||
                                          ((m1_sel_q == TGT_MMIO) && mmio_err_i));

  assign sba_rvalid_o   = m2_rvalid_q;
  assign sba_rdata_o    = rdata_mux(m2_sel_q, imem_rdata_i, mmio_rdata_i, dm_rdata_i);
  assign sba_err_o      = m2_rvalid_q && ((m2_sel_q == TGT_ERR) ||
                                          ((m2_sel_q == TGT_MMIO) && mmio_err_i));

`ifndef SYNTHESIS
  // The bridge is expected to answer exactly one cycle after each accepted
  // request; the response muxes above depend on it.
  logic mmio_req_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mmio_req_q <= 1'b0;
    else        mmio_req_q <= mmio_req_o && mmio_gnt_i;
  end
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (mmio_rvalid_i == mmio_req_q)
        else $error("agriasic_rv32i_bus: bridge rvalid not 1 cycle after grant");
    end
  end
`endif

endmodule

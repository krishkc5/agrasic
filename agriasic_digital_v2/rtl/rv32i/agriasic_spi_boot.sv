// -----------------------------------------------------------------------------
// Module: agriasic_spi_boot
// Purpose:
//   Autonomous firmware boot from an external SPI NOR flash (Option C), plus a
//   minimal SPI-master peripheral for firmware afterwards (self-reflash).
//
// BOOT_SEL strap (sampled once at reset release -- it is a strap, not a
// runtime control):
//   0 (default, and what an unstrapped pin with a pull-down gives):
//       shadow-load the GOLDEN image from the on-die synthesized boot ROM
//       into the IMEM SRAM, then release the core. A bare chip with no flash
//       and no host starts and runs on its own.
//   1:  load from external SPI flash instead (below). This is the patchable
//       path: build a new image, program the flash, strap high.
//
// Either way the core fetches from the SRAM, never from the ROM, so IMEM
// stays WRITABLE after boot -- a debugger can halt, patch a constant over
// JTAG and resume without rebuilding or reflashing anything. That is the
// whole reason this is a shadow-load rather than a fetch-path mux.
//
// BOOT_CTRL lets the debugger override the strap in both directions
// (retry -> flash, boot_rom -> golden ROM), so neither source is reachable
// only by re-strapping the board.
//
// ROM shadow-load (boot_sel_i = 0):
//   No power-up wait (the ROM is gates, not a part that has to come up) and
//   no CRC (a constant table cannot be corrupt in the way a flash read can).
//   USED_WORDS words are copied through the bus, one per grant, so the copy
//   costs roughly 2 cycles per word -- about 300 cycles for the current
//   image, against ~65,000 for the same image over SPI.
//
// Flash boot (boot_sel_i = 1):
//   1. Wait BOOT_DELAY_CYCLES after reset so the flash is out of power-up.
//   2. CS low, send READ (0x03) + 24-bit address 0, then clock in:
//        header, 16 bytes, little-endian words:
//          [0] magic   0x41475241  ("AGRA")
//          [1] length  payload bytes, multiple of 4, 4..IMEM_BYTES
//          [2] version free-form, reported in BOOT_STATUS
//          [3] crc32   IEEE 802.3 / zlib CRC-32 of the payload only
//        payload, `length` bytes, written to IMEM at 0 as 32-bit words
//        through the bus (this module is bus master M3).
//   3. CRC matches -> fw_valid_o = 1 (the shell releases the core).
//      Otherwise boot_fail_o = 1 with an error code and the core stays held.
//   The image is produced by fw/build.sh (agriasic_fw_flash.bin/.hex).
//
// Skip:
//   IMEM_PRELOADED = 1 (simulation only) goes straight here: the behavioural
//   IMEM was filled by $readmemh, so neither boot source should overwrite it.
//   fw_valid_o then waits for BOOT_CTRL.release, which is also the bench flow
//   for "the debugger loaded IMEM itself".
//
// Registers (behind agriasic_rv32i_mmio, window 0x8000_0020):
//   BOOT_STATUS  R   [3:0] state  [6:4] error  [8] fw_valid  [9] boot_sel
//                    [10] boot_fail  [11] busy  [13:12] source
//                    (0 = none/skip, 1 = golden ROM, 2 = SPI flash)
//                    [31:16] image version (flash header; 0 for a ROM boot)[15:0]
//   BOOT_CTRL    W   [0] release: assert fw_valid (from SKIP/FAIL)
//                    [1] retry: drop fw_valid (core back to reset) and re-run
//                        the FLASH boot regardless of the strap
//                    [2] boot_rom: same, but re-run the golden ROM copy
//   SPI_CTRL     RW  [0] cs_n (1 = deselected)  [15:8] clock divider
//   SPI_DATA     W   byte to transmit (starts an 8-bit transfer)
//                R   last byte received
//   SPI_STATUS   R   [0] busy  [1] fw_owned (boot done, pins belong to fw)
//   The SPI engine and pins belong to the boot FSM until it reaches DONE,
//   FAIL or SKIP; after that SPI_CTRL/SPI_DATA drive them.
//
// SPI: mode 0 (SCK idle low; MOSI changes on falling edge, MISO sampled on
// rising edge), MSB first. SCK = clk / (2 * (div + 1)); the boot uses
// BOOT_CLK_DIV (default 7 -> clk/16 = 10 MHz at 160 MHz).
//
// Error codes: 1 bad magic, 2 bad length, 3 CRC mismatch, 4 bus error.
// A ROM boot can only ever report 4.
// -----------------------------------------------------------------------------
module agriasic_spi_boot #(
  parameter int unsigned IMEM_BYTES        = 4096,
  parameter int unsigned BOOT_DELAY_CYCLES = 800_000,  // ~5 ms at 160 MHz (flash tVSL)
  parameter logic [7:0]  BOOT_CLK_DIV      = 8'd7,
  parameter bit          IMEM_PRELOADED    = 1'b0,
  parameter int unsigned ROM_USED_WORDS    = 148       // golden image size, see agriasic_boot_rom
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        boot_sel_i,      // strap: 0 = golden ROM, 1 = SPI flash

  // Golden boot ROM (combinational constant table, agriasic_boot_rom).
  output logic [31:0] rom_addr_o,
  input  logic [31:0] rom_data_i,

  // Flash SPI pins
  output logic        spi_sck_o,
  output logic        spi_cs_n_o,
  output logic        spi_mosi_o,
  input  logic        spi_miso_i,

  // Bus master (M3) -> IMEM
  output logic        bus_req_o,
  output logic        bus_we_o,
  output logic [3:0]  bus_be_o,
  output logic [31:0] bus_addr_o,
  output logic [31:0] bus_wdata_o,
  input  logic        bus_gnt_i,
  input  logic        bus_rvalid_i,
  input  logic [31:0] bus_rdata_i,
  input  logic        bus_err_i,

  // Status to the shell
  output logic        fw_valid_o,
  output logic        boot_fail_o,

  // Register interface from the MMIO bridge
  input  logic        ctrl_release_i,   // pulse
  input  logic        ctrl_retry_i,     // pulse: re-boot from flash
  input  logic        ctrl_boot_rom_i,  // pulse: re-boot from the golden ROM
  input  logic        spi_ctrl_we_i,    // pulse, spi_ctrl_wdata_i valid
  input  logic [15:0] spi_ctrl_wdata_i, // [0] cs_n, [15:8] div
  input  logic        spi_data_we_i,    // pulse, starts a transfer
  input  logic [7:0]  spi_data_wdata_i,
  output logic [31:0] boot_status_o,
  output logic [31:0] spi_ctrl_o,
  output logic [7:0]  spi_rx_o,
  output logic [31:0] spi_status_o
);

  localparam logic [31:0] MAGIC = 32'h4147_5241;
  localparam logic [7:0]  CMD_READ = 8'h03;

  // --------------------------------------------------------------------------
  // CRC-32 (reflected, poly 0xEDB88320): one byte per call
  // --------------------------------------------------------------------------
  function automatic logic [31:0] crc32_byte(input logic [31:0] crc, input logic [7:0] data);
    logic [31:0] c;
    c = crc ^ {24'd0, data};
    for (int i = 0; i < 8; i++) begin
      c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    end
    return c;
  endfunction

  // --------------------------------------------------------------------------
  // SPI byte engine (shared by the boot FSM and the firmware peripheral)
  // --------------------------------------------------------------------------
  logic        eng_start;
  logic [7:0]  eng_tx;
  logic [7:0]  eng_div;
  logic        eng_busy;
  logic        eng_done;      // one-cycle pulse, eng_rx valid
  logic [7:0]  eng_rx;

  logic [7:0]  div_cnt_q;
  logic [3:0]  bit_cnt_q;     // 8..1 bits remaining
  logic        sck_q;
  logic [7:0]  sh_tx_q, sh_rx_q;

  assign eng_busy  = (bit_cnt_q != 4'd0);
  assign spi_sck_o = sck_q;
  assign spi_mosi_o = sh_tx_q[7];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt_q <= '0;
      bit_cnt_q <= '0;
      sck_q     <= 1'b0;
      sh_tx_q   <= '0;
      sh_rx_q   <= '0;
      eng_done  <= 1'b0;
      eng_rx    <= '0;
    end else begin
      eng_done <= 1'b0;
      if (!eng_busy) begin
        sck_q <= 1'b0;
        if (eng_start) begin
          sh_tx_q   <= eng_tx;      // MSB presented on MOSI while SCK is low
          bit_cnt_q <= 4'd8;
          div_cnt_q <= '0;
        end
      end else if (div_cnt_q == eng_div) begin
        div_cnt_q <= '0;
        if (!sck_q) begin
          // rising edge: sample MISO
          sck_q   <= 1'b1;
          sh_rx_q <= {sh_rx_q[6:0], spi_miso_i};
        end else begin
          // falling edge: shift out the next bit
          sck_q     <= 1'b0;
          sh_tx_q   <= {sh_tx_q[6:0], 1'b0};
          bit_cnt_q <= bit_cnt_q - 4'd1;
          if (bit_cnt_q == 4'd1) begin
            eng_done <= 1'b1;
            eng_rx   <= sh_rx_q;
          end
        end
      end else begin
        div_cnt_q <= div_cnt_q + 8'd1;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Boot FSM
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_DELAY   = 4'd0,
    S_CMD     = 4'd1,
    S_HDR     = 4'd2,
    S_CHECK   = 4'd3,
    S_DATA    = 4'd4,
    S_WRITE   = 4'd5,
    S_VERIFY  = 4'd6,
    S_DONE    = 4'd7,
    S_FAIL    = 4'd8,
    S_SKIP    = 4'd9,
    S_ROM     = 4'd10   // shadow-load the golden ROM into IMEM
  } state_e;

  state_e      state_q, state_d;
  logic [2:0]  err_q, err_d;
  logic [19:0] delay_q;
  logic [4:0]  byte_idx_q;                   // command/header byte counter
  logic [31:0] hdr_q [4];                    // magic, length, version, crc
  logic [31:0] hdr_d [4];
  logic [31:0] length_q;                     // payload bytes
  logic [31:0] off_q;                        // payload bytes received
  logic [31:0] word_q;                       // assembling word (little-endian)
  logic [31:0] crc_q;
  logic        fw_valid_q;
  logic        bus_err_q;                   // sticky: any write returned err
  logic        force_flash_q;               // BOOT_CTRL.retry: boot from flash
  logic        force_rom_q;                 // BOOT_CTRL.boot_rom: boot from the golden ROM
  logic        strap_q;                     // boot_sel_i latched at reset release
  logic        strap_valid_q;               // strap_q holds a real sample
  logic [1:0]  source_q;                    // what the last boot actually used
  logic        boot_cs_n;
  logic        boot_start;
  logic [7:0]  boot_tx;
  logic        boot_owns;                    // engine/pins belong to the boot FSM

  wire in_boot = (state_q != S_DONE) && (state_q != S_FAIL) && (state_q != S_SKIP);
  assign boot_owns = in_boot;

  // Command bytes: READ + 24-bit address 0
  function automatic logic [7:0] cmd_byte(input logic [4:0] idx);
    return (idx == 5'd0) ? CMD_READ : 8'h00;
  endfunction

  always_comb begin
    state_d    = state_q;
    err_d      = err_q;
    boot_cs_n  = 1'b1;
    boot_start = 1'b0;
    boot_tx    = 8'h00;
    bus_req_o  = 1'b0;
    hdr_d      = hdr_q;
    rom_addr_o = off_q;

    unique case (state_q)
      S_DELAY: begin
        // First cycle out of reset samples the strap; the source decision is
        // made from the LATCHED value, never from the live pin, so a glitch
        // after reset cannot redirect a boot in progress.
        if (!strap_valid_q) begin
          state_d = S_DELAY;
        // Simulation with a $readmemh-preloaded IMEM: touch neither source.
        end else if (IMEM_PRELOADED && !force_flash_q && !force_rom_q) begin
          state_d = S_SKIP;
        end else if (boot_from_flash) begin
          // Only the flash path needs the part's power-up time.
          if (delay_q == 20'(BOOT_DELAY_CYCLES)) state_d = S_CMD;
        end else begin
          state_d = S_ROM;
        end
      end

      // Golden ROM -> IMEM, one word per bus grant. rom_addr_o is off_q, so
      // the ROM word and the IMEM address are the same by construction and a
      // copy cannot skew.
      S_ROM: begin
        bus_req_o = 1'b1;
        if (bus_gnt_i) begin
          if (off_q + 32'd4 >= 32'(ROM_USED_WORDS * 4)) state_d = S_VERIFY;
        end
      end

      S_CMD: begin
        boot_cs_n = 1'b0;
        boot_tx   = cmd_byte(byte_idx_q);
        if (!eng_busy && !eng_done) boot_start = 1'b1;
        if (eng_done && byte_idx_q == 5'd3) state_d = S_HDR;
      end

      S_HDR: begin
        boot_cs_n = 1'b0;
        if (!eng_busy && !eng_done) boot_start = 1'b1;
        if (eng_done) begin
          // byte_idx_q counts 0..15 within the header; little-endian words
          hdr_d[byte_idx_q[3:2]][8*byte_idx_q[1:0] +: 8] = eng_rx;
          if (byte_idx_q == 5'd15) state_d = S_CHECK;
        end
      end

      S_CHECK: begin
        boot_cs_n = 1'b0;
        if (hdr_q[0] != MAGIC) begin
          err_d = 3'd1; state_d = S_FAIL;
        end else if (hdr_q[1] == 32'd0 || hdr_q[1] > IMEM_BYTES || hdr_q[1][1:0] != 2'b00) begin
          err_d = 3'd2; state_d = S_FAIL;
        end else begin
          state_d = S_DATA;
        end
      end

      S_DATA: begin
        boot_cs_n = 1'b0;
        if (!eng_busy && !eng_done) boot_start = 1'b1;
        if (eng_done && off_q[1:0] == 2'b11) state_d = S_WRITE;
      end

      S_WRITE: begin
        boot_cs_n = 1'b0;
        bus_req_o = 1'b1;
        if (bus_gnt_i) begin
          state_d = (off_q == length_q) ? S_VERIFY : S_DATA;
        end
      end

      S_VERIFY: begin
        // CS released; final CRC = ~crc_q. A ROM copy has no CRC to check --
        // the table is gates -- so only the bus-error check applies to it.
        if (bus_err_i || bus_err_q) begin
          err_d = 3'd4; state_d = S_FAIL;
        end else if (from_rom_q) begin
          state_d = S_DONE;
        end else if ((crc_q ^ 32'hFFFF_FFFF) != hdr_q[3]) begin
          err_d = 3'd3; state_d = S_FAIL;
        end else begin
          state_d = S_DONE;
        end
      end

      S_DONE, S_FAIL, S_SKIP: begin
        if (ctrl_retry_i || ctrl_boot_rom_i) begin
          state_d = S_DELAY;
          err_d   = 3'd0;
        end
      end

      default: state_d = S_DELAY;
    endcase
  end

  // Sequential part of the FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= S_DELAY;
      err_q      <= 3'd0;
      delay_q    <= '0;
      byte_idx_q <= '0;
      length_q   <= '0;
      off_q      <= '0;
      word_q     <= '0;
      crc_q      <= 32'hFFFF_FFFF;
      fw_valid_q <= 1'b0;
      bus_err_q  <= 1'b0;
      force_flash_q <= 1'b0;
      force_rom_q   <= 1'b0;
      strap_q       <= 1'b0;
      strap_valid_q <= 1'b0;
      source_q      <= 2'd0;
      for (int i = 0; i < 4; i++) hdr_q[i] <= '0;
    end else begin
      state_q <= state_d;
      err_q   <= err_d;
      hdr_q   <= hdr_d;

      if (bus_err_i) bus_err_q <= 1'b1;

      // The strap is sampled once, on the first cycle out of reset, and then
      // ignored: it is a board-level tie, and a glitch on it mid-run must not
      // change what the chip is doing. A BOOT_CTRL re-boot re-enters S_DELAY
      // but does NOT re-sample -- the override bits carry that intent.
      if (!strap_valid_q) begin
        strap_q       <= boot_sel_i;
        strap_valid_q <= 1'b1;
      end

      if (ctrl_retry_i)         force_flash_q <= 1'b1;
      else if (state_q == S_DONE || state_q == S_FAIL) force_flash_q <= 1'b0;
      if (ctrl_boot_rom_i)      force_rom_q <= 1'b1;
      else if (state_q == S_DONE || state_q == S_FAIL) force_rom_q <= 1'b0;

      // Record which source this boot used, for BOOT_STATUS.
      if (state_q == S_DELAY && state_d == S_ROM)      source_q <= 2'd1;
      else if (state_q == S_DELAY && state_d == S_CMD) source_q <= 2'd2;
      else if (state_q == S_DELAY && state_d == S_SKIP) source_q <= 2'd0;

      // Counters
      unique case (state_q)
        S_DELAY: begin
          delay_q    <= (state_d == S_DELAY) ? delay_q + 20'd1 : 20'd0;
          byte_idx_q <= '0;
          off_q      <= '0;
          crc_q      <= 32'hFFFF_FFFF;
          bus_err_q  <= 1'b0;
        end
        S_CMD: begin
          if (eng_done) byte_idx_q <= (byte_idx_q == 5'd3) ? 5'd0 : byte_idx_q + 5'd1;
        end
        S_HDR: begin
          if (eng_done) byte_idx_q <= byte_idx_q + 5'd1;
        end
        S_CHECK: begin
          length_q <= hdr_q[1];
          off_q    <= '0;
        end
        S_ROM: begin
          if (bus_gnt_i) off_q <= off_q + 32'd4;
        end
        S_DATA: begin
          if (eng_done) begin
            word_q[8*off_q[1:0] +: 8] <= eng_rx;
            crc_q <= crc32_byte(crc_q, eng_rx);
            off_q <= off_q + 32'd1;
          end
        end
        default: begin end
      endcase

      // fw_valid: set on DONE or release; cleared on retry (core back to reset)
      if (ctrl_retry_i) begin
        fw_valid_q <= 1'b0;
      end else if (state_q == S_VERIFY && state_d == S_DONE) begin
        fw_valid_q <= 1'b1;
      end else if (ctrl_release_i && (state_q == S_SKIP || state_q == S_FAIL || state_q == S_DONE)) begin
        fw_valid_q <= 1'b1;
      end else if (IMEM_PRELOADED && state_q == S_SKIP) begin
        fw_valid_q <= 1'b1;
      end
    end
  end

  // Which source this boot is using. from_rom_q distinguishes the two at
  // S_VERIFY, where the CRC applies to a flash image only.
  wire boot_from_flash = (strap_q || force_flash_q) && !force_rom_q;
  wire from_rom_q      = (source_q == 2'd1);

  // Bus write. The flash path assembles a word from four received bytes and
  // writes it at off_q-4 (off_q has already advanced); the ROM path writes
  // the word at off_q directly and advances on the grant.
  assign bus_we_o    = 1'b1;
  assign bus_be_o    = 4'b1111;
  assign bus_addr_o  = (state_q == S_ROM) ? off_q       : (off_q - 32'd4);
  assign bus_wdata_o = (state_q == S_ROM) ? rom_data_i  : word_q;

  assign fw_valid_o  = fw_valid_q;
  assign boot_fail_o = (state_q == S_FAIL);

  // --------------------------------------------------------------------------
  // Firmware-owned SPI peripheral (after boot)
  // --------------------------------------------------------------------------
  logic        fw_cs_n_q;
  logic [7:0]  fw_div_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fw_cs_n_q <= 1'b1;
      fw_div_q  <= BOOT_CLK_DIV;
    end else if (spi_ctrl_we_i) begin
      fw_cs_n_q <= spi_ctrl_wdata_i[0];
      fw_div_q  <= spi_ctrl_wdata_i[15:8];
    end
  end

  // Engine / pin ownership mux
  assign eng_start  = boot_owns ? boot_start : (spi_data_we_i && !eng_busy);
  assign eng_tx     = boot_owns ? boot_tx    : spi_data_wdata_i;
  assign eng_div    = boot_owns ? BOOT_CLK_DIV : fw_div_q;
  assign spi_cs_n_o = boot_owns ? boot_cs_n  : fw_cs_n_q;

  // Register read-back
  assign boot_status_o = {hdr_q[2][15:0], 2'd0, source_q, in_boot,
                          boot_fail_o, strap_q, fw_valid_q, 1'b0, err_q, state_q};
  assign spi_ctrl_o    = {16'd0, fw_div_q, 7'd0, fw_cs_n_q};
  assign spi_rx_o      = eng_rx;
  assign spi_status_o  = {30'd0, !boot_owns, eng_busy};

  // Unused
  wire unused_bus = bus_rvalid_i | (|bus_rdata_i);

endmodule

// -----------------------------------------------------------------------------
// Behavioural SPI NOR flash (mode 0) for simulation: READ (0x03) only.
//
//   CS_N low, then 8 command bits + 24 address bits shifted in MSB first on
//   rising SCK; from the falling edge after the last address bit the model
//   drives successive bytes MSB first, auto-incrementing the address, until
//   CS_N rises. Any other command returns 0xFF. Unprogrammed bytes read 0xFF
//   (erased), like a real part; `mem` is writable from the testbench so an
//   image can be corrupted or replaced between resets.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_spi_flash_model #(
  parameter string       IMAGE = "agriasic_fw_flash.hex",   // one byte per line
  parameter int unsigned SIZE  = 65536
) (
  input  logic sck_i,
  input  logic cs_n_i,
  input  logic mosi_i,
  output logic miso_o
);

  logic [7:0] mem [0:SIZE-1];

  initial begin
    for (int i = 0; i < SIZE; i++) mem[i] = 8'hFF;
    if (IMAGE != "") $readmemh(IMAGE, mem);
  end

  logic [31:0] shift_q;      // command + address
  int unsigned bit_cnt;
  logic        reading;
  logic [23:0] addr;
  logic [7:0]  out_byte;
  int unsigned out_bit;      // 7..0, next bit to present

  always @(posedge cs_n_i or negedge cs_n_i) begin
    if (cs_n_i) begin
      reading  = 1'b0;
      bit_cnt  = 0;
      miso_o   = 1'b0;
    end else begin
      bit_cnt  = 0;
      reading  = 1'b0;
    end
  end

  initial begin
    miso_o  = 1'b0;
    reading = 1'b0;
    bit_cnt = 0;
  end

  // Capture command/address on rising edges.
  always @(posedge sck_i) begin
    if (!cs_n_i && !reading) begin
      shift_q = {shift_q[30:0], mosi_i};
      bit_cnt++;
      if (bit_cnt == 32) begin
        if (shift_q[31:24] == 8'h03) begin
          addr     = shift_q[23:0];
          out_byte = mem[addr];
          out_bit  = 7;
          reading  = 1'b1;
        end else begin
          out_byte = 8'hFF;
          out_bit  = 7;
          reading  = 1'b1;
          addr     = 24'hFF_FFFF;   // "other command": stream 0xFF
        end
      end
    end
  end

  // Drive data on falling edges (master samples on the next rising edge).
  always @(negedge sck_i) begin
    if (!cs_n_i && reading) begin
      miso_o = out_byte[out_bit];
      if (out_bit == 0) begin
        out_bit = 7;
        if (addr != 24'hFF_FFFF) begin
          addr     = addr + 24'd1;
          out_byte = mem[addr];
        end
      end else begin
        out_bit--;
      end
    end
  end

endmodule

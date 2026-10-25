// -----------------------------------------------------------------------------
// Module: agriasic_boot_rom
// Purpose:
//   Golden firmware image, synthesized as a constant table. This is what a
//   bare chip runs: with the BOOT_SEL strap low, agriasic_spi_boot copies
//   these words into the IMEM SRAM at reset and releases the core.
//
//   GENERATED FILE -- do not edit by hand.
//     source : fw/golden/agriasic_fw_golden.hex (148 words, 592 bytes)
//     sha256 : 81cffa2c0fc85ca32f1c50db801f3d6a57f59fe6737293b8dbcdf74df31aac52
//     regen  : python3 fw/gen_boot_rom.py
//
// Why a table and not a memory array:
//   These are constants, so synthesis maps the case statement into gates --
//   roughly a few thousand for an image this size in 180 nm -- rather than
//   8192 storage bits. There is no clock and no reset here; the
//   copier registers the data on its way into the SRAM.
//
// Why shadow-load instead of fetching from the ROM directly:
//   The core always fetches from the IMEM SRAM, so (a) nothing is added to
//   the fetch path's timing, (b) firmware is linked once, at one address, for
//   both boot sources, and (c) IMEM stays WRITABLE after a ROM boot -- a
//   debugger can halt, patch a constant over JTAG and resume, which a
//   fetch-from-ROM arrangement could not do.
//
// Unused words read as the RV32 canonical NOP so a fetch past the image is
// defined rather than undriven.
// -----------------------------------------------------------------------------
module agriasic_boot_rom #(
  parameter int unsigned NUM_WORDS  = 256,
  // What the instantiator believes the image length is. Checked below against
  // the table actually generated into this file.
  parameter int unsigned USED_WORDS = 148
) (
  input  logic [31:0] addr_i,   // byte address; [1:0] ignored (4B aligned)
  output logic [31:0] data_o
);

  localparam int unsigned AddrLsb = 2;
  localparam int unsigned AddrMsb = $clog2(NUM_WORDS) + AddrLsb - 1;

  // Ground truth, rewritten on every regeneration alongside the table below.
  // The shell carries its own ROM_USED_WORDS; if the two ever drift, the copier
  // would load a truncated or over-long image and the chip would silently run
  // something that is not the golden image. Fail loudly instead.
  localparam int unsigned GENERATED_USED_WORDS = 148;

`ifndef SYNTHESIS
  initial
    if (USED_WORDS != GENERATED_USED_WORDS)
      $fatal(1, "agriasic_boot_rom: USED_WORDS (%0d) does not match the generated table (%0d) -- regenerate with fw/gen_boot_rom.py",
             USED_WORDS, GENERATED_USED_WORDS);
`endif

  wire [AddrMsb-AddrLsb:0] word_addr = addr_i[AddrMsb:AddrLsb];

  always_comb begin
    unique case (word_addr)
      8'd0: data_o = 32'h0A20006F;
      8'd1: data_o = 32'h09E0006F;
      8'd2: data_o = 32'h09A0006F;
      8'd3: data_o = 32'h0960006F;
      8'd4: data_o = 32'h0920006F;
      8'd5: data_o = 32'h08E0006F;
      8'd6: data_o = 32'h08A0006F;
      8'd7: data_o = 32'h0860006F;
      8'd8: data_o = 32'h0820006F;
      8'd9: data_o = 32'h07E0006F;
      8'd10: data_o = 32'h07A0006F;
      8'd11: data_o = 32'h0760006F;
      8'd12: data_o = 32'h0720006F;
      8'd13: data_o = 32'h06E0006F;
      8'd14: data_o = 32'h06A0006F;
      8'd15: data_o = 32'h0660006F;
      8'd16: data_o = 32'h0620006F;
      8'd17: data_o = 32'h05E0006F;
      8'd18: data_o = 32'h05A0006F;
      8'd19: data_o = 32'h0560006F;
      8'd20: data_o = 32'h0520006F;
      8'd21: data_o = 32'h04E0006F;
      8'd22: data_o = 32'h04A0006F;
      8'd23: data_o = 32'h0460006F;
      8'd24: data_o = 32'h0420006F;
      8'd25: data_o = 32'h03E0006F;
      8'd26: data_o = 32'h03A0006F;
      8'd27: data_o = 32'h0360006F;
      8'd28: data_o = 32'h0320006F;
      8'd29: data_o = 32'h02E0006F;
      8'd30: data_o = 32'h02A0006F;
      8'd31: data_o = 32'h0260006F;
      8'd32: data_o = 32'h00010117;
      8'd33: data_o = 32'h10010113;
      8'd34: data_o = 32'h907362C1;
      8'd35: data_o = 32'h201D3042;
      8'd36: data_o = 32'h800002B7;
      8'd37: data_o = 32'h10000313;
      8'd38: data_o = 32'h0062A023;
      8'd39: data_o = 32'h10500073;
      8'd40: data_o = 32'h02B7BFF5;
      8'd41: data_o = 32'h03138000;
      8'd42: data_o = 32'hA0232000;
      8'd43: data_o = 32'h00730062;
      8'd44: data_o = 32'hBFF51050;
      8'd45: data_o = 32'hD6227179;
      8'd46: data_o = 32'hD24AD426;
      8'd47: data_o = 32'hCC56CE52;
      8'd48: data_o = 32'hC85ECA5A;
      8'd49: data_o = 32'hC662D04E;
      8'd50: data_o = 32'hC26AC466;
      8'd51: data_o = 32'h07B7C06E;
      8'd52: data_o = 32'h07138000;
      8'd53: data_o = 32'hC3980820;
      8'd54: data_o = 32'hC3D84709;
      8'd55: data_o = 32'h800007B7;
      8'd56: data_o = 32'h0E37C798;
      8'd57: data_o = 32'h07B78000;
      8'd58: data_o = 32'h47058000;
      8'd59: data_o = 32'h0E13CB98;
      8'd60: data_o = 32'h079303CE;
      8'd61: data_o = 32'h66C12000;
      8'd62: data_o = 32'h80000EB7;
      8'd63: data_o = 32'h80000637;
      8'd64: data_o = 32'h80000F37;
      8'd65: data_o = 32'h80000FB7;
      8'd66: data_o = 32'h800002B7;
      8'd67: data_o = 32'h800003B7;
      8'd68: data_o = 32'h64896441;
      8'd69: data_o = 32'h00FE2023;
      8'd70: data_o = 32'h86934701;
      8'd71: data_o = 32'h47850206;
      8'd72: data_o = 32'h45890EB1;
      8'd73: data_o = 32'h06514905;
      8'd74: data_o = 32'h0FF10F61;
      8'd75: data_o = 32'h03428293;
      8'd76: data_o = 32'h03838393;
      8'd77: data_o = 32'h4A21147D;
      8'd78: data_o = 32'h4B114A8D;
      8'd79: data_o = 32'h84934B95;
      8'd80: data_o = 32'hA0237104;
      8'd81: data_o = 32'h498900FE;
      8'd82: data_o = 32'h48014501;
      8'd83: data_o = 32'h43014881;
      8'd84: data_o = 32'h80000C37;
      8'd85: data_o = 32'h20234C85;
      8'd86: data_o = 32'h0073019C;
      8'd87: data_o = 32'h2C031050;
      8'd88: data_o = 32'h7C130006;
      8'd89: data_o = 32'h1CE3001C;
      8'd90: data_o = 32'h2C03FE0C;
      8'd91: data_o = 32'h7C130006;
      8'd92: data_o = 32'h1463100C;
      8'd93: data_o = 32'h2D830A0C;
      8'd94: data_o = 32'hAD03000F;
      8'd95: data_o = 32'hAC83000F;
      8'd96: data_o = 32'hAC030002;
      8'd97: data_o = 32'h936E0003;
      8'd98: data_o = 32'h986698EA;
      8'd99: data_o = 32'h94639562;
      8'd100: data_o = 32'h43330929;
      8'd101: data_o = 32'hC29C02B3;
      8'd102: data_o = 32'h000E2C03;
      8'd103: data_o = 32'h00062983;
      8'd104: data_o = 32'h00030CB7;
      8'd105: data_o = 32'h008C7C33;
      8'd106: data_o = 32'hF9B309BA;
      8'd107: data_o = 32'h87930199;
      8'd108: data_o = 32'hE9B30A06;
      8'd109: data_o = 32'hA0230189;
      8'd110: data_o = 32'h87930137;
      8'd111: data_o = 32'h07050806;
      8'd112: data_o = 32'h02B8C8B3;
      8'd113: data_o = 32'h0266A023;
      8'd114: data_o = 32'h02B84833;
      8'd115: data_o = 32'h0516A023;
      8'd116: data_o = 32'h02B54533;
      8'd117: data_o = 32'h0706A023;
      8'd118: data_o = 32'h0063C388;
      8'd119: data_o = 32'h47A90547;
      8'd120: data_o = 32'h03270963;
      8'd121: data_o = 32'h02000793;
      8'd122: data_o = 32'h02B70563;
      8'd123: data_o = 32'h06400793;
      8'd124: data_o = 32'h03570163;
      8'd125: data_o = 32'h13C00793;
      8'd126: data_o = 32'h01670D63;
      8'd127: data_o = 32'h3E800793;
      8'd128: data_o = 32'h01770963;
      8'd129: data_o = 32'h45196785;
      8'd130: data_o = 32'hC5A78793;
      8'd131: data_o = 32'h00A70363;
      8'd132: data_o = 32'h069187A6;
      8'd133: data_o = 32'h4985B73D;
      8'd134: data_o = 32'h67C1BF25;
      8'd135: data_o = 32'hC79456FD;
      8'd136: data_o = 32'h468967C1;
      8'd137: data_o = 32'h5432C394;
      8'd138: data_o = 32'h07B7C3D8;
      8'd139: data_o = 32'h07138000;
      8'd140: data_o = 32'hC3980800;
      8'd141: data_o = 32'h591254A2;
      8'd142: data_o = 32'h4A725982;
      8'd143: data_o = 32'h4B524AE2;
      8'd144: data_o = 32'h4C324BC2;
      8'd145: data_o = 32'h4D124CA2;
      8'd146: data_o = 32'h45014D82;
      8'd147: data_o = 32'h80826145;
      default: data_o = 32'h0000_0013;   // RV32 NOP
    endcase
  end

endmodule

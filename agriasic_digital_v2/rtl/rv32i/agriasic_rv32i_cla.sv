/* 
   Taarana Jammula (tjammula)
   Krishna Karthikeya Chemudupati (krishkc)
 */

`timescale 1ns / 1ps

/**
 * @param a first 1-bit input
 * @param b second 1-bit input
 * @param g whether a and b generate a carry
 * @param p whether a and b would propagate an incoming carry
 */
module gp1(input wire a, b,
           output wire g, p);
   assign g = a & b;
   assign p = a | b;
endmodule

/**
 * Computes aggregate generate/propagate signals over a 4-bit window.
 * @param gin incoming generate signals
 * @param pin incoming propagate signals
 * @param cin the incoming carry
 * @param gout whether these 4 bits internally would generate a carry-out (independent of cin)
 * @param pout whether these 4 bits internally would propagate an incoming carry from cin
 * @param cout the carry outs for the low-order 3 bits
 */
module gp4(input wire [3:0] gin, pin,
           input wire cin,
           output wire gout, pout,
           output wire [2:0] cout);

   assign pout = pin[3] & pin[2] & pin[1] & pin[0];

   assign gout = gin[3] |
                 (pin[3] & gin[2]) |
                 (pin[3] & pin[2] & gin[1]) |
                 (pin[3] & pin[2] & pin[1] & gin[0]);

   assign cout[0] = gin[0] | (pin[0] & cin);

   assign cout[1] = gin[1] |
                    (pin[1] & gin[0]) |
                    (pin[1] & pin[0] & cin);

   assign cout[2] = gin[2] |
                    (pin[2] & gin[1]) |
                    (pin[2] & pin[1] & gin[0]) |
                    (pin[2] & pin[1] & pin[0] & cin);

   // cout[3] is not computed because it equals gout | (pout & cin)

endmodule

/** Same as gp4 but for an 8-bit window instead */
module gp8(input wire [7:0] gin, pin,
           input wire cin,
           output wire gout, pout,
           output wire [6:0] cout);

   // Aggregate propagate: all 8 bits must propagate
   assign pout = &pin;

   // Aggregate generate: carry generated at any position considering propagation from lower bits
   assign gout = gin[7] |
                 (pin[7] & gin[6]) |
                 (pin[7] & pin[6] & gin[5]) |
                 (pin[7] & pin[6] & pin[5] & gin[4]) |
                 (pin[7] & pin[6] & pin[5] & pin[4] & gin[3]) |
                 (pin[7] & pin[6] & pin[5] & pin[4] & pin[3] & gin[2]) |
                 (pin[7] & pin[6] & pin[5] & pin[4] & pin[3] & pin[2] & gin[1]) |
                 (pin[7] & pin[6] & pin[5] & pin[4] & pin[3] & pin[2] & pin[1] & gin[0]);

   assign cout[0] = gin[0] | (pin[0] & cin);

   assign cout[1] = gin[1] |
                    (pin[1] & gin[0]) |
                    (pin[1] & pin[0] & cin);

   assign cout[2] = gin[2] |
                    (pin[2] & gin[1]) |
                    (pin[2] & pin[1] & gin[0]) |
                    (pin[2] & pin[1] & pin[0] & cin);

   assign cout[3] = gin[3] |
                    (pin[3] & gin[2]) |
                    (pin[3] & pin[2] & gin[1]) |
                    (pin[3] & pin[2] & pin[1] & gin[0]) |
                    (pin[3] & pin[2] & pin[1] & pin[0] & cin);

   assign cout[4] = gin[4] |
                    (pin[4] & gin[3]) |
                    (pin[4] & pin[3] & gin[2]) |
                    (pin[4] & pin[3] & pin[2] & gin[1]) |
                    (pin[4] & pin[3] & pin[2] & pin[1] & gin[0]) |
                    (pin[4] & pin[3] & pin[2] & pin[1] & pin[0] & cin);

   assign cout[5] = gin[5] |
                    (pin[5] & gin[4]) |
                    (pin[5] & pin[4] & gin[3]) |
                    (pin[5] & pin[4] & pin[3] & gin[2]) |
                    (pin[5] & pin[4] & pin[3] & pin[2] & gin[1]) |
                    (pin[5] & pin[4] & pin[3] & pin[2] & pin[1] & gin[0]) |
                    (pin[5] & pin[4] & pin[3] & pin[2] & pin[1] & pin[0] & cin);

   assign cout[6] = gin[6] |
                    (pin[6] & gin[5]) |
                    (pin[6] & pin[5] & gin[4]) |
                    (pin[6] & pin[5] & pin[4] & gin[3]) |
                    (pin[6] & pin[5] & pin[4] & pin[3] & gin[2]) |
                    (pin[6] & pin[5] & pin[4] & pin[3] & pin[2] & gin[1]) |
                    (pin[6] & pin[5] & pin[4] & pin[3] & pin[2] & pin[1] & gin[0]) |
                    (pin[6] & pin[5] & pin[4] & pin[3] & pin[2] & pin[1] & pin[0] & cin);

   //cout[7] is not computed because it equals gout | (pout & cin)

endmodule

module CarryLookaheadAdder
  (input wire [31:0]  a, b,
   input wire         cin,
   output wire [31:0] sum);

   wire [31:0] g, p;

   genvar i;
   generate
      for (i = 0; i < 32; i = i + 1) begin : gp1_gen
         gp1 gp1_inst (
            .a(a[i]),
            .b(b[i]),
            .g(g[i]),
            .p(p[i])
         );
      end
   endgenerate

   wire [3:0] g8, p8;        
   wire [6:0] c8_0, c8_1, c8_2, c8_3;  

   wire [2:0] c_between_blocks;
   wire g_top, p_top;  //g/p for entire 32-bit adder

   gp8 gp8_0 (.gin(g[7:0]),   .pin(p[7:0]),   .cin(cin),                   .gout(g8[0]), .pout(p8[0]), .cout(c8_0));
   gp8 gp8_1 (.gin(g[15:8]),  .pin(p[15:8]),  .cin(c_between_blocks[0]),  .gout(g8[1]), .pout(p8[1]), .cout(c8_1));
   gp8 gp8_2 (.gin(g[23:16]), .pin(p[23:16]), .cin(c_between_blocks[1]),  .gout(g8[2]), .pout(p8[2]), .cout(c8_2));
   gp8 gp8_3 (.gin(g[31:24]), .pin(p[31:24]), .cin(c_between_blocks[2]),  .gout(g8[3]), .pout(p8[3]), .cout(c8_3));

   gp4 gp4_top (
      .gin(g8),
      .pin(p8),
      .cin(cin),
      .gout(g_top),  // Aggregate generate for entire 32-bit adder
      .pout(p_top),  // Aggregate propagate for entire 32-bit adder 
      .cout(c_between_blocks)
   );

   assign sum[0] = a[0] ^ b[0] ^ cin;
   assign sum[7:1] = a[7:1] ^ b[7:1] ^ c8_0[6:0];
   assign sum[8] = a[8] ^ b[8] ^ c_between_blocks[0];
   assign sum[15:9] = a[15:9] ^ b[15:9] ^ c8_1[6:0];
   assign sum[16] = a[16] ^ b[16] ^ c_between_blocks[1];
   assign sum[23:17] = a[23:17] ^ b[23:17] ^ c8_2[6:0];
   assign sum[24] = a[24] ^ b[24] ^ c_between_blocks[2];
   assign sum[31:25] = a[31:25] ^ b[31:25] ^ c8_3[6:0];

endmodule

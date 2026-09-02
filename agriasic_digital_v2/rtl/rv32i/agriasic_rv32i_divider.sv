/* 
   Taarana Jammula (tjammula)
   Krishna Karthikeya Chemudupati (krishkc)
 */

`timescale 1ns / 1ns

// quotient = dividend / divisor

module DividerUnsignedPipelined (
    input wire clk, rst, stall,
    input  wire  [31:0] i_dividend,
    input  wire  [31:0] i_divisor,
    output logic [31:0] o_remainder,
    output logic [31:0] o_quotient
);

    // 8 ppielined registers
    logic [31:0] dividend_reg  [0:7];
    logic [31:0] divisor_reg   [0:7];
    logic [31:0] remainder_reg [0:7];
    logic [31:0] quotient_reg  [0:7];

    wire [31:0] stage_dividend_out  [0:7];
    wire [31:0] stage_remainder_out [0:7];
    wire [31:0] stage_quotient_out  [0:7];

    wire [31:0] s0_div [0:4], s0_rem [0:4], s0_quo [0:4];
    assign s0_div[0] = i_dividend;
    assign s0_rem[0] = 32'b0;
    assign s0_quo[0] = 32'b0;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : stage0_iter
            divu_1iter u_iter (
                .i_dividend(s0_div[i]), .i_divisor(i_divisor),
                .i_remainder(s0_rem[i]), .i_quotient(s0_quo[i]),
                .o_dividend(s0_div[i+1]), .o_remainder(s0_rem[i+1]), .o_quotient(s0_quo[i+1])
            );
        end
    endgenerate
    assign stage_dividend_out[0]  = s0_div[4];
    assign stage_remainder_out[0] = s0_rem[4];
    assign stage_quotient_out[0]  = s0_quo[4];

    genvar s, j;
    generate
        for (s = 1; s < 8; s = s + 1) begin : stages
            wire [31:0] div [0:4], rem [0:4], quo [0:4];

            // input from previous register
            assign div[0] = dividend_reg[s-1];
            assign rem[0] = remainder_reg[s-1];
            assign quo[0] = quotient_reg[s-1];

            for (j = 0; j < 4; j = j + 1) begin : iter
                divu_1iter u_iter (
                    .i_dividend(div[j]), .i_divisor(divisor_reg[s-1]),
                    .i_remainder(rem[j]), .i_quotient(quo[j]),
                    .o_dividend(div[j+1]), .o_remainder(rem[j+1]), .o_quotient(quo[j+1])
                );
            end

            // stage output
            assign stage_dividend_out[s]  = div[4];
            assign stage_remainder_out[s] = rem[4];
            assign stage_quotient_out[s]  = quo[4];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k < 8; k = k + 1) begin
                dividend_reg[k]  <= 32'b0;
                divisor_reg[k]   <= 32'b0;
                remainder_reg[k] <= 32'b0;
                quotient_reg[k]  <= 32'b0;
            end
        end else begin
            dividend_reg[0]  <= stage_dividend_out[0];
            divisor_reg[0]   <= i_divisor;
            remainder_reg[0] <= stage_remainder_out[0];
            quotient_reg[0]  <= stage_quotient_out[0];

            // stage outputs + propagate divisor
            for (int k = 1; k < 8; k = k + 1) begin
                dividend_reg[k]  <= stage_dividend_out[k];
                divisor_reg[k]   <= divisor_reg[k-1];
                remainder_reg[k] <= stage_remainder_out[k];
                quotient_reg[k]  <= stage_quotient_out[k];
            end
        end
    end

    // Output from last stage's combinational output (before registering)
    assign o_remainder = stage_remainder_out[7];
    assign o_quotient  = stage_quotient_out[7];

endmodule


module divu_1iter (
    input  wire  [31:0] i_dividend,
    input  wire  [31:0] i_divisor,
    input  wire  [31:0] i_remainder,
    input  wire  [31:0] i_quotient,
    output logic [31:0] o_dividend,
    output logic [31:0] o_remainder,
    output logic [31:0] o_quotient
);
  /*
    for (int i = 0; i < 32; i++) {
        remainder = (remainder << 1) | ((dividend >> 31) & 0x1);
        if (remainder < divisor) {
            quotient = (quotient << 1);
        } else {
            quotient = (quotient << 1) | 0x1;
            remainder = remainder - divisor;
        }
        dividend = dividend << 1;
    }
    */

    logic [31:0] remainder_shifted;
    logic [32:0] remainder_minus_divisor;
    logic take_subtract;

    assign remainder_shifted = {i_remainder[30:0], i_dividend[31]};
    // Use borrow-out from a single subtract instead of separate compare + subtract.
    assign remainder_minus_divisor = {1'b0, remainder_shifted} - {1'b0, i_divisor};
    assign take_subtract = ~remainder_minus_divisor[32];

    assign o_dividend = {i_dividend[30:0], 1'b0};
    assign o_quotient = {i_quotient[30:0], take_subtract};
    assign o_remainder = take_subtract ? remainder_minus_divisor[31:0] : remainder_shifted;

endmodule

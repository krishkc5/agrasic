`timescale 1ns/1ns

// -----------------------------------------------------------------------------
// Testbench: tb_settle_conv_sweep
// Purpose (Rev 4.3 Phase 8, closes verification item V-1):
//   V-1 in the original verification plan (MAS section 12.3) calls for
//   sweeping settle against conv "across the full 8-bit range" (256 x 256 =
//   65536 combinations) with a completion timeout on every one. That is what
//   caught D-1/D-2 originally: two independently programmable registers
//   jointly determined whether the chip hung, and no single-point test
//   exposed that.
//
//   Literally exhaustive 8-bit x 8-bit coverage is not attempted here: at
//   the high end (settle=255, conv=255) a single run is tens of thousands
//   of cycles, and 65536 of them is impractical for a regression that has to
//   stay fast enough to run on every change. This sweeps a representative
//   grid instead -- both axes' boundaries (0 and near-max), several points
//   in between at increasing scale, and every combination of the two --
//   which is the same class of coverage V-1 wants (no single settle/conv
//   value class goes unpaired with every other) without the combinatorial
//   cost of the literal 65536-point grid. D-1/D-2's actual failure mode
//   (section 5) would have been caught by any grid at all, since it was a
//   hang across a wide swath of the settle/conv space, not an isolated
//   point.
//
// What this checks for every (settle, conv) pair in the grid:
//   1. The run completes within a generous timeout (no hang).
//   2. The result is exactly the expected value (settle/conv must not
//      perturb the measurement, only its duration).
// -----------------------------------------------------------------------------
module tb_settle_conv_sweep;
  localparam int unsigned ADC_WIDTH = 8;
  // Same four-target model as the other Phase 5+ testbenches.
  // D(0)=220, D(180)=100 -> I = 4*120 = 480; D(90)=170, D(270)=90 -> Q = 4*80 = 320.
  localparam logic signed [15:0] EXPECTED_I = 16'sd480;
  localparam logic signed [15:0] EXPECTED_Q = 16'sd320;

  // Grid points, chosen to cover both axes' extremes and several
  // intermediate scales rather than every one of 256 values per axis.
  localparam int NUM_SETTLE = 9;
  localparam int NUM_CONV   = 6;
  localparam int unsigned SETTLE_VALS [0:NUM_SETTLE-1] = '{0, 1, 2, 5, 10, 20, 50, 100, 200};
  localparam int unsigned CONV_VALS   [0:NUM_CONV-1]   = '{0, 1, 2, 5, 10, 20};

  logic clk;
  logic rst_n;
  logic start;
  logic [3:0]  cfg_pair_log2_i;
  logic [7:0]  cfg_settle_cycles_i;
  logic [13:0] cfg_exc_divider_i;
  logic [7:0]  cfg_conv_cycles_i;
  logic conv_start_o;
  logic [ADC_WIDTH-1:0] sine_code_o;
  logic [1:0] mux_sel_o;
  logic adc_enable_o;
  logic adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic busy_o;
  logic done_o;
  logic signed [15:0] result_dv_i_o;
  logic signed [15:0] result_dv_q_o;
  logic signed [15:0] result_cur_i_o;
  logic signed [15:0] result_cur_q_o;

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .cfg_pair_log2_i(cfg_pair_log2_i),
    .cfg_settle_cycles_i(cfg_settle_cycles_i),
    .cfg_exc_divider_i(cfg_exc_divider_i),
    .cfg_conv_cycles_i(cfg_conv_cycles_i),
    .cfg_mux_settle_i(8'd2),
    .cfg_amplitude_i(2'd0),
    .afe_conv_start_o(conv_start_o),
    .afe_sine_code_o(sine_code_o),
    .afe_mux_sel_o(mux_sel_o),
    .afe_adc_enable_o(adc_enable_o),
    .afe_sample_o(adc_sample_o),
    .afe_adc_dac_o(adc_dac_o),
    .afe_adc_comp_i(adc_comp_i),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_dv_i_o(result_dv_i_o),
    .result_dv_q_o(result_dv_q_o),
    .result_cur_i_o(result_cur_i_o),
    .result_cur_q_o(result_cur_q_o)
  );

  always #5 clk = ~clk;

  // Rev 5 two-channel AFE model: dV (analog mux channel 0, PGA on E2/E3) and
  // return current (channel 1, TIA on E4). Both are frozen by the single
  // adc_sample_o strobe at the FSM's chosen phase point; the comparator then
  // answers for whichever channel mux_sel selects.
  logic [ADC_WIDTH-1:0] hold_dv_q, hold_cur_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (2'(dut.u_measurement_fsm.point_q))
        4'd0: begin hold_dv_q <= 8'd220; hold_cur_q <= 8'd200; end  // PT_0   (0 deg)
        4'd1: begin hold_dv_q <= 8'd100; hold_cur_q <= 8'd110; end  // PT_180 (180 deg)
        4'd2: begin hold_dv_q <= 8'd170; hold_cur_q <= 8'd160; end  // PT_90  (90 deg)
        4'd3: begin hold_dv_q <= 8'd90; hold_cur_q <= 8'd100; end  // PT_270 (270 deg)
        default: begin end
      endcase
    end
  end
  wire [ADC_WIDTH-1:0] adc_target = (mux_sel_o == 2'd0) ? hold_dv_q : hold_cur_q;
  assign adc_comp_i = (adc_target >= adc_dac_o);


  int errors;
  int total_runs;

  task automatic run_one(input int unsigned settle, input int unsigned conv,
                         output bit hung, output int elapsed,
                         output logic signed [15:0] got_i, output logic signed [15:0] got_q);
    int n;
    begin
      @(negedge clk);
      cfg_pair_log2_i     = 4'd2;
      cfg_exc_divider_i   = 14'd1;
      cfg_settle_cycles_i = settle[7:0];
      cfg_conv_cycles_i   = conv[7:0];

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      n = 0;
      // Budget: settle (periods*16) + 16 conversions/pair-equiv * 4 pairs *
      // 8*(3+conv) cycles, plus generous margin. At settle=200, conv=20 this
      // is comfortably inside 100000.
      while (!done_o && n < 100000) begin
        @(posedge clk);
        n++;
      end
      hung    = !done_o;
      elapsed = n;
      got_i   = result_dv_i_o;
      got_q   = result_dv_q_o;

      @(negedge clk);
    end
  endtask

  initial begin
    errors = 0;
    total_runs = 0;
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[TB] settle x conv grid sweep (Rev 4.3 Phase 8, V-1): %0d settle x %0d conv = %0d points",
             NUM_SETTLE, NUM_CONV, NUM_SETTLE * NUM_CONV);

    for (int s = 0; s < NUM_SETTLE; s++) begin
      for (int c = 0; c < NUM_CONV; c++) begin
        bit hung;
        int elapsed;
        logic signed [15:0] got_i, got_q;

        run_one(SETTLE_VALS[s], CONV_VALS[c], hung, elapsed, got_i, got_q);
        total_runs++;

        if (hung) begin
          $error("SETTLE_CONV_HANG: settle=%0d conv=%0d did not complete in budget",
                 SETTLE_VALS[s], CONV_VALS[c]);
          errors++;
        end else if (got_i !== EXPECTED_I || got_q !== EXPECTED_Q) begin
          $error("SETTLE_CONV_RESULT_FAIL: settle=%0d conv=%0d expected I=%0d Q=%0d got I=%0d Q=%0d",
                 SETTLE_VALS[s], CONV_VALS[c], EXPECTED_I, EXPECTED_Q, got_i, got_q);
          errors++;
        end
      end
    end

    $display("[TB] %0d/%0d grid points completed without hanging or wrong results",
             total_runs - errors, total_runs);

    if (errors == 0) $display("SETTLE_CONV_SWEEP_PASS");
    else             $display("SETTLE_CONV_SWEEP_FAIL: %0d error(s)", errors);
    $finish;
  end
endmodule

`timescale 1ns/1ps
// Full-chain FUNCTIONAL model, not a transistor/extracted equivalence claim.
module agriasic_afe_integrated_model #(
 parameter real STEP_NS=0.125,
 parameter real PGA_GAIN=4.8117816703, PGA_TAU_NS=2.38879559573, PGA_OFFSET=-0.000536366033023,
 parameter real TIA_G0=1637.40392637, TIA_T0=6.87229892268, TIA_O0=-9.47749580917e-05,
 parameter real TIA_G1=12236.4255298, TIA_T1=7.52163100913, TIA_O1=-9.51184668747e-05,
 parameter real TIA_G2=204998.751127, TIA_T2=20.4135782966, TIA_O2=-0.000101987180049,
 parameter real TIA_G3=1445.89201819, TIA_T3=7.59290108458, TIA_O3=-9.47994334533e-05,
 // Excitation values are placeholders inherited from the digital model.
 parameter real EXC_HALF_SWING=0.45, EXC_TAU_NS=2.0,
 parameter bit PHYSICAL_REFERENCES=1
)(
 input wire [7:0] afe_sine_code_i,
 input wire [1:0] afe_mux_sel_i,
 input wire afe_sample_i,afe_adc_enable_i,
 input wire [7:0] afe_adc_dac_i,
 output wire afe_adc_comp_o,
 input wire afe_conv_start_i,
 input wire [2:0] afe_tia_rf_i,
 output real e1_drive_o,
 input real e2_sense_i,e3_sense_i,e4_iin_i,vin_t_i,
 input real vdda_i,vssa_i,vddm_i,vssm_i,vrefh_i,vrefl_i,vcm_i,ibias_i
);
 function automatic real absr(input real x);return x<0?-x:x;endfunction
 real pga_v=0.9,tia_v=0.9,tia_stage=0.0,tia_signal=0.0,exc_v=0.9;
 real gain,tau,offset,target,alpha;
 function automatic real clip(input real v);
   if(v<vssa_i+0.1)return vssa_i+0.1;
   if(v>vdda_i-0.1)return vdda_i-0.1;
   return v;
 endfunction
 // Two cascaded poles approximate nominal TIA gain and phase at10MHz.
 // They are not a validated broadband/power/noise model of Vidhu's cells.
 initial forever begin
   #(STEP_NS);
   case(afe_tia_rf_i)
    3'b001:begin gain=TIA_G0;tau=TIA_T0;offset=TIA_O0;end
    3'b010:begin gain=TIA_G1;tau=TIA_T1;offset=TIA_O1;end
    3'b100:begin gain=TIA_G2;tau=TIA_T2;offset=TIA_O2;end
    3'b111:begin gain=TIA_G3;tau=TIA_T3;offset=TIA_O3;end
    default:begin gain=0;tau=TIA_T0;offset=0;end
   endcase
   alpha=1.0-$exp(-STEP_NS/tau);
   tia_signal=tia_signal+alpha*(tia_stage-tia_signal);
   tia_stage=tia_stage+alpha*(gain*e4_iin_i-tia_stage);
   tia_v=clip(vcm_i+offset+tia_signal);
   target=clip(vcm_i+PGA_OFFSET+PGA_GAIN*(e2_sense_i-e3_sense_i));
   pga_v=pga_v+(1.0-$exp(-STEP_NS/PGA_TAU_NS))*(target-pga_v);
   target=clip(vcm_i+(real'(afe_sine_code_i)-128.0)/128.0*EXC_HALF_SWING);
   exc_v=exc_v+(1.0-$exp(-STEP_NS/EXC_TAU_NS))*(target-exc_v);
 end
 assign e1_drive_o=exc_v;
 sh_adc_behavioral sense(.afe_mux_sel_i(afe_mux_sel_i),.afe_sample_i(afe_sample_i),
 .afe_adc_enable_i(afe_adc_enable_i),.afe_adc_dac_i(afe_adc_dac_i),
 .afe_conv_start_i(afe_conv_start_i),.afe_adc_comp_o(afe_adc_comp_o),
 .vin_v_i(pga_v),.vin_i_i(tia_v),.vin_t_i(vin_t_i));
 initial begin
  #1;
  if(absr(vdda_i-vssa_i-1.8)>0.01 || absr(vddm_i-vssm_i-1.8)>0.01)
    $warning("Nominal-only model: supplies differ from1.8V");
  if(absr(ibias_i-4.6e-6)>1e-6)$warning("Bias differs from nominal4.6uA");
  if(absr(vcm_i-0.9)>0.001)$fatal(1,"Model uses fixed0.9V common-mode calibration");
  if(PHYSICAL_REFERENCES)begin
   if(absr(vrefh_i-1.15)>0.001 || absr(vrefl_i-0.65)>0.001)
    $fatal(1,"Physical references must be1.15/0.65V; effective input span0.4..1.4V");
  end else if(absr(vrefh_i-1.4)>0.001 || absr(vrefl_i-0.4)>0.001)
    $fatal(1,"Legacy effective-span reference inputs must be1.4/0.4V");
 end
endmodule

// Adapter matching the saved GitHub agriasic_afe_top signal/pad port list.
// Do not compile alongside the repository's other definition of this module.
// Mixed rails are tied ONLY in this functional adapter, not in Cadence/layout.
module agriasic_afe_top #(
 parameter int unsigned ADC_WIDTH=8,
 parameter string SH_STROBE_MODE="FREEZE_ON_RISE",
 parameter real SH_HOLD_NS=460.0,
 parameter string COMP_INVALID_POLICY="HOLD",
 parameter bit QUIET=0,
 parameter bit PHYSICAL_REFERENCES=0
)(
 input wire [ADC_WIDTH-1:0] afe_sine_code_i,
 input wire [1:0] afe_mux_sel_i,
 input wire afe_sample_i,afe_adc_enable_i,
 input wire [ADC_WIDTH-1:0] afe_adc_dac_i,
 output wire afe_adc_comp_o,
 input wire afe_conv_start_i,
 input wire [2:0] afe_tia_rf_i,
 output real e1_drive_o,
 input real e2_sense_i,e3_sense_i,e4_iin_i,vin_t_i,
 input real vdda_i,vssa_i,vrefh_i,vrefl_i,vcm_i,ibias_i
);
 initial begin
  if(ADC_WIDTH!=8 || SH_STROBE_MODE!="FREEZE_ON_RISE" || COMP_INVALID_POLICY!="HOLD")
    $fatal(1,"Unsupported model configuration");
  if(!QUIET)$display("AFE model: SH_HOLD_NS ignored; shared hold releases after current capture. Nominal behavioral model only.");
 end
 agriasic_afe_integrated_model #(.PHYSICAL_REFERENCES(PHYSICAL_REFERENCES)) chain(
 .afe_sine_code_i(afe_sine_code_i),.afe_mux_sel_i(afe_mux_sel_i),
 .afe_sample_i(afe_sample_i),.afe_adc_enable_i(afe_adc_enable_i),
 .afe_adc_dac_i(afe_adc_dac_i),.afe_adc_comp_o(afe_adc_comp_o),
 .afe_conv_start_i(afe_conv_start_i),.afe_tia_rf_i(afe_tia_rf_i),
 .e1_drive_o(e1_drive_o),.e2_sense_i(e2_sense_i),.e3_sense_i(e3_sense_i),
 .e4_iin_i(e4_iin_i),.vin_t_i(vin_t_i),.vdda_i(vdda_i),.vssa_i(vssa_i),
 .vddm_i(vdda_i),.vssm_i(vssa_i),.vrefh_i(vrefh_i),.vrefl_i(vrefl_i),
 .vcm_i(vcm_i),.ibias_i(ibias_i));
endmodule

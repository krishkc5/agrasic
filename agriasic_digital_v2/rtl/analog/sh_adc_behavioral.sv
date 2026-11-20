`timescale 1ns/1ps
// Simulation-only functional/timing abstraction. NOT analog signoff.
// Inputs vin_v_i/vin_i_i are amplifier OUTPUT voltages, not electrodes.
module sh_adc_behavioral #(
 parameter real VLO=0.4, VHI=1.4,
 parameter real STEP_NS=0.25, ACQUIRE_NS=10.0,
 parameter real DECISION_NS=6.25, RETRACK_NS=18.25,
 parameter real IDLE_RECOVERY_NS=50.0
)(
 input wire [1:0] afe_mux_sel_i,
 input wire afe_sample_i, afe_adc_enable_i,
 input wire [7:0] afe_adc_dac_i,
 input wire afe_conv_start_i,
 output reg afe_adc_comp_o=0,
 input real vin_v_i, vin_i_i, vin_t_i
);
 real held_v=0.9, held_i=0.9, adc_v=0.9;
 real capture_due=-1, decision_due=-1, release_due=-1, idle_due=-1;
 reg holding=0, armed=0;
 reg [1:0] selected=0;
 reg [7:0] last_dac=0;
 // Both hold cells share capture AND release controls.
 always @(posedge afe_sample_i) begin
   held_v=vin_v_i; held_i=vin_i_i; holding=1; release_due=-1; idle_due=-1;
 end
 always @(posedge afe_adc_enable_i) idle_due=-1;
 always @(negedge afe_adc_enable_i) begin
   armed=0;capture_due=-1;decision_due=-1;afe_adc_comp_o=0;
   idle_due=$realtime+IDLE_RECOVERY_NS;
 end
 always @(posedge afe_conv_start_i) if(afe_adc_enable_i) begin
   selected=afe_mux_sel_i;armed=0;afe_adc_comp_o=0;
   capture_due=$realtime+ACQUIRE_NS;decision_due=-1;
   if(afe_mux_sel_i==1)release_due=$realtime+RETRACK_NS;
 end
 initial forever begin
   #(STEP_NS);
   if(!holding)begin held_v=vin_v_i;held_i=vin_i_i;end
   if(idle_due>=0 && $realtime>=idle_due && !afe_adc_enable_i)begin
     holding=0;idle_due=-1;release_due=-1;
   end
   if(release_due>=0 && $realtime>=release_due)begin holding=0;release_due=-1;end
   if(capture_due>=0 && $realtime>=capture_due && afe_adc_enable_i)begin
     case(selected)
       0:adc_v=held_v;
       1:adc_v=held_i;
       2:adc_v=vin_t_i;
       default:begin adc_v=VLO;$warning("Reserved mux channel 3");end
     endcase
     armed=1;capture_due=-1;last_dac=afe_adc_dac_i;
     decision_due=$realtime+DECISION_NS;
   end
   if(armed && afe_adc_enable_i && afe_adc_dac_i!=last_dac)begin
     last_dac=afe_adc_dac_i;decision_due=$realtime+DECISION_NS;
   end
   if(armed && afe_adc_enable_i && decision_due>=0 && $realtime>=decision_due)begin
     afe_adc_comp_o=(adc_v >= VLO+(VHI-VLO)*real'(last_dac)/256.0);
     decision_due=-1;
   end
 end
endmodule

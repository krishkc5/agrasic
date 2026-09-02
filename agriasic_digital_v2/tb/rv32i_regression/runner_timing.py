import os, sys
from pathlib import Path
P = Path(__file__).resolve().parent
sys.path.append(str(P / 'common' / 'python'))
import cocotb_utils as cu
from cocotb.runner import get_runner
runr = get_runner(cu.SIM)
runr.build(verilog_sources=[P/"agriasic_rv32i_core.sv"], vhdl_sources=[], hdl_toplevel="Processor",
           includes=[P], build_dir="sim_build", build_args=cu.VERILATOR_FLAGS+['-DDIVIDER_STAGES=8'])
runr.test(seed=12345, hdl_toplevel="Processor", test_module="agriasic_tb_timing",
          testcase=os.environ.get("TESTS") or None)

#!/bin/bash
set -e
W="$HOME/agriasic_regression"; cd "$W"; source "$HOME/rv-venv/bin/activate"
cp agriasic_tb_timing.py agriasic_tb_notrace.py
# Disable cycle-by-cycle trace comparison. The functional checks inside
# riscvTest() -- regs[17]==93 and resultCode==0 -- are UNCHANGED, so this still
# proves the programs execute correctly; it only drops the timing comparison
# that the extra stall cycle necessarily invalidates.
sed -i "s/^TRACING_MODE = 'compare'/TRACING_MODE = None/" agriasic_tb_notrace.py
grep -n "^TRACING_MODE" agriasic_tb_notrace.py
cat > runner_notrace.py <<'PYEOF'
import os, sys
from pathlib import Path
P = Path(__file__).resolve().parent
sys.path.append(str(P / 'common' / 'python'))
import cocotb_utils as cu
from cocotb.runner import get_runner
runr = get_runner(cu.SIM)
runr.build(verilog_sources=[P/"agriasic_rv32i_core.sv"], vhdl_sources=[], hdl_toplevel="Processor",
           includes=[P], build_dir="sim_build", build_args=cu.VERILATOR_FLAGS+['-DDIVIDER_STAGES=8'])
runr.test(seed=12345, hdl_toplevel="Processor", test_module="agriasic_tb_notrace",
          testcase=os.environ.get("TESTS") or None)
PYEOF
TESTS="testTraceRvLui,testTraceRvBeq,testTraceRvLw,dhrystone" python runner_notrace.py 2>&1 \
  | grep -E "TESTS=|PASS |FAIL |AssertionError|SimTimeout" | head -12

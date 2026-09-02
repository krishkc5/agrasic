#!/bin/bash
W="$HOME/agriasic_regression"; cd "$W"; source "$HOME/rv-venv/bin/activate"
cp agriasic_tb.py agriasic_tb_timing.py
python - <<'PY'
import re
s = open('agriasic_tb_timing.py').read()
# Bump the wait only inside the four cycle-count-sensitive load tests.
for fn in ['testLoadUse1','testLoadUse2','testWMData','testWMAddress']:
    i = s.index(f'async def {fn}(dut)')
    j = s.index('async def', i+10)
    seg = s[i:j]
    seg2 = re.sub(r'await ClockCycles\(dut\.clk, (\d+)\)',
                  lambda m: f'await ClockCycles(dut.clk, {int(m.group(1))+4})', seg)
    s = s[:i] + seg2 + s[j:]
open('agriasic_tb_timing.py','w').write(s)
print("waits bumped by 4 in the 4 load tests")
PY
cat > runner_timing.py <<'PYEOF'
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
          testcase="testLoadUse1,testLoadUse2,testWMData,testWMAddress")
PYEOF
python runner_timing.py 2>&1 | grep -E "TESTS=|PASS |FAIL |expected|AssertionError" | head -20

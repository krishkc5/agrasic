#!/bin/bash
set -e
SRC="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN"
W="$HOME/agriasic_regression"
cp "$SRC/agriasic_digital_v2/rtl/rv32i/agriasic_rv32i_core.sv" "$W/"
cd "$W"; source "$HOME/rv-venv/bin/activate"

# Timing-adjusted variant: only the tests whose hardcoded cycle counts encode
# the OLD pipeline timing. Values checked are unchanged.
cp agriasic_tb.py agriasic_tb_timing.py
python - <<'PY'
s = open('agriasic_tb_timing.py').read()
def bump(fn, old, new):
    global s
    i = s.index(f'async def {fn}(dut)'); j = s.index('async def', i+10)
    seg = s[i:j]; assert old in seg, (fn, old)
    s = s[:i] + seg.replace(old, new, 1) + s[j:]
bump('testLoadUse1',  'await ClockCycles(dut.clk, 8)', 'await ClockCycles(dut.clk, 10)')
bump('testLoadUse2',  'await ClockCycles(dut.clk, 8)', 'await ClockCycles(dut.clk, 10)')
bump('testWMAddress', 'await ClockCycles(dut.clk, 5)', 'await ClockCycles(dut.clk, 7)')
# testWMData intentionally left at its original cycle count.
open('agriasic_tb_timing.py','w').write(s)
print("cycle counts adjusted: LoadUse1/2 +2, WMAddress +2, WMData unchanged")
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
          testcase=os.environ.get("TESTS") or None)
PYEOF

echo "=== load/store tests ==="
TESTS="testLoadUse1,testLoadUse2,testWMData,testWMAddress,testLoadFalseUse" \
  python runner_timing.py 2>&1 | grep -E "TESTS=|PASS  |FAIL  |AssertionError" | head -12

echo ""
echo "=== full suite (original timing) ==="
python runner.py 2>&1 | grep -E "TESTS=" | head -3

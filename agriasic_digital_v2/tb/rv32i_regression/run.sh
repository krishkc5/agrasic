#!/bin/bash
set -e
W="$HOME/agriasic_regression"
cd "$W"
source "$HOME/rv-venv/bin/activate"

# Point the testbench's helper import at our local copy instead of ../common
sed -i "s|p = Path.cwd() / '..' / 'common' / 'python'|p = Path(__file__).resolve().parent / 'common' / 'python'|" agriasic_tb.py

cat > runner.py <<'PYEOF'
import os, sys
from pathlib import Path
P = Path(__file__).resolve().parent
sys.path.append(str(P / 'common' / 'python'))
import cocotb_utils as cu
from cocotb.runner import get_runner

runr = get_runner(cu.SIM)
runr.build(
    verilog_sources=[P / "agriasic_rv32i_core.sv"],
    vhdl_sources=[],
    hdl_toplevel="Processor",
    includes=[P],
    build_dir="sim_build",
    build_args=cu.VERILATOR_FLAGS + ['-DDIVIDER_STAGES=8'],
)
runr.test(
    seed=12345,
    hdl_toplevel="Processor",
    test_module="agriasic_tb",
    testcase=os.environ.get("TESTS") or None,
)
PYEOF

python runner.py 2>&1 | tail -70

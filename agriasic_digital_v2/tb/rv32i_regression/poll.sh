#!/bin/bash
set -e
W="$HOME/agriasic_regression"; cd "$W"; source "$HOME/rv-venv/bin/activate"
cat > diag.py <<'PYEOF'
import cocotb
from cocotb.triggers import ClockCycles
from agriasic_tb import preTestSetup

@cocotb.test()
async def pollWMAddress(dut):
    await preTestSetup(dut, '''
        lw x1,0(x0)
        sb x1,0(x1)
        ''')
    idx = int(0x2083 / 4)
    for c in range(1, 15):
        await ClockCycles(dut.clk, 1)
        v = int(dut.memory.mem_array[idx].value)
        dut._log.info(f"POLL cycle {c}: mem[{idx}] = 0x{v:08x}")
PYEOF
cat > runner_diag.py <<'PYEOF'
import sys
from pathlib import Path
P = Path(__file__).resolve().parent
sys.path.append(str(P / 'common' / 'python'))
import cocotb_utils as cu
from cocotb.runner import get_runner
runr = get_runner(cu.SIM)
runr.build(verilog_sources=[P/"agriasic_rv32i_core.sv"], vhdl_sources=[], hdl_toplevel="Processor",
           includes=[P], build_dir="sim_build", build_args=cu.VERILATOR_FLAGS+['-DDIVIDER_STAGES=8'])
runr.test(seed=12345, hdl_toplevel="Processor", test_module="diag")
PYEOF
python runner_diag.py 2>&1 | grep -E "POLL|TESTS=" | head -20

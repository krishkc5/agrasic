"""Generic synthesis only: no foundry area, timing or power is claimed.

The two memories are explicit blackboxes so an unchosen memory implementation
cannot silently become tens of thousands of DFFs in the core count.
"""
from pathlib import Path
import subprocess
import shutil
import sys

BASE = Path(__file__).resolve().parents[1]
BUILD = BASE / "power/build/synthesis"
BUILD.mkdir(parents=True, exist_ok=True)
for sub in ("", "ctrl", "rv32i"):
    for path in (BASE / "rtl" / sub).glob("*.sv"):
        shutil.copy2(path, BUILD / path.name)
# Vendored Ibex keeps its subdirectory layout so rtl/ibex/ibex.f stays valid.
if (BUILD / "ibex").exists():
    shutil.rmtree(BUILD / "ibex")
shutil.copytree(BASE / "rtl/ibex", BUILD / "ibex")
if (BUILD / "riscv-dbg").exists():
    shutil.rmtree(BUILD / "riscv-dbg")
shutil.copytree(BASE / "rtl/riscv-dbg", BUILD / "riscv-dbg")
shutil.copy2(BASE / "fw/agriasic_fw.hex", BUILD / "agriasic_fw.hex")
ibex_files = ["ibex/" + line.strip()
              for line in (BASE / "rtl/ibex/ibex.f").read_text().splitlines() if line.strip()]
dbg_files = ["riscv-dbg/" + line.strip()
             for line in (BASE / "rtl/riscv-dbg/riscv_dbg.f").read_text().splitlines() if line.strip()]
sources = " ".join(dbg_files + ibex_files + [
    "agriasic_digital_rv32i_top.sv", "agriasic_rv32i_control_shell.sv",
    "agriasic_digital_top.sv", "rst_sync.sv", "measurement_fsm.sv",
    "excitation_ctrl.sv", "sar_controller.sv",
    "agriasic_imem.sv", "agriasic_dmem.sv", "agriasic_rv32i_mmio.sv", "agriasic_rv32i_bus.sv", "agriasic_spi_boot.sv", "agriasic_boot_rom.sv", "agriasic_spi_host.sv", "spi_slave.sv"])
# SYNTHESIS disables prim_assert. AGRIASIC_LATCH_REGFILE is intentionally NOT set:
# this run must match the simulated hierarchy (FF register file) so that
# analyze_activity.py can pair every netlist register bit with a VCD signal.
# The real ASIC synthesis should add -D AGRIASIC_LATCH_REGFILE.
# -nofsm: keep enum-typed state registers in their RTL (binary) encoding so
# every netlist register bit still corresponds to a VCD signal bit; the FSM
# pass would otherwise re-encode them one-hot (bus target selects, JTAG TAP).
script = f"""read_slang --threads 1 --allow-use-before-declare -D SYNTHESIS -I ibex/prim -I ibex/dv_utils -I riscv-dbg/common_cells/include --top agriasic_digital_rv32i_top --ignore-assertions --blackboxed-module agriasic_imem --blackboxed-module agriasic_dmem {sources}
hierarchy -check -top agriasic_digital_rv32i_top
proc
opt
write_json wordlevel.json
synth -top agriasic_digital_rv32i_top -noabc -nofsm
check
stat
write_json generic.json
"""
(BUILD / "synth.ys").write_text(script)
with (BASE / "power/results/synthesis.log").open("w") as log:
    subprocess.run([sys.executable, str(BASE / "power/yosys_entry.py"),
                    "-Q", "-T", "-s", "synth.ys"],
                   cwd=BUILD, stdout=log, stderr=subprocess.STDOUT, check=True)
print("Generic synthesis finished; see results/synthesis.log")

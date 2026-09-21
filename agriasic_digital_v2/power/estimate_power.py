"""Reproduce the explicitly assumed logic-power model and presentation plots."""
import csv
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
TOOLS = BASE.parents[1] / ".tools/power-python"
if TOOLS.is_dir():
    sys.path.insert(0, str(TOOLS))

def read_csv(name):
    return list(csv.DictReader((ROOT / "results" / name).open()))

def main():
    assumptions = json.loads((ROOT / "assumptions.json").read_text())
    structure = json.loads((ROOT / "results/structure.json").read_text())
    activity = [{k: int(v) for k, v in r.items()} for r in read_csv("activity.csv")]
    registers = read_csv("register_activity.csv")
    ff = structure["register_bits"]
    gates = structure["generic_combinational_primitives"]
    blocks = structure["register_bits_by_block"]
    sweep_cycles = sum(r["cycles"] for r in activity[:6])
    active_cycles = sum(activity[i]["cycles"] for i in [0, 2, 4])
    frozen_cycles = sweep_cycles - active_cycles
    V = assumptions["voltage_V"]
    f = assumptions["frequency_MHz"] * 1e6
    mode_cycles = {1: active_cycles, 2: frozen_cycles, 3: activity[6]["cycles"], 4: activity[7]["cycles"]}
    rises = {(int(r["epoch"]), r["block"]): int(r["rising_transitions"]) for r in registers}
    modes = {1: "firmware_enabled", 2: "measurement_frozen", 3: "after_ecall", 4: "start_low_reset"}
    results = []
    for scenario, params in assumptions["scenarios"].items():
        clock_per_bit_W = params["effective_clock_fF_per_register_bit"] * 1e-15 * V**2 * f
        # Uniform logic-cone allocation per retained FF bit is ONLY a sensitivity
        # proxy. It does not recover multiplier/divider internal glitch activity.
        energy_per_rise_J = gates / ff * params["logic_load_fF_per_primitive"] * 1e-15 * V**2 * params["data_activity_multiplier"]
        for mode, label in modes.items():
            clock_W = ff * clock_per_bit_W
            data_W = sum(rises.get((mode, block), 0) for block in blocks) / mode_cycles[mode] * f * energy_per_rise_J
            results.append({"scenario": scenario, "mode": label, "clock_mW": clock_W * 1e3,
                            "data_proxy_mW": data_W * 1e3, "logic_dynamic_mW": (clock_W + data_W) * 1e3})
        sweep_rises = sum(rises.get((mode, block), 0) for mode in [1, 2] for block in blocks)
        sweep_data_W = sweep_rises / sweep_cycles * f * energy_per_rise_J
        sweep_W = ff * clock_per_bit_W + sweep_data_W
        results.append({"scenario": scenario, "mode": "whole_sweep", "clock_mW": ff * clock_per_bit_W * 1e3,
                        "data_proxy_mW": sweep_data_W * 1e3, "logic_dynamic_mW": sweep_W * 1e3})
    with (ROOT / "results/power_estimates.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=list(results[0]))
        writer.writeheader()
        writer.writerows(results)
    lookup = {(r["scenario"], r["mode"]): r for r in results}
    ref = next(iter(json.loads((ROOT / "results/reference_dff_1v8.json").read_text()).values()))
    cp = ref["pin CLK"]
    # The library uses pF, ns and mW: power table entries represent pJ/event.
    energy_pJ = sum(float(p["rise_power pwr_tin_10"]["values"][1]) + float(p["fall_power pwr_tin_10"]["values"][1]) for p in cp["internal_power "]) / 2
    pin_fF = float(cp["capacitance"]) * 1000
    reference = {"clock_slew_ns": 0.1027, "clock_pin_capacitance_fF": pin_fF,
                 "internal_clock_energy_pJ_per_cycle": energy_pJ,
                 "equivalent_clock_capacitance_fF_before_tree": pin_fF + energy_pJ / 1.8**2 * 1000}
    simulation_log = (ROOT / "results/simulation.log").read_text()
    if "[TB] PASS -- all checks passed" not in simulation_log:
        raise ValueError("The source functional testbench did not pass")
    e2e_cycles = int(re.search(r"firmware halted after (\d+) cycles", simulation_log)[1])
    assert sum(blocks.values()) == ff == structure["vcd_matched_register_bits"]
    assert active_cycles + frozen_cycles == sweep_cycles
    summary = {"sweep_cycles_negedge_window": sweep_cycles, "existing_e2e_posedge_cycles": e2e_cycles,
               "active_cycles": active_cycles, "frozen_cycles": frozen_cycles,
               "frozen_percent": 100 * frozen_cycles / sweep_cycles,
               "sweep_time_ms_at_model_frequency": sweep_cycles / f * 1000,
               "sweep_samples": sum(r["adc_samples"] for r in activity[:6]),
               "imem_accesses_in_sweep": sum(r["imem_ce"] for r in activity[:6]),
               "dmem_accesses_in_sweep": sum(r["ram_ce"] for r in activity[:6]),
               "memory_capacity_bits": {"imem": 32768, "dmem": 16384},
               "reference_clock_example": reference,
               "sweep_results": {s: {**lookup[s, "whole_sweep"],
                                     "energy_uJ": lookup[s, "whole_sweep"]["logic_dynamic_mW"] * sweep_cycles / f * 1000}
                                 for s in assumptions["scenarios"]}}
    (ROOT / "results/summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    files = list((BASE / "rtl").rglob("*.sv")) + [BASE / "fw/agriasic_fw.hex", BASE / "tb/tb_agriasic_rv32i_e2e.sv"]
    manifest = {"git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=BASE, text=True).strip(),
                "files_sha256": {str(p.relative_to(BASE)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)},
                "synthesis_creator": json.loads((ROOT / "build/synthesis/generic.json").read_text())["creator"],
                "reference_sha256": hashlib.sha256((ROOT / "results/reference_dff_1v8.json").read_bytes()).hexdigest()}
    (ROOT / "results/provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    plot(assumptions, structure, summary, lookup)

def plot(assumptions, structure, summary, lookup):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11, "axes.spines.top": False,
                         "axes.spines.right": False, "pdf.fonttype": 42})
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5), gridspec_kw={"width_ratios": [1.05, 1.1]})
    fig.suptitle("AgriASIC digital power budget | 1.8 V", fontsize=19, fontweight="bold", x=.075, ha="left")
    ax = axes[0]
    groups = structure["register_bits_by_block"]
    names = ["CPU pipeline", "Register file", "Mul/div", "Measurement", "Shell / MMIO / bus", "Debug module", "Boot loader"]
    keys = ["core_pipeline", "core_register_file", "core_divider", "measurement_engine", "shell_mmio_reset", "debug_module", "boot_loader"]
    values = [groups[k] * 25e-15 * 1.8**2 * 160e6 * 1e3 for k in keys]
    ax.barh(names, values, color=["#235a80", "#347da5", "#56a0b6", "#ce8e3d", "#90a4ae", "#6c5b7b", "#8d6e63"])
    ax.invert_yaxis()
    for i, v in enumerate(values): ax.text(v+.2, i, f"{v:.2f}", va="center", fontsize=10)
    ax.set_xlim(0, max(values)*1.28)
    ax.set_xlabel("Clock-related dynamic power (mW)")
    ax.set_title("Central assumption at 160 MHz", loc="left", pad=16)
    ax.text(0, -.28, "2,800 synthesized register bits\n25 fF effective clock load per bit (assumed)", transform=ax.transAxes, fontsize=10, color="#555555")
    ax = axes[1]
    frequencies = np.linspace(10, 160, 151)
    low = lookup["low", "whole_sweep"]["logic_dynamic_mW"] * frequencies / 160
    central = lookup["central", "whole_sweep"]["logic_dynamic_mW"] * frequencies / 160
    high = lookup["high", "whole_sweep"]["logic_dynamic_mW"] * frequencies / 160
    ax.fill_between(frequencies, low, high, color="#c6dee8", label="Assumption range")
    ax.plot(frequencies, central, color="#235a80", linewidth=2.5, label="Central scenario")
    ax.set_xlim(0, 168)
    ax.set_ylim(0, high[-1]*1.12)
    ax.set_xlabel("Master clock (MHz)")
    ax.set_ylabel("Average logic dynamic power (mW)")
    ax.set_title("Same firmware sweep, scaled clock", loc="left", pad=16)
    ax.legend(loc="upper left", frameon=False, fontsize=10)
    ax.text(.97, .12, f"{central[-1]:.1f} mW central\n{low[-1]:.1f}–{high[-1]:.1f} mW range\nat 160 MHz", transform=ax.transAxes, ha="right", fontsize=11)
    fig.text(.075, .02, "RTL activity + generic synthesis + assumed capacitances. Excludes memory macros, leakage and pads.\n160 MHz is a target, not timing-verified. Range is a sensitivity study, not a confidence interval.", fontsize=9, color="#555555")
    fig.subplots_adjust(left=.14, right=.97, top=.80, bottom=.30, wspace=.60)
    for suffix in ["png", "pdf", "svg"]:
        fig.savefig(ROOT / f"results/power_summary.{suffix}", dpi=180, facecolor="white")
    plt.close(fig)

if __name__ == "__main__":
    main()

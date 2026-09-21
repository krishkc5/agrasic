"""Count surviving FF bits and their RTL VCD activity; this is NOT a power tool.

Match generic-synthesis register outputs to the original RTL net names. Count
each surviving physical-state bit once; discard constants and duplicate aliases.
Unpacked arrays flattened by slang are expanded back into the VCD element names.
"""
import csv
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOP = "agriasic_digital_rv32i_top"
PREFIX = "TOP.tb_agriasic_rv32i_e2e.dut."

def group(name):
    if ".multdiv_i." in name:
        return "core_divider"          # Ibex iterative mul/div (name kept for estimate_power.py)
    if ".register_file_i." in name:
        return "core_register_file"
    if ".u_core." in name:
        return "core_pipeline"
    if "u_measurement_top." in name:
        return "measurement_engine"
    if ".u_dm." in name or ".u_dtm." in name:
        return "debug_module"         # riscv-dbg dm_top + JTAG DTM (Phase 2)
    return "shell_mmio_reset"

def priority(name):
    storage = re.search(r"(?:_q|_state|_current|\.core_rst)$|(?:\.regs|_reg|\.div_pipe|rf_reg)\[", name)
    return (0 if storage else 1,
            -name.count("."), len(name))

def main():
    netlist = json.loads((ROOT / "build/synthesis/generic.json").read_text())["modules"][TOP]
    cells = netlist["cells"]
    qbits = {c["connections"]["Q"][0] for c in cells.values() if "DFF" in c["type"]}
    nets = netlist["netnames"]
    owners = {}
    for name in sorted((n for n in nets if not n.startswith("$")), key=priority):
        for bit in nets[name]["bits"]:
            if bit in qbits:
                owners.setdefault(bit, group(name))
    assert len(owners) == len(qbits), "Every surviving register bit needs a named owner"
    structure = {"register_bits": len(qbits), "register_bits_by_block": dict(Counter(owners.values())),
                 "generic_combinational_primitives": sum(c["type"].startswith("$_") and "DFF" not in c["type"] for c in cells.values()),
                 "cell_types": dict(Counter(c["type"] for c in cells.values())),
                 "memory_blackboxes": [c["type"] for c in cells.values() if not c["type"].startswith("$")]}
    vcd_names = {}
    scopes = []
    with (ROOT / "build/activity.vcd").open() as stream:
        for line in stream:
            fields = line.split()
            if not fields: continue
            if fields[0] == "$scope": scopes.append(fields[2])
            elif fields[0] == "$upscope": scopes.pop()
            elif fields[0] == "$var":
                full = ".".join(scopes + [fields[4]])
                if full.startswith(PREFIX):
                    vcd_names[full[len(PREFIX):]] = (fields[3], int(fields[2]))
            elif fields[0] == "$enddefinitions": break
        masks = defaultdict(lambda: defaultdict(int))
        covered = set()
        for name in sorted((n for n in nets if not n.startswith("$")), key=priority):
            # Unpacked arrays: the VCD always has per-element vars name[i]. The
            # netlist either keeps name[0] (Penn core style) or flattens the
            # whole array under the bare name (Ibex's imd_val_q[2]).
            if name in vcd_names:
                code, width = vcd_names[name]
                array_match = re.match(r"(.*)\[0\]$", name)
                base = array_match[1] if array_match else None
            elif f"{name}[0]" in vcd_names:
                code, width = vcd_names[f"{name}[0]"]
                base = name
            else:
                continue
            bits = nets[name]["bits"]
            offset = nets[name].get("offset", 0)
            # A vector declared with a non-zero LSB (e.g. Ibex's logic [31:8]
            # rdata_q) carries its offset in the netlist, but the VCD var is
            # just len(bits) wide starting at 0.
            if offset and len(bits) == width:
                offset = 0
            for index, bit in enumerate(bits):
                if bit not in qbits or bit in covered: continue
                pos = index + offset
                target = code
                if pos >= width:
                    if base is None: continue
                    element = f"{base}[{pos // width}]"
                    if element not in vcd_names: continue
                    target = vcd_names[element][0]
                    pos %= width
                masks[target][owners[bit]] |= 1 << pos
                covered.add(bit)
        structure["vcd_matched_register_bits"] = len(covered)
        structure["unmatched_register_bits"] = len(qbits - covered)
        # Cycle windows use sampled epochs; times in the VCD are picoseconds.
        ep = list(csv.DictReader((ROOT / "results/epochs.csv").open()))
        times = [int(e.get("time_ps", e.get("time_ns"))) for e in ep]
        epochs = [int(e["epoch"]) for e in ep]
        boundary = 0
        now = 0
        mode = 0
        last = {}
        toggles = defaultdict(Counter)
        rises = defaultdict(Counter)
        # Count all edges of only the synthesized register outputs, not clocks,
        # testbench counters, duplicate ports, or pruned simulation-only state.
        for line in stream:
            c = line[0]
            if c == "#":
                now = int(line[1:])
                while boundary < len(times) and now >= times[boundary]:
                    mode = epochs[boundary]
                    boundary += 1
                continue
            if c in "01": code, value = line[1:].strip(), int(c)
            elif c == "b":
                value_str, code = line[1:].split()
                if code not in masks: continue
                if "x" in value_str or "z" in value_str:
                    raise ValueError("Unknown on a monitored state bit")
                value = int(value_str, 2)
            else: continue
            if code not in masks: continue
            previous = last.get(code)
            last[code] = value
            if previous is None or mode == 0: continue
            changed = previous ^ value
            up = changed & value
            for block, mask in masks[code].items():
                toggles[mode][block] += (changed & mask).bit_count()
                rises[mode][block] += (up & mask).bit_count()
    (ROOT / "results/structure.json").write_text(json.dumps(structure, indent=2) + "\n")
    with (ROOT / "results/register_activity.csv").open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["epoch", "block", "register_bits", "bit_toggles", "rising_transitions"])
        for mode in sorted(toggles):
            for block, bits in sorted(structure["register_bits_by_block"].items()):
                writer.writerow([mode, block, bits, toggles[mode][block], rises[mode][block]])
    print(json.dumps(structure, indent=2))

if __name__ == "__main__":
    main()

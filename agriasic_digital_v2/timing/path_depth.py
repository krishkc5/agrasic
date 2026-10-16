#!/usr/bin/env python3
"""Structural critical-path analysis: longest combinational depth between flops.

Signoff STA needs a Liberty library we do not have. What we CAN measure without
one is the *structure* of the timing problem: how many levels of logic sit
between one flop and the next, and where the deepest ones are. Gate delays vary
a few-fold between cells; logic depth varies by an order of magnitude between
paths, so depth is what identifies the critical path. The library then tells you
whether it closes.

This exists specifically to answer one question: with no SRAM compiler, IMEM and
DMEM are standard-cell flop arrays, which puts an N:1 read mux in the
instruction fetch path. Is that actually the worst path in the design?

    python timing/path_depth.py            # reuse an existing netlist
    python timing/path_depth.py --build    # re-synthesise first (minutes)

Run under Windows Python: the vendored wasmtime in .tools/power-python ships
only the win32 native library, so WSL python3 cannot load YoWASP yosys.
"""
import argparse
import json
import pathlib
import subprocess
import sys
from collections import defaultdict, deque

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent
SYNTH_DIR = BASE / "power/build/synthesis"
NETLIST = HERE / "build/netlist_timing.json"

SEQ_PREFIXES = ("$_DFF", "$_SDFF", "$_ADFF", "$_DLATCH", "$_SR_")


def build_netlist():
    """Re-synthesise with the memories INCLUDED -- the whole point is the mux."""
    NETLIST.parent.mkdir(parents=True, exist_ok=True)
    print("re-running synthesis to refresh the build directory ...")
    subprocess.run([sys.executable, str(BASE / "power/run_synthesis.py")],
                   check=True, cwd=str(BASE))
    ys = (SYNTH_DIR / "synth.ys").read_text(encoding="utf-8")
    # Memories must NOT be blackboxed here, and we need a JSON netlist out.
    ys = ys.replace("--blackboxed-module agriasic_imem --blackboxed-module agriasic_dmem ", "")
    # The power flow runs `synth -noabc` so every netlist register still pairs
    # with a VCD signal. That is the wrong setting for TIMING: unoptimised
    # generic logic reports depths a real flow would restructure away. Let abc
    # balance it, so the ranking reflects something a backend tool would see.
    ys = ys.replace(" -noabc", "")
    ys = ys.replace("write_json wordlevel.json\n", "")
    ys = ys.replace("write_json generic.json\n", "write_json netlist_timing.json\n")
    (SYNTH_DIR / "synth_timing.ys").write_text(ys, encoding="utf-8")
    print("synthesising with memories included (this is the slow one) ...")
    subprocess.run([sys.executable, str(BASE / "power/yosys_entry.py"),
                    "-Q", "-T", "-s", "synth_timing.ys"],
                   check=True, cwd=str(SYNTH_DIR))
    (SYNTH_DIR / "netlist_timing.json").replace(NETLIST)
    print("wrote", NETLIST.relative_to(BASE))


def load_top(path):
    design = json.loads(path.read_text(encoding="utf-8"))
    mods = design["modules"]
    # The flattened top is the one with by far the most cells.
    name = max(mods, key=lambda m: len(mods[m].get("cells", {})))
    return name, mods[name]


def bit_names(mod):
    """net bit -> readable RTL name, preferring real names over yosys temporaries."""
    names = {}
    for nname, n in mod.get("netnames", {}).items():
        synthetic = nname.startswith("$")
        for i, b in enumerate(n["bits"]):
            if not isinstance(b, int):
                continue
            label = "%s[%d]" % (nname, i) if len(n["bits"]) > 1 else nname
            if b not in names or (synthetic is False and names[b][0] is True):
                names[b] = (synthetic, label)
    return {b: lbl for b, (syn, lbl) in names.items()}


def analyse(top_name, mod):
    cells = mod.get("cells", {})
    ports = mod.get("ports", {})

    driver = {}                      # net bit -> cell name (combinational only)
    cell_in = defaultdict(list)      # cell -> input net bits
    cell_out = defaultdict(list)     # cell -> output net bits
    seq_cells, comb_cells = set(), set()
    start_bits = set()               # flop Q and primary inputs

    for cname, c in cells.items():
        ctype = c["type"]
        dirs = c.get("port_directions", {})
        is_seq = ctype.startswith(SEQ_PREFIXES)
        (seq_cells if is_seq else comb_cells).add(cname)
        for port, bits in c["connections"].items():
            d = dirs.get(port, "input")
            bits = [b for b in bits if isinstance(b, int)]   # drop 0/1/x consts
            if d == "output":
                cell_out[cname].extend(bits)
                if is_seq:
                    start_bits.update(bits)       # a flop output starts a path
                else:
                    for b in bits:
                        driver[b] = cname
            else:
                # A clock pin is not a data path; ignore it for depth.
                if is_seq and port in ("C", "CLK"):
                    continue
                cell_in[cname].extend(bits)

    for pname, p in ports.items():
        if p["direction"] in ("input", "inout"):
            start_bits.update(b for b in p["bits"] if isinstance(b, int))

    # Longest-path over the combinational DAG, in levels of logic.
    depth = defaultdict(int)
    for b in start_bits:
        depth[b] = 0

    indeg = {}
    consumers = defaultdict(list)
    for cname in comb_cells:
        src = [b for b in cell_in[cname] if b in driver]
        indeg[cname] = len(src)
        for b in src:
            consumers[driver[b]].append(cname)

    q = deque(c for c in comb_cells if indeg[c] == 0)
    order = []
    while q:
        c = q.popleft()
        order.append(c)
        for nxt in consumers[c]:
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                q.append(nxt)

    if len(order) != len(comb_cells):
        print("  WARNING: %d combinational cells are in a loop and were skipped"
              % (len(comb_cells) - len(order)))

    came_from = {}
    for cname in order:
        best, best_src = 0, None
        for b in cell_in[cname]:
            if depth[b] + 1 > best:
                best, best_src = depth[b] + 1, b
        for b in cell_out[cname]:
            if best > depth[b]:
                depth[b] = best
                came_from[b] = (cname, best_src)

    # Endpoints: flop data inputs and primary outputs.
    endpoints = []
    for cname in seq_cells:
        for b in cell_in[cname]:
            endpoints.append((depth[b], b, cname, cells[cname]["type"]))
    for pname, p in ports.items():
        if p["direction"] in ("output", "inout"):
            for b in p["bits"]:
                if isinstance(b, int):
                    endpoints.append((depth[b], b, "PORT:" + pname, "port"))
    endpoints.sort(key=lambda t: -t[0])
    return endpoints, came_from, cells, depth, bit_names(mod)


def trace(bit, came_from, cells, limit=14):
    out = []
    while bit in came_from and len(out) < limit:
        cname, src = came_from[bit]
        out.append(cells[cname]["type"])
        if src is None:
            break
        bit = src
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true", help="re-synthesise first")
    ap.add_argument("--top", type=int, default=12, help="endpoints to list")
    args = ap.parse_args()

    if args.build or not NETLIST.exists():
        build_netlist()

    top_name, mod = load_top(NETLIST)
    print("\ntop module : %s" % top_name)
    print("cells      : %d" % len(mod.get("cells", {})))

    endpoints, came_from, cells, depth, names = analyse(top_name, mod)
    if not endpoints:
        print("no endpoints found"); return

    print("\nDeepest combinational paths (levels of logic between registers):\n")
    print("  %-6s  %-22s  %s" % ("depth", "endpoint cell type", "endpoint"))
    print("  " + "-" * 74)
    seen = set()
    shown = 0
    for d, bit, cname, ctype in endpoints:
        label = names.get(bit, cname)
        # Group by the signal, not the individual bit, so one wide register does
        # not fill the whole table.
        key = label.split("[")[0]
        if key in seen:
            continue
        seen.add(key)
        print("  %-6d  %-22s  %s" % (d, ctype, key[:56]))
        shown += 1
        if shown >= args.top:
            break

    worst_d, worst_bit = endpoints[0][0], endpoints[0][1]
    print("\nWorst path: %d levels of logic." % worst_d)
    print("Cell chain from the endpoint backwards (deepest first):")
    print("  endpoint signal: %s" % names.get(worst_bit, "(unnamed)"))
    chain = trace(worst_bit, came_from, cells)
    print("  " + " <- ".join(c.replace("$_", "").replace("_", "") for c in chain))

    muxes = sum(1 for c in chain if "MUX" in c)
    print("\n  of the %d levels shown, %d are muxes" % (len(chain), muxes))
    print("\nNote: depth is a proxy, not a delay. A library is still needed to say")
    print("whether this closes at 160 MHz (6.25 ns). Use it to find the path, not")
    print("to sign it off.")


if __name__ == "__main__":
    main()

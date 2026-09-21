"""Summarize actual sampled addresses; never substitute payload sums for extent."""
import csv
import hashlib
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
DMEM_BASE  = 0x00010000   # agriasic_rv32i_bus.sv / control shell (Phase 2 flat map)
DMEM_BYTES = 0x800

def bounds(values):
    values = set(values)
    return {"lowest_byte": f"0x{min(values):08X}", "highest_byte": f"0x{max(values):08X}",
            "distinct_bytes": len(values), "span_bytes": max(values) - min(values) + 1}

def main():
    events = list(csv.DictReader((ROOT / "results/accesses.csv").open()))
    initialized = set()
    ram_bytes, result_bytes, stack_bytes, fetch_bytes = set(), set(), set(), set()
    invalid, uninitialized_reads = [], []
    mmio = Counter()
    sp = []
    retire = []
    image = json.loads((BASE / "fw/agriasic_fw.memory.json").read_text())
    fetch_beyond_image = set()
    for event in events:
        addr, mask = int(event["address"], 16), int(event["byte_mask"], 16)
        kind = event["kind"]
        if kind == "sp":
            sp.append(event["address"])
            continue
        if kind == "retire":
            retire.append(addr)
            continue
        accessed = {addr + lane for lane in range(4) if mask & (1 << lane)}
        if kind == "fetch":
            fetch_bytes |= accessed
            if max(accessed) >= 4096 or addr % 4: invalid.append(event)
            if max(accessed) >= image["vma_end_exclusive"]: fetch_beyond_image.add(addr)
        elif addr & 0x80000000:
            mmio[kind, addr] += 1
            if max(accessed) >= 0x80000020 or addr % 4: invalid.append(event)
        else:
            # Phase 2 flat map: DMEM is at DMEM_BASE; report RAM bytes as offsets
            # within the RAM so the extent-from-origin numbers stay comparable.
            if addr < DMEM_BASE or max(accessed) >= DMEM_BASE + DMEM_BYTES or addr % 4: invalid.append(event)
            accessed = {a - DMEM_BASE for a in accessed}
            ram_bytes |= accessed
            if (addr - DMEM_BASE) >= 0x7e0: stack_bytes |= accessed
            else: result_bytes |= accessed
            if kind == "store": initialized |= accessed
            elif not accessed <= initialized: uninitialized_reads.append(event)
    summary = {"instruction_image": image,
               "instruction_fetch": bounds(fetch_bytes), "highest_fetch_word_address": f"0x{max(fetch_bytes) - 3:08X}",
               "highest_retired_instruction_address": f"0x{max(retire):08X}",
               "fetch_word_addresses_beyond_linked_image": [f"0x{a:08X}" for a in sorted(fetch_beyond_image)],
               "retired_addresses_beyond_linked_image": [f"0x{a:08X}" for a in sorted(set(retire)) if a >= image["vma_end_exclusive"]],
               "data_memory": bounds(ram_bytes), "result_buffers": bounds(result_bytes), "stack_accesses": bounds(stack_bytes),
               "stack_pointer_values_in_order": ["0x" + s.upper() for s in sp],
               "stack_frame_bytes_static": 32, "dmem_base": f"0x{DMEM_BASE:08X}", "data_memory_address_span_from_dmem_base_bytes": max(ram_bytes) + 1,
               "mmio_accesses": [{"kind": kind, "word_address": f"0x{addr:08X}", "count": n} for (kind, addr), n in sorted(mmio.items(), key=lambda p: (p[0][1], p[0][0]))],
               "invalid_accesses": invalid, "data_loads_before_observed_store": uninitialized_reads,
               "event_counts": dict(Counter(e["kind"] for e in events)),
               "hex_sha256": hashlib.sha256((BASE / "fw/agriasic_fw.hex").read_bytes()).hexdigest()}
    assert not invalid, invalid
    assert not uninitialized_reads, uninitialized_reads
    assert not summary["retired_addresses_beyond_linked_image"]
    assert "[TB] PASS -- all checks passed" in (ROOT / "results/simulation.log").read_text()
    (ROOT / "results/address_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))

if __name__ == "__main__": main()

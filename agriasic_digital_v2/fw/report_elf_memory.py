#!/usr/bin/env python3
"""Report occupied addresses from an ELF32 little-endian image, including gaps.

Only allocated sections contribute; symbol/string/debug tables do not.
Run beside the linker map: this supplements the map, not just `size` totals.
Absolute-address C accesses and the runtime stack are intentionally not inferred
from the ELF; they require source inspection or the memory simulation audit.
"""
import argparse
import json
from pathlib import Path
import struct

def inspect_elf(path, origin=0):
    data = path.read_bytes()
    if data[:6] != b"\x7fELF\x01\x01":
        raise ValueError("Expected ELF32 little-endian firmware")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    phoff, shoff = header[5:7]
    phsize, phnum, shsize, shnum, shstrings = header[9:14]
    sections = [struct.unpack_from("<IIIIIIIIII", data, shoff + n * shsize) for n in range(shnum)]
    loads = [struct.unpack_from("<IIIIIIII", data, phoff + n * phsize) for n in range(phnum)]
    strings = sections[shstrings]
    names = data[strings[4]:strings[4] + strings[5]]
    allocated = []
    for sec in sections:
        name_off, sec_type, flags, addr, file_off, size, _, _, alignment, _ = sec
        if not (flags & 2) or not size:
            continue
        name = names[name_off:].split(b"\0", 1)[0].decode()
        load_addr = None
        if sec_type != 8:  # SHT_NOBITS reserves memory but has no stored bytes
            for ptype, poff, _vaddr, paddr, filesz, _memsz, _flags, _align in loads:
                if ptype == 1 and poff <= file_off and file_off + size <= poff + filesz:
                    load_addr = paddr + file_off - poff
                    break
            if load_addr is None:
                raise ValueError(f"Allocated initialized section {name} has no PT_LOAD segment")
        allocated.append({"name": name, "size_bytes": size, "vma_start": addr,
                          "vma_highest_byte": addr + size - 1, "vma_end_exclusive": addr + size,
                          "lma_start": load_addr,
                          "lma_highest_byte": None if load_addr is None else load_addr + size - 1,
                          "alignment_bytes": alignment, "nobits": sec_type == 8})
    highest = max(s["vma_highest_byte"] for s in allocated)
    if min(s["vma_start"] for s in allocated) < origin:
        raise ValueError("Section begins below the supplied memory origin")
    initialized = [s for s in allocated if s["lma_start"] is not None]
    return {"elf": path.name, "entry_address": header[4], "memory_origin": origin,
            "sections": allocated, "allocated_section_bytes_sum": sum(s["size_bytes"] for s in allocated),
            "highest_occupied_vma_byte": highest, "vma_end_exclusive": highest + 1,
            "address_span_from_origin_bytes": highest + 1 - origin,
            "highest_initialized_lma_byte": max(s["lma_highest_byte"] for s in initialized),
            "note": "This linker describes IMEM only. Absolute result buffers, stack and heap are not allocated sections."}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("elf", type=Path)
    parser.add_argument("--origin", type=lambda x: int(x, 0), default=0)
    args = parser.parse_args()
    result = inspect_elf(args.elf, args.origin)
    lines = [f"ELF allocated-memory report: {args.elf.name}"]
    for sec in result["sections"]:
        lines.append(f"{sec['name']}: {sec['size_bytes']} bytes, VMA 0x{sec['vma_start']:08X}..0x{sec['vma_highest_byte']:08X}, alignment {sec['alignment_bytes']}")
    lines += [f"Allocated section sum: {result['allocated_section_bytes_sum']} bytes",
              f"Highest occupied byte: 0x{result['highest_occupied_vma_byte']:08X}",
              f"Next address (exclusive end): 0x{result['vma_end_exclusive']:08X}",
              f"Required address span from origin 0x{args.origin:08X}: {result['address_span_from_origin_bytes']} bytes (includes gaps)",
              result["note"]]
    args.elf.with_suffix(".memory.json").write_text(json.dumps(result, indent=2) + "\n")
    args.elf.with_suffix(".memory.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    main()

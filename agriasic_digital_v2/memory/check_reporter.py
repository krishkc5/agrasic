"""Regression for the specific failure mode: section sum misses address gaps."""
from pathlib import Path
import struct
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fw"))
from report_elf_memory import inspect_elf

def main():
    # Two 4-byte sections at 0 and 0x1000. File offsets deliberately differ
    # from memory addresses, and the non-allocated string table is excluded.
    buf = bytearray(0x300 + 5 * 40)
    ident = b"\x7fELF\x01\x01\x01" + bytes(9)
    struct.pack_into("<16sHHIIIIIHHHHHH", buf, 0, ident, 2, 243, 1,
                     0, 52, 0x300, 0, 52, 32, 2, 40, 5, 3)
    struct.pack_into("<IIIIIIII", buf, 52, 1, 0x100, 0, 0, 4, 4, 5, 4)
    struct.pack_into("<IIIIIIII", buf, 84, 1, 0x110, 0x1000, 0x1000, 4, 4, 4, 4)
    names = b"\0.text\0.data\0.shstrtab\0.empty\0"
    buf[0x200:0x200 + len(names)] = names
    sections = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (1, 1, 6, 0, 0x100, 4, 0, 0, 4, 0),
        (7, 1, 2, 0x1000, 0x110, 4, 0, 0, 4, 0),
        (13, 3, 0, 0, 0x200, len(names), 0, 0, 1, 0),
        (23, 8, 2, 0x8000, 0, 0, 0, 0, 4, 0),
    ]
    for index, section in enumerate(sections):
        struct.pack_into("<IIIIIIIIII", buf, 0x300 + 40 * index, *section)
    with tempfile.TemporaryDirectory(prefix="agriasic-elf-report-") as folder:
        path = Path(folder) / "gaps.elf"
        path.write_bytes(buf)
        report = inspect_elf(path)
    assert report["allocated_section_bytes_sum"] == 8
    assert report["address_span_from_origin_bytes"] == 4100
    assert report["highest_occupied_vma_byte"] == 0x1003
    assert report["highest_initialized_lma_byte"] == 0x1003
    print("PASS: 8 section bytes require a 4,100-byte address span; metadata and zero-sized sections excluded.")

if __name__ == "__main__": main()

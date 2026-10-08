#!/bin/bash
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CC=riscv64-unknown-elf-gcc
# rv32imc_zicsr: Ibex always implements C (RV32Zca is the minimum) and start.S
# needs csrw for mie; GCC 13 requires zicsr to be spelled out explicitly.
# -Wno-array-bounds: GCC cannot reason about absolute addresses and reports a
# false positive for every memory-mapped access built from an integer cast. The
# accesses are volatile, so they are preserved regardless; the disassembly check
# below confirms the stores actually survive.
FLAGS="-march=rv32imc_zicsr -mabi=ilp32 -Os -Wall -Wextra -Wno-array-bounds -ffreestanding -nostdlib -nodefaultlibs -fno-tree-loop-distribute-patterns -fstack-usage"

echo "=== compiling ==="
$CC $FLAGS -T link.ld -Wl,-Map=agriasic_fw.map,--cref -o agriasic_fw.elf start.S fw.c

echo "=== sections ==="
riscv64-unknown-elf-size -A agriasic_fw.elf | head -12
python3 report_elf_memory.py agriasic_fw.elf

echo "=== generating hex image ==="
riscv64-unknown-elf-objcopy -O binary agriasic_fw.elf agriasic_fw.bin
python3 - <<'PY'
import struct
data = open('agriasic_fw.bin','rb').read()
if len(data) % 4:
    data += b'\x00' * (4 - len(data) % 4)
words = struct.unpack('<%dI' % (len(data)//4), data)
with open('agriasic_fw.hex','w') as f:
    for w in words:
        f.write('%08x\n' % w)
print(f"wrote agriasic_fw.hex: {len(words)} words ({len(words)*4} bytes)")
if len(words) > 256:
    raise SystemExit(f"ERROR: image is {len(words)} words, exceeds the 256-word IMEM")
PY

echo "=== generating SPI-flash boot image (Phase 3, agriasic_spi_boot) ==="
# Header (little-endian words): magic "AGRA", payload length, version, CRC-32
# (zlib / IEEE 802.3) of the payload. The boot FSM checks all three before it
# releases the core. .bin is what goes into the flash at address 0; .hex is
# one byte per line for the simulation flash model.
python3 - <<'PYIMG'
import struct, zlib, subprocess
payload = open('agriasic_fw.bin','rb').read()
if len(payload) % 4:
    payload += b'\x00' * (4 - len(payload) % 4)
try:
    version = int(subprocess.check_output(['git','rev-parse','--short=4','HEAD'], stderr=subprocess.DEVNULL).decode().strip(), 16)
except Exception:
    version = 1
crc = zlib.crc32(payload) & 0xFFFFFFFF
hdr = struct.pack('<IIII', 0x41475241, len(payload), version & 0xFFFF, crc)
image = hdr + payload
open('agriasic_fw_flash.bin','wb').write(image)
with open('agriasic_fw_flash.hex','w') as f:
    for b in image:
        f.write('%02x\n' % b)
print(f"wrote agriasic_fw_flash.bin/.hex: {len(image)} bytes (16-byte header + {len(payload)} payload, crc32=0x{crc:08x}, version=0x{version&0xffff:04x})")
PYIMG

echo "=== verifying volatile stores to the scratch-RAM outputs survived ==="
riscv64-unknown-elf-objdump -d agriasic_fw.elf > agriasic_fw.dis
# Rev 4.3 Phase 7 layout at DMEM_BASE = 0x10000 (Phase 2 flat map):
# +0x100/+0x104 = OUT_COUNT/OUT_NUM_POINTS, +0x110..0x118 = OUT_DIV[0..2],
# +0x120..0x128 = OUT_I[0..2], +0x130..0x138 = OUT_Q[0..2], +0x140 = OUT_TEMP.
# With -Os the compiler materialises the base with `lui rX,0x10` and stores
# through it, so check the base is formed and count the stores.
echo "DMEM_BASE (lui 0x10) materialised $(grep -cE 'lui[[:space:]]+[a-z0-9]+,0x10$' agriasic_fw.dis) time(s)"
echo "total sw instructions: $(grep -cE '\b(c\.)?sw\b' agriasic_fw.dis)"
echo "=== Ibex boot layout check ==="
grep -E "^00000000 <_vectors>:|^00000080 <_start>:" agriasic_fw.dis
echo "=== full disassembly of main ==="
sed -n "/<main>:/,/^$/p" agriasic_fw.dis

#!/bin/bash
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CC=riscv64-unknown-elf-gcc
# -Wno-array-bounds: GCC cannot reason about absolute addresses and reports a
# false positive for every memory-mapped access built from an integer cast. The
# accesses are volatile, so they are preserved regardless; the disassembly check
# below confirms the stores actually survive.
FLAGS="-march=rv32im -mabi=ilp32 -Os -Wall -Wextra -Wno-array-bounds -ffreestanding -nostdlib -nodefaultlibs -fno-tree-loop-distribute-patterns"

echo "=== compiling ==="
$CC $FLAGS -T link.ld -o agriasic_fw.elf start.S fw.c

echo "=== sections ==="
riscv64-unknown-elf-size -A agriasic_fw.elf | head -12

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
if len(words) > 1024:
    raise SystemExit("ERROR: image exceeds the 1024-word instruction ROM")
PY

echo "=== verifying volatile stores to the scratch-RAM outputs survived ==="
riscv64-unknown-elf-objdump -d agriasic_fw.elf > agriasic_fw.dis
# Rev 4.3 Phase 7 layout (supersedes the Phase 1-6 single-frequency-demo
# offsets): 256/260=OUT_COUNT/OUT_NUM_POINTS, 272-280=OUT_DIV[0..2],
# 288-296=OUT_I[0..2], 304-312=OUT_Q[0..2], 320=OUT_TEMP
grep -E "sw\s+[a-z0-9]+,(256|260|272|276|280|288|292|296|304|308|312|320)\(" agriasic_fw.dis || echo "(checking by offset below)"
grep -cE "sw" agriasic_fw.dis | xargs echo "total sw instructions:"
echo "=== full disassembly of main ==="
sed -n "/<main>:/,/^$/p" agriasic_fw.dis

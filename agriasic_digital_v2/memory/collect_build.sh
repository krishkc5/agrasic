#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$BASE/memory/results"
bash "$BASE/fw/build.sh" > "$BASE/memory/results/firmware_build.log" 2>&1
cd "$BASE/fw"
riscv64-unknown-elf-readelf -W -S -l agriasic_fw.elf > "$BASE/memory/results/readelf.txt"
riscv64-unknown-elf-objdump -h agriasic_fw.elf > "$BASE/memory/results/section_headers.txt"
riscv64-unknown-elf-gcc --version > "$BASE/memory/results/compiler_version.txt"
riscv64-unknown-elf-ld --version > "$BASE/memory/results/linker_version.txt"
cat agriasic_fw.memory.txt

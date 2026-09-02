#!/bin/bash
set -e
SRC="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/cis5710-tjammula/riscv-tests"
DST="$HOME/riscv-tests"

# Build in WSL's native fs: /mnt/c is slow, and the Windows checkout has CRLF
# line endings that break script shebangs. Also leaves the class repo untouched.
# cocotb_utils resolves RISCV_TESTS_PATH as ../../riscv-tests/isa from
# sim_build, which lands exactly here.
if [ ! -d "$DST" ]; then
  echo "=== copying riscv-tests to WSL fs ==="
  cp -r "$SRC" "$DST"
fi
cd "$DST"

echo "=== stripping CRLF from build scripts ==="
for f in configure config.sub config.guess install-sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" && chmod +x "$f"
done
find . -name "Makefile*" -o -name "*.sh" | while read -r f; do sed -i 's/\r$//' "$f"; done

echo "=== configuring ==="
if ! ./configure --with-xlen=32 >/tmp/rvt_conf.log 2>&1; then
  echo "(--with-xlen=32 rejected, retrying bare)"
  ./configure >/tmp/rvt_conf.log 2>&1 || { tail -25 /tmp/rvt_conf.log; exit 1; }
fi

echo "=== building isa tests ==="
make -j4 isa >/tmp/rvt_make.log 2>&1 || { tail -40 /tmp/rvt_make.log; exit 1; }

echo "=== built, sample binaries: ==="
ls isa/ | grep -E "^rv32ui-p-(simple|lw|add|sb|sh|sw)$" | head
echo "total rv32ui-p binaries: $(ls isa/ | grep -c '^rv32ui-p-[a-z]*$')"

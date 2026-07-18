#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# sckoc regression suite. Run from anywhere: bash tests/run.sh
# Needs root (or sudo in CI) only for the /dev/cpu/0/msr gate fixture;
# everything else runs against synthetic sysfs trees and file-backed
# readoc fixtures (READOC_DEV).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  - $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL- $1"; }
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== t1 shell syntax =="
for f in sckoc install.sh uninstall.sh setup.sh packaging/*.sh tests/run.sh; do
  chk "bash -n $f" "bash -n '$f'"
done

echo "== t2 install.sh embeds match sources =="
for P in "MSR_SH:sckoc" "TPMI_C:tpmi-uncore.c" "COMP_SH:packaging/sckoc.completion" "READOC_C:readoc.c" "HSMP_C:hsmp-msg.c"; do
  M=${P%%:*}; S=${P##*:}
  chk "$M == $S" "diff -q <(sed -n \"/<<'$M'/,/^$M\$/p\" install.sh | sed '1d;\$d') '$S'"
done
chk "VER_H version matches version.h" \
  "[ \"\$(grep -o 'VERSION_STRING \"[0-9.]*\"' <(sed -n \"/<<'VER_H'/,/^VER_H\$/p\" install.sh))\" = \"\$(grep -o 'VERSION_STRING \"[0-9.]*\"' version.h)\" ]"

echo "== t3 version consistency =="
V=$(grep -m1 '^MSRVER=' sckoc | cut -d= -f2)
chk "version.h == $V"        "grep -q '\"$V\"' version.h"
chk "fedora spec == $V"      "grep -q '^Version:.*$V' fedora/sckoc.spec"
chk "packaging spec == $V"   "grep -q '^Version:.*$V' packaging/sckoc.spec"
chk "build-deb == $V"        "grep -q 'V=$V' packaging/build-deb.sh"
chk "man .TH == $V"          "grep -q '\"sckoc $V\"' packaging/sckoc.1"

echo "== t4 readoc unit (single + batch) =="
gcc -Wall -O2 -I. -o "$T/readoc" readoc.c || bad "readoc compiles"
python3 - "$T" <<'PY'
import struct, sys
d = sys.argv[1]
b = bytearray(8192)
def put(reg, val): b[reg:reg+8] = struct.pack('<Q', val)
put(0x100, 1000); put(0x200, 2000); put(0x400, (5 << 32) | 7)
open(d + '/cpu0.msr', 'wb').write(bytes(b))
put(0x100, 1111)
open(d + '/cpu1.msr', 'wb').write(bytes(b))
PY
export READOC_DEV="$T/cpu%d.msr"
R="$T/readoc"
chk "single decimal"      "[ \"\$($R -p 0 -u 0x100)\" = 1000 ]"
chk "single hex"          "[ \"\$($R -p 0 -x 0x100)\" = 3e8 ]"
chk "bitfield 47:32"      "[ \"\$($R -p 0 -f 47:32 0x400)\" = 5 ]"
chk "bitfield 2:0"        "[ \"\$($R -p 0 -f 2:0 0x400)\" = 7 ]"
chk "batch 2cpu x 2reg = 4 lines" "[ \"\$($R -p 0-1 0x100,0x200 | wc -l)\" = 4 ]"
chk "batch cpu1 value"    "$R -p 0-1 0x100 | grep -qx '1 0x100 1111'"
chk "batch skips missing cpu (rc 0)" "$R -p 0,9 0x100 | grep -qx '0 0x100 1000'"
chk "batch all-missing rc 4" "$R -p 8,9 0x100 >/dev/null; [ \$? = 4 ]"
unset READOC_DEV

echo "== t5 uncore paths =="
mkuc(){ mkdir -p "$1"; for f in current min max initial_min initial_max; do echo "$3" > "$1/${f}_freq_khz"; done; echo "$2" > "$1/package_id"; }
U="$T/unc"; mkuc "$U/uncore00" 0 2700000
mkuc "$U/uncore01" 0 2000000; echo 800000 > "$U/uncore01/min_freq_khz"; echo 800000 > "$U/uncore01/initial_min_freq_khz"; echo 2500000 > "$U/uncore01/initial_max_freq_khz"
chk "sysfs table + star"  "MSRVEN=GenuineIntel UNCSYS=$U bash sckoc uncore | grep -q 'uncore01.*\*'"
chk "star legend"         "MSRVEN=GenuineIntel UNCSYS=$U bash sckoc uncore | grep -q 'differ from the BIOS'"
U2="$T/unc2"; mkdir -p "$U2/package_00_die_00"; for f in current min max initial_min initial_max; do echo 2400000 > "$U2/package_00_die_00/${f}_freq_khz"; done
chk "legacy dir, pkg from name" "MSRVEN=GenuineIntel UNCSYS=$U2 bash sckoc uncore | grep -q 'package_00_die_00   0'"
chk "AMD branch rc=1"     "MSRVEN=AuthenticAMD UNCSYS=$T/none bash sckoc uncore; [ \$? = 1 ]"
printf '#!/bin/sh\nprintf "0 2700 2700 2700\\n"\n' > "$T/mocktp"; chmod +x "$T/mocktp"
chk "tpmi fallback"       "MSRVEN=GenuineIntel UNCSYS=$T/none READOC=/nonexistent TPMIU=$T/mocktp bash sckoc uncore | grep -q '(tpmi\\|TPMI MMIO'"
chk "no data rc=1"        "MSRVEN=GenuineIntel UNCSYS=$T/none READOC=/nonexistent TPMIU=/nonexistent bash sckoc uncore; [ \$? = 1 ]"

echo "== t6 --json validity =="
chk "uncore --json parses + changed flag" \
  "MSRVEN=GenuineIntel UNCSYS=$U bash sckoc uncore --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"source\"]==\"sysfs\" and any(x[\"changed\"] for x in d[\"domains\"])'"
chk "uncore --json AMD empty doc" \
  "MSRVEN=AuthenticAMD bash sckoc uncore --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"domains\"]==[]' "
GATE=""
if [ ! -e /dev/cpu/0/msr ]; then
  if [ "$(id -u)" = 0 ]; then mkdir -p /dev/cpu/0 && touch /dev/cpu/0/msr && GATE=1; fi
fi
if [ -e /dev/cpu/0/msr ]; then
  NC=$(nproc); for i in $(seq 0 $((NC-1))); do cp "$T/cpu0.msr" "$T/cpu$i.msr" 2>/dev/null || true; done
  chk "mon --json parses" \
    "MSRVEN=GenuineIntel INT=1 READOC=$T/readoc READOC_DEV=$T/cpu%d.msr bash sckoc --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"schema\"]==\"sckoc-mon-v1\" and len(d[\"sockets\"])>=1'"
else
  echo "  skip- mon --json (no /dev/cpu/0/msr and not root)"
fi
[ -n "$GATE" ] && rm -rf /dev/cpu

echo "== t7 completion coverage =="
chk "subcommands incl uncore + --json" \
  "bash -c 'source packaging/sckoc.completion; COMP_WORDS=(sckoc \"\"); COMP_CWORD=1; _sckoc; echo \"\${COMPREPLY[*]}\"' | grep -q 'uncore.*--json\\|--json.*uncore'"
chk "uninstall -y" \
  "bash -c 'source packaging/sckoc.completion; COMP_WORDS=(sckoc uninstall \"\"); COMP_CWORD=2; _sckoc; echo \"\${COMPREPLY[*]}\"' | grep -qx -- '-y'"
chk "mon offers --json" \
  "bash -c 'source packaging/sckoc.completion; COMP_WORDS=(sckoc mon \"\"); COMP_CWORD=2; _sckoc; echo \"\${COMPREPLY[*]}\"' | grep -qx -- '--json'"

echo "== t8 cpu model block =="
chk "prints == CPU ==" \
  "bash -c 'CPUROOT=/sys/devices/system/cpu; FAM=\$(awk \"/cpu family/{print \\\$4;exit}\" /proc/cpuinfo); declare -A REP; for d in \"\$CPUROOT\"/cpu[0-9]*; do c=\${d##*cpu}; p=\$(cat \"\$d/topology/physical_package_id\" 2>/dev/null) || continue; [ -z \"\${REP[\$p]}\" ] && REP[\$p]=\$c; done; SOCKETS=\$(printf \"%s\\n\" \"\${!REP[@]}\" | sort -n); CPUS=\$(for d in \"\$CPUROOT\"/cpu[0-9]*; do echo \"\${d##*cpu}\"; done | sort -n); eval \"\$(awk \"/^siblings\\(\\)/,/^}/\" sckoc)\"; eval \"\$(awk \"/^cpu_model_block\\(\\)/,/^}/\" sckoc)\"; cpu_model_block' | grep -q '== CPU =='"

echo "== t9 mon mesh line has no (Min =="
chk "mesh line present" \
  "bash -c 'eval \"\$(awk \"/^intel_uncore\\(\\)/,/^}/\" sckoc)\"; UNC=$U LIBEXEC=/nonexistent READOC=/nonexistent intel_uncore 0 0' | grep -q Mesh"
chk "mesh line has no (Min" \
  "! bash -c 'eval \"\$(awk \"/^intel_uncore\\(\\)/,/^}/\" sckoc)\"; UNC=$U LIBEXEC=/nonexistent READOC=/nonexistent intel_uncore 0 0' | grep -q '(Min'"

echo
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]

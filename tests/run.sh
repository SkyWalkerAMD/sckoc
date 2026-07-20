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
gcc -std=gnu99 -Wall -O2 -I. -o "$T/readoc" readoc.c || bad "readoc compiles"
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
chk "CPU line carries Base via BASEM" \
  "bash -c 'CPUROOT=/sys/devices/system/cpu; FAM=\$(awk \"/cpu family/{print \\\$4;exit}\" /proc/cpuinfo); declare -A REP; for d in \"\$CPUROOT\"/cpu[0-9]*; do c=\${d##*cpu}; p=\$(cat \"\$d/topology/physical_package_id\" 2>/dev/null) || continue; [ -z \"\${REP[\$p]}\" ] && REP[\$p]=\$c; done; SOCKETS=\$(printf \"%s\\n\" \"\${!REP[@]}\" | sort -n); CPUS=\$(for d in \"\$CPUROOT\"/cpu[0-9]*; do echo \"\${d##*cpu}\"; done | sort -n); eval \"\$(awk \"/^siblings\\(\\)/,/^}/\" sckoc)\"; eval \"\$(awk \"/^cpu_model_block\\(\\)/,/^}/\" sckoc)\"; declare -A BASEM; for ss in \$SOCKETS; do BASEM[\$ss]=2500; done; cpu_model_block' | grep -q 'Base 2500 MHz'"

echo "== t9 mon mesh line has no (Min =="
chk "mesh line present" \
  "bash -c 'eval \"\$(awk \"/^intel_uncore\\(\\)/,/^}/\" sckoc)\"; UNC=$U LIBEXEC=/nonexistent READOC=/nonexistent intel_uncore 0 0' | grep -q Mesh"
chk "mesh line has no (Min" \
  "! bash -c 'eval \"\$(awk \"/^intel_uncore\\(\\)/,/^}/\" sckoc)\"; UNC=$U LIBEXEC=/nonexistent READOC=/nonexistent intel_uncore 0 0' | grep -q '(Min'"


echo "== t10 3.0.0: vid rename, info report, slim panel =="
# per-purpose readoc fixtures: adjacent MSRs alias byte ranges in the file
# emulation, so each check gets a file holding only the registers it reads.
python3 - "$T" <<'PY10'
import struct, sys
d = sys.argv[1]
def mk(p, regs):
    b = bytearray(8192)
    for r, v in regs.items(): b[r:r+8] = struct.pack('<Q', v)
    open(p, 'wb').write(bytes(b))
mk(d+'/vid0.msr',  {0x198: (9568 << 32) | (48 << 8)})   # VID 9568/8192 = 1.1680 V
mk(d+'/info0.msr', {0x194: 1 << 20,                     # OC Lock Enabled
                    0xCE: (25<<8)|(8<<40)|(8<<48)|(1<<28)|(1<<30),  # base25 eff8 min8, prog turbo+tjmax
                    0x1A2: (97<<16)|(5<<24),            # TjMax 97, TCC offset 5
                    0x1AD: 30|(30<<8)|(29<<16)|(29<<24),  # turbo bins 30/30/29/29
                    0x606: (10 << 8) | 3,               # pu=3
                    0x610: (1 << 47) | (2000 << 32) | (1 << 15) | 1000})  # PL1 125.0/PL2 250.0, both Enabled
mk(d+'/pkg0.msr',  {0x606: 3, 0x614: 2800|(1600<<16)|(4000<<32)})  # TDP 350/Min 200/Max 500 W
mk(d+'/turbo1.msr',{0x1AD: 48})                         # single turbo bin 48x (bare, no binN)
mk(d+'/mon0.msr',  {0xCE: 25 << 8})                     # base ratio 25 -> 2500 MHz
PY10
mkdir -p "$T/sb2" "$T/topo/cpu0/topology"
printf '\x00\x00\x00\x01' > "$T/sb2/SecureBoot-test"
echo "none [integrity] confidentiality" > "$T/ld2"
echo 0 > "$T/topo/cpu0/topology/core_cpus_list"; echo 0 > "$T/topo/cpu0/topology/physical_package_id"
mkdir -p "$T/topo/cpu0/cache/index0" "$T/topo/cpu0/cache/index3"
echo 1 > "$T/topo/cpu0/cache/index0/level"; echo Data > "$T/topo/cpu0/cache/index0/type"; echo 48K > "$T/topo/cpu0/cache/index0/size"
echo 3 > "$T/topo/cpu0/cache/index3/level"; echo Unified > "$T/topo/cpu0/cache/index3/type"; echo 320M > "$T/topo/cpu0/cache/index3/size"
# populated dmidecode: dram_speed/dram_detail must not abort the rest under any
# guard-returns-nonzero path (regression: dmidecode WITH data used to kill mon)
cat > "$T/fakedmi" <<'DMI'
#!/bin/sh
cat <<'OUT'
Memory Device
	Total Width: 80 bits
	Size: 16 GB
	Locator: CPU0_DIMM_A1
	Bank Locator: NODE 0
	Configured Memory Speed: 6400 MT/s
	Configured Voltage: 1.1 V

OUT
DMI
chmod +x "$T/fakedmi"
cat > "$T/fakeipmi" <<'FIP'
#!/bin/bash
C="$0.cnt"
if [ "$1 $2 $3" = "sdr type Temperature" ]; then
cat <<'TBL'
CPU Package Temp | 01h |  ok  |  3.0 | 31 degrees C
VR CPU Temp      | 20h |  ok  |  7.0 | 45 degrees C
DIMMA1_Temp      | 04h |  ns  |  8.0 | No Reading
DIMMC1_Temp      | 06h |  ok  |  8.0 | 30 degrees C
DIMMF1_Temp      | 09h |  ok  |  8.0 | 30 degrees C
TBL
elif [ "$1 $2 $3" = "raw 0x04 0x2d" ]; then
  case "$4" in
    0x06) echo " 1e 40 40" ;;
    0x09) echo " 1d 40 40" ;;
    *) n=$(cat "$C" 2>/dev/null || echo 0); echo $((n+1)) > "$C"
       if [ "$n" -le 1 ]; then echo " 1f 40 40"; else echo " 21 40 40"; fi ;;
  esac
fi
FIP
chmod +x "$T/fakeipmi"
cat > "$T/slowipmi" <<'FIP'
#!/bin/bash
[ "$1 $2 $3" = "sdr type Temperature" ] && { sleep 2; echo "CPU Package Temp | 01h | ok | 3.0 | 31 degrees C"; }
FIP
chmod +x "$T/slowipmi"
cat > "$T/dmidup" <<'DMI'
#!/bin/sh
cat <<'OUT'
Memory Device
	Size: 32 GB
	Locator: DIMM 0
	Configured Memory Speed: 6400 MT/s
	Configured Voltage: 1.1 V

Memory Device
	Size: 32 GB
	Locator: DIMM 0
	Configured Memory Speed: 6400 MT/s
	Configured Voltage: 1.1 V

OUT
DMI
chmod +x "$T/dmidup"

bash sckoc help > "$T/help.out"
chk "help lists vid"               "grep -q 'sckoc vid ' '$T/help.out'"
chk "help lists info"              "grep -q 'sckoc info ' '$T/help.out'"
chk "help uncore line has Min/Max" "grep -q 'Min/Max' '$T/help.out'"
chk "help USAGE block has no vcore" "! sed -n '/^USAGE:/,/^ENVIRONMENT:/p' '$T/help.out' | grep -q vcore"
chk "help notes deprecated alias"  "grep -q \"deprecated alias of 'vid'\" '$T/help.out'"
if echo x | grep -qP 'x' 2>/dev/null; then
  chk "sckoc CLI has no CJK text"  "! grep -qP '\p{Han}' sckoc"
else
  echo "  skip- CJK scan (grep -P unavailable)"
fi

bash -c 'source packaging/sckoc.completion; COMP_WORDS=(sckoc ""); COMP_CWORD=1; _sckoc; echo "${COMPREPLY[*]}"' > "$T/comp.out"
chk "completion offers vid"        "grep -qw vid '$T/comp.out'"
chk "completion offers info"       "grep -qw info '$T/comp.out'"
chk "completion dropped vcore"     "! grep -qw vcore '$T/comp.out'"

cat > "$T/vidh.sh" <<EOSH
CPUROOT="$T/topo"; VEN=GenuineIntel; CPUS=0
READOC="$T/readoc"; export READOC_DEV="$T/vid%d.msr"
rf(){ "\$READOC" -p "\$1" -u "\$2" 2>/dev/null || echo 0; }
bits(){ echo \$(( (\$1 >> \$2) & ((1 << \$3) - 1) )); }
wt4(){ awk "BEGIN{printf \"%.4f\", \$1}"; }
eval "\$(awk '/^siblings\(\)/,/^}/' sckoc)"
eval "\$(awk '/^vid_cmd\(\)/,/^}/' sckoc)"
vid_cmd
EOSH
chk "vid header: English, requested"  "bash '$T/vidh.sh' | grep -q 'requested voltage / regulator target'"
chk "vid header: not measured"        "bash '$T/vidh.sh' | grep -q 'not measured'"
chk "vid value decode"                "bash '$T/vidh.sh' | grep -q 'core0 *1\.1680 V'"

I10="MSRVEN=GenuineIntel READOC=$T/readoc READOC_DEV=$T/info%d.msr SBDIR=$T/sb2 LDF=$T/ld2"
chk "info platform line"  "env $I10 bash sckoc info | grep -q 'Secure Boot Enabled  Lockdown integrity  OC Lock Enabled'"
chk "info CPU ratio ceilings" "env $I10 bash sckoc info | grep -q 'Base 25x (2500 MHz)  Max-Eff 8x  Min 8x'"
chk "info programmable flags"  "env $I10 bash sckoc info | grep -q 'Programmable: turbo-ratio yes'"
chk "info turbo ratio bins"    "env $I10 bash sckoc info | grep -q 'Turbo Ratio Limits' && env $I10 bash sckoc info | grep -q '30x'"
ITB="MSRVEN=GenuineIntel READOC=$T/readoc READOC_DEV=$T/turbo1.msr SBDIR=$T/sb2 LDF=$T/ld2"
chk "info single turbo bin bare" "env $ITB bash sckoc info | grep -qE '^ +48x$' && ! env $ITB bash sckoc info | grep -q 'bin0'"
chk "info thermal TjMax"       "env $I10 bash sckoc info | grep -q 'TjMax 97' && env $I10 bash sckoc info | grep -q 'PROCHOT offset 5'"
chk "info PL line + window"    "env $I10 bash sckoc info | grep -qE 'S0  PL1 125.0 W \(Enabled, [0-9.]+ s\)  PL2 250.0 W \(Enabled, [0-9.]+ s\)'"
chk "info package envelope"    "env MSRVEN=GenuineIntel READOC=$T/readoc READOC_DEV=$T/pkg%d.msr SBDIR=$T/sb2 LDF=$T/ld2 bash sckoc info | grep -q 'Package: TDP 350.0 W  Min 200.0 W  Max 500.0 W'"
chk "info cache topology"      "env MSRVEN=GenuineIntel CPUROOT=$T/topo READOC=$T/readoc READOC_DEV=$T/info%d.msr SBDIR=$T/sb2 LDF=$T/ld2 bash sckoc info | grep -q '== Cache' && env MSRVEN=GenuineIntel CPUROOT=$T/topo READOC=$T/readoc READOC_DEV=$T/info%d.msr SBDIR=$T/sb2 LDF=$T/ld2 bash sckoc info | grep -q 'L1d 48K'"
IDMI="MSRVEN=GenuineIntel CPUROOT=$T/topo READOC=$T/readoc READOC_DEV=$T/info%d.msr SBDIR=$T/sb2 LDF=$T/ld2 DMI=$T/fakedmi IPMITOOL=/nonexistent"
chk "info memory parsed"      "env $IDMI bash sckoc info | grep -qE 'CPU0_DIMM_A1.*6400 MT/s.*1.1 V.*16 GB'"
chk "info populated memory keeps Cache" "env $IDMI bash sckoc info | grep -q '== Memory' && env $IDMI bash sckoc info | grep -q '== Cache'"
chk "info without msr degrades" "env MSRVEN=GenuineIntel READOC=/nonexistent SBDIR=$T/sb2 LDF=$T/ld2 bash sckoc info | grep -q 'N/A (need msr module'"

GATE2=""
if [ ! -e /dev/cpu/0/msr ]; then
  if [ "$(id -u)" = 0 ]; then mkdir -p /dev/cpu/0 && touch /dev/cpu/0/msr && GATE2=1; fi
fi
if [ -e /dev/cpu/0/msr ]; then
  NC=$(nproc); for i in $(seq 0 $((NC-1))); do [ "$i" = 0 ] || cp "$T/mon0.msr" "$T/mon$i.msr"; done
  M10="MSRVEN=GenuineIntel INT=1 READOC=$T/readoc READOC_DEV=$T/mon%d.msr DMI=/bin/false UNCSYS=$T/none TPMIU=/nonexistent"
  env $M10 bash sckoc > "$T/mon.out" 2>/dev/null || true
  chk "mon: Platform line moved out"   "! grep -q '== Platform ==' '$T/mon.out'"
  chk "mon: PL1/PL2 moved out"         "! grep -q 'PL1 ' '$T/mon.out'"
  chk "mon: per-socket rows present"   "grep -q 'Per-socket Overview' '$T/mon.out'"
  chk "mon: Base moved to CPU block"   "grep -q 'Base 2500 MHz' '$T/mon.out' && ! grep -q '(Base' '$T/mon.out'"
  env $M10 DMI=$T/fakedmi bash sckoc > "$T/monp.out" 2>/dev/null || true
  chk "mon survives populated dmidecode" "grep -q 'Per-socket Overview' '$T/monp.out'"
  # AMD: a package energy counter that does not advance (static fixture reads
  # the same value at T0 and T1) must not render "Pkg 0.0 W" - regression for
  # Threadripper PRO 9955WX where 0xC001029B stays 0 while per-core advances.
  python3 - "$T" <<'PYA'
import struct, sys
p = sys.argv[1] + '/amd0.msr'
with open(p, 'wb') as f:
    f.seek(0xC0010299); f.write(struct.pack('<Q', 16 << 8))        # energy unit 2^-16
    f.seek(0xC0010064); f.write(struct.pack('<Q', (1 << 63) | 900))  # P0 enabled, FID 900 -> 4500 MHz (fam26)
PYA
  A10="MSRVEN=AuthenticAMD MSRFAM=26 INT=1 READOC=$T/readoc READOC_DEV=$T/amd%d.msr DMI=/bin/false UNCSYS=$T/none TPMIU=/nonexistent SMUDRV=$T/none IPMITOOL=/nonexistent HWROOT=$T/nohw"
  env $A10 bash sckoc > "$T/mona.out" 2>/dev/null || true
  chk "AMD mon: dead pkg counter -> N/A" "grep -q 'Pkg N/A (energy counter not advancing' '$T/mona.out' && ! grep -q 'Pkg 0.0 W' '$T/mona.out'"
  chk "AMD json: dead pkg counter -> null" "env $A10 bash sckoc --json 2>/dev/null | grep -q '\"pkg_w\":null'"
  chk "AMD mon: P-state fallback labelled VID" "grep -qE 'VID (~|N/A)' '$T/mona.out' && ! grep -q 'Vcore ~' '$T/mona.out'"
  rm -f /run/sckoc-bmc /run/sckoc-bmc-dimm 2>/dev/null || true
  IPB="MSRVEN=AuthenticAMD MSRFAM=26 INT=1 READOC=$T/readoc READOC_DEV=$T/amd%d.msr DMI=/bin/false UNCSYS=$T/none TPMIU=/nonexistent SMUDRV=$T/none HWROOT=$T/nohw IPMITOOL=$T/fakeipmi BMCCACHE=$T/bmcc BMCDIMMS=$T/bmcdimm"
  env $IPB bash sckoc > "$T/monb1.out" 2>/dev/null || true
  chk "AMD mon: BMC temp fallback (probe)" "grep -q 'Temp Max 31' '$T/monb1.out' && grep -q '(bmc)' '$T/monb1.out'"
  chk "AMD mon: BMC probe caches sensor id + raw mode" "[ \"\$(cat '$T/bmcc')\" = 'CPU Package Temp|01|raw' ]"
  env $IPB bash sckoc > "$T/monb2.out" 2>/dev/null || true
  chk "AMD mon: BMC cached raw single-message read" "grep -q 'Temp Max 33' '$T/monb2.out'"
  env $IPB IPMITOOL=$T/slowipmi BMCCACHE=$T/bmslow BMCDIMMS=$T/bmslowd BMCPROBET=1 bash sckoc >/dev/null 2>&1 || true
  chk "AMD mon: slow-BMC timeout is not negative-cached" "[ ! -e '$T/bmslow' ]"
  chk "info: duplicate DIMM locators numbered" "env MSRVEN=AuthenticAMD MSRFAM=26 READOC=$T/readoc READOC_DEV=$T/amd%d.msr SBDIR=$T/sb2 LDF=$T/ld2 DMI=$T/dmidup IPMITOOL=/nonexistent BMCDIMMS=$T/nodimm bash sckoc info | grep -q 'DIMM 0 #2'"
SLOTE="MSRVEN=AuthenticAMD MSRFAM=26 READOC=$T/readoc READOC_DEV=$T/amd%d.msr SBDIR=$T/sb2 LDF=$T/ld2 DMI=$T/dmidup IPMITOOL=$T/fakeipmi BMCCACHE=$T/slotc BMCDIMMS=$T/slotd"
chk "info: BMC slot names replace blank locators" "env $SLOTE bash sckoc info | grep -q 'DIMMC1 (bmc)' && env $SLOTE bash sckoc info | grep -q 'DIMMF1 (bmc)'"
chk "info: BMC DIMM rows show live temperature" "env $SLOTE bash sckoc info | grep -Eq 'DIMMC1 \(bmc\).*32 GB +30' && env $SLOTE bash sckoc info | grep -Eq 'DIMMF1 \(bmc\).*32 GB +29'"
  V10="MSRVEN=GenuineIntel READOC=$T/readoc READOC_DEV=$T/vid%d.msr"
  env $V10 bash sckoc vcore > "$T/vc.out" 2> "$T/vc.err" || true
  chk "vcore alias: stderr notice"     "grep -q \"use 'sckoc vid'\" '$T/vc.err'"
  chk "vcore alias: still functional"  "grep -q 'Per-core VID' '$T/vc.out'"
  env $V10 bash sckoc vid > /dev/null 2> "$T/v2.err" || true
  chk "vid: no deprecation on stderr"  "! grep -q vid '$T/v2.err'"
else
  echo "  skip- mon layout / vcore alias (no /dev/cpu/0/msr and not root)"
fi
[ -n "$GATE2" ] && rm -rf /dev/cpu
echo
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]

#!/bin/bash
# install.sh: one-click install/upgrade for sckoc (Intel/AMD read-only monitor)
set -e
[ "$(id -u)" = 0 ] || { echo "run as root / sudo"; exit 1; }

OLD=$( { /usr/local/bin/sckoc -V 2>/dev/null || /usr/local/bin/msr -V 2>/dev/null; } | grep -E "^(msr|sckoc)" || true)
[ -n "$OLD" ] && echo "== old version detected: $OLD, upgrading =="
rm -f /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/msr /usr/local/bin/msr-w890e /usr/local/bin/msr-tr \
      /usr/local/bin/hsmp-fclk /usr/local/bin/hsmp-msg \
      /etc/bash_completion.d/sckoc

command -v gcc >/dev/null || {
  if command -v dnf >/dev/null; then dnf -y install gcc
  elif command -v yum >/dev/null; then yum -y install gcc
  elif command -v apt-get >/dev/null; then apt-get -y install gcc
  else echo "no package manager found, install gcc manually"; exit 1; fi
}
command -v dmidecode >/dev/null || {
  { command -v dnf >/dev/null && dnf -y install dmidecode; } || { command -v yum >/dev/null && yum -y install dmidecode; } || { command -v apt-get >/dev/null && apt-get -y install dmidecode; } || true
} 2>/dev/null

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/version.h" <<'VER_H'
#ifndef SCKOC_VERSION_H
#define SCKOC_VERSION_H
#define VERSION_STRING "2.0.0"
#endif
VER_H
cat > "$T/readoc.c" <<'READOC_C'
/*
 * readoc.c - MSR reader for sckoc (socket/overclock monitor)
 *
 * Reads a Model-Specific Register from /dev/cpu/N/msr.
 *
 * Part of sckoc. Original implementation, GPL-2.0-only.
 * Copyright (C) 2026 SkyWalkerAMD
 *
 * Reads one 64-bit MSR at the given register number on a chosen CPU,
 * optionally extracting a [high:low] bitfield, and prints it as
 * unsigned decimal (default) or hexadecimal.
 *
 * This is a deliberately small, read-only helper: it never writes MSRs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <getopt.h>
#include <inttypes.h>

#include "version.h"

enum out_fmt { FMT_UDEC, FMT_HEX, FMT_HEX_UPPER };

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s [-p cpu] [-f high:low] [-u|-x|-X] regno\n"
		"  -p cpu        CPU number to read from (default 0)\n"
		"  -f high:low   extract bitfield [high:low] only\n"
		"  -u            unsigned decimal output (default)\n"
		"  -x            hexadecimal output (lower case)\n"
		"  -X            hexadecimal output (upper case)\n"
		"  -V            print version\n"
		"  -h            print this help\n",
		prog);
}

int main(int argc, char *argv[])
{
	int cpu = 0;
	unsigned hi = 63, lo = 0;
	enum out_fmt fmt = FMT_UDEC;
	int c;

	while ((c = getopt(argc, argv, "p:f:uxXVh")) != -1) {
		switch (c) {
		case 'p': {
			char *end;
			long v = strtol(optarg, &end, 0);
			if (*end || v < 0 || v > 8191) {
				usage(argv[0]);
				return 127;
			}
			cpu = (int)v;
			break;
		}
		case 'f':
			if (sscanf(optarg, "%u:%u", &hi, &lo) != 2 ||
			    hi > 63 || lo > hi) {
				usage(argv[0]);
				return 127;
			}
			break;
		case 'u': fmt = FMT_UDEC;      break;
		case 'x': fmt = FMT_HEX;       break;
		case 'X': fmt = FMT_HEX_UPPER; break;
		case 'V':
			fprintf(stderr, "readoc %s\n", VERSION_STRING);
			return 0;
		case 'h':
			usage(argv[0]);
			return 0;
		default:
			usage(argv[0]);
			return 127;
		}
	}

	if (optind != argc - 1) {
		usage(argv[0]);
		return 127;
	}

	uint32_t reg = (uint32_t)strtoul(argv[optind], NULL, 0);

	char path[64];
	snprintf(path, sizeof(path), "/dev/cpu/%d/msr", cpu);

	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "readoc: cannot open %s: %s\n",
			path, strerror(errno));
		return 2;
	}

	uint64_t val;
	if (pread(fd, &val, sizeof(val), reg) != (ssize_t)sizeof(val)) {
		fprintf(stderr, "readoc: cannot read MSR 0x%" PRIx32
			" on cpu %d: %s\n", reg, cpu, strerror(errno));
		close(fd);
		return 4;
	}
	close(fd);

	/* extract bitfield if narrower than the full 64 bits */
	unsigned width = hi - lo + 1;
	if (width < 64) {
		val >>= lo;
		val &= (UINT64_C(1) << width) - 1;
	}

	switch (fmt) {
	case FMT_HEX:       printf("%" PRIx64 "\n", val); break;
	case FMT_HEX_UPPER: printf("%" PRIX64 "\n", val); break;
	case FMT_UDEC:
	default:            printf("%" PRIu64 "\n", val); break;
	}

	return 0;
}
READOC_C
gcc -I"$T" -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 "$T/readoc.c" -o /usr/local/bin/readoc
cat > "$T/hsmp-msg.c" <<'HSMP_C'
/* hsmp-msg: generic HSMP query. usage: hsmp-msg <msg_id> <response_sz> <sock> [arg0..]
   prints response words space-separated */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/types.h>

#if defined(__has_include)
# if __has_include(<asm/amd_hsmp.h>)
#  include <asm/amd_hsmp.h>
#  define HAVE_HSMP_HDR
# endif
#endif
#ifndef HAVE_HSMP_HDR
#pragma pack(4)
struct hsmp_message {
	__u32 msg_id;
	__u16 num_args;
	__u16 response_sz;
	__u32 args[8];
	__u16 sock_ind;
};
#pragma pack()
#define HSMP_IOCTL_CMD _IOWR(0xF8, 0, struct hsmp_message)
#endif

int main(int argc, char *argv[])
{
	struct hsmp_message msg = {0};
	int i, fd;
	if (argc < 4) { fprintf(stderr, "usage: %s msg_id response_sz sock [args..]\n", argv[0]); return 1; }
	fd = open("/dev/hsmp", O_RDONLY);
	if (fd < 0) { perror("open /dev/hsmp"); return 1; }
	msg.msg_id = strtoul(argv[1], NULL, 0);
	msg.response_sz = strtoul(argv[2], NULL, 0);
	if (msg.response_sz > 8) msg.response_sz = 8; /* args[] holds at most 8 words */
	msg.sock_ind = strtoul(argv[3], NULL, 0);
	msg.num_args = argc - 4;
	for (i = 4; i < argc && i - 4 < 8; i++) msg.args[i - 4] = strtoul(argv[i], NULL, 0);
	if (ioctl(fd, HSMP_IOCTL_CMD, &msg) < 0) { perror("hsmp ioctl"); return 2; }
	for (i = 0; i < msg.response_sz; i++) printf("%u%s", msg.args[i], i + 1 < msg.response_sz ? " " : "\n");
	close(fd);
	return 0;
}
HSMP_C
gcc -Wall -O2 "$T/hsmp-msg.c" -o /usr/local/bin/hsmp-msg

cat > /usr/local/bin/sckoc <<'MSR_SH'
#!/bin/bash
# sckoc: Intel/AMD read-only hardware monitor (no writes)
MSRVER=2.0.0
set -e
LIBEXEC=/usr/libexec/sckoc
READOC="${READOC:-$( [ -x "$LIBEXEC/readoc" ] && echo "$LIBEXEC/readoc" || command -v readoc || echo readoc )}"
INT="${INT:-1}"
rf(){ "$READOC" -p "$1" -u "$2" 2>/dev/null || echo 0; }
bits(){ echo $(( ($1 >> $2) & ((1 << $3) - 1) )); }

usage(){
  cat <<USAGE
sckoc $MSRVER - read-only MSR/HSMP hardware monitor for Intel & AMD

USAGE:
  sckoc [mon]              full monitor panel (default when no argument)
  sckoc vcore             per-core / per-rail core voltage
  sckoc dump <reg> [hi:lo]  read an MSR on every socket, optional bitfield
  sckoc uninstall [-y]    remove sckoc (auto-detects script/rpm/deb install)
  sckoc version | -V      print version
  sckoc help | -h         this help

ENVIRONMENT:
  INT=<sec>                 sampling window for freq/power/C0 (default 1)
  DMI=<path>                override dmidecode path

EXAMPLES:
  sudo sckoc                       # one-shot overview
  sudo INT=2 sckoc                 # 2-second sampling window
  sudo watch -n 3 sckoc            # refresh every 3 s
  sudo sckoc vcore                 # core voltage per core / rail
  sudo sckoc dump 0x198 47:32      # Intel Vcore field, all sockets
  sudo sckoc dump 0xC0010064       # AMD P-state 0 definition
  sudo sckoc uninstall -y          # remove without prompt

NOTES:
  Root required. Reads only - never writes MSRs (Secure Boot / lockdown safe).
  Intel needs the msr module. AMD FCLK/PPT need /dev/hsmp (amd_hsmp or hsmp_acpi
  plus BIOS HSMP). AMD temperature needs k10temp. Voltage rails need a board
  Super I/O driver (nct6775 etc).
USAGE
}
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  -V|version) echo "sckoc $MSRVER"; exit 0 ;;
  uninstall)
    [ "$(id -u)" = 0 ] || { echo "run as root: sudo sckoc uninstall"; exit 1; }
    echo "This will completely remove sckoc (package, files, completion, module autoload, repo configs)."
    if [ "${2:-}" != "-y" ]; then
      printf "Continue? [y/N] "; read -r a
      case "$a" in y|Y) ;; *) echo "aborted"; exit 1 ;; esac
    fi
    if command -v rpm >/dev/null && rpm -q sckoc >/dev/null 2>&1; then
      { command -v dnf >/dev/null && dnf -y remove sckoc; } || { command -v yum >/dev/null && yum -y remove sckoc; } || rpm -e sckoc
    fi
    if command -v dpkg >/dev/null && dpkg -s sckoc >/dev/null 2>&1; then
      { command -v apt-get >/dev/null && apt-get -y remove sckoc; } || dpkg -r sckoc
    fi
    rm -f /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/hsmp-msg \
          /usr/local/bin/msr /usr/local/bin/msr-w890e /usr/local/bin/msr-tr /usr/local/bin/hsmp-fclk \
          /etc/bash_completion.d/sckoc \
          /etc/modules-load.d/msr.conf /etc/modules-load.d/sckoc.conf /etc/modules-load.d/sckoc-amd.conf /etc/modules-load.d/sckoc-sensors.conf /usr/lib/modules-load.d/sckoc.conf \
          /etc/apt/sources.list.d/sckoc.list
    if [ -f /var/lib/sckoc/dkms-amd-hsmp ]; then
      HV=$(cat /var/lib/sckoc/dkms-amd-hsmp)
      dkms remove -m amd_hsmp -v "$HV" --all 2>/dev/null || true
      rm -rf "/usr/src/amd_hsmp-$HV"
      echo "removed DKMS amd_hsmp $HV (installed by sckoc installer)"
    elif command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^amd_hsmp'; then
      echo "note: DKMS amd_hsmp was NOT installed by sckoc - kept."
      echo "      remove manually: dkms remove -m amd_hsmp -v <ver> --all; rm -rf /usr/src/amd_hsmp-<ver>"
    fi
    rm -rf /var/lib/sckoc
    if command -v dnf >/dev/null && dnf copr list 2>/dev/null | grep -q sckoc; then
      dnf -y copr remove skywalkeramd/sckoc 2>/dev/null || dnf -y copr disable skywalkeramd/sckoc 2>/dev/null || true
    fi
    echo "sckoc fully removed. (shared deps gcc/dmidecode/dkms/git kept; loaded kernel modules stay until reboot)"
    exit 0 ;;
esac

[ -e /dev/cpu/0/msr ] || { echo "msr module not loaded, run: sudo modprobe msr"; exit 1; }
CPUROOT="${CPUROOT:-/sys/devices/system/cpu}"
VEN="${MSRVEN:-$(awk '/vendor_id/{print $3;exit}' /proc/cpuinfo)}"
FAM="${MSRFAM:-$(awk '/cpu family/{print $4;exit}' /proc/cpuinfo)}"

declare -A REP
for d in "$CPUROOT"/cpu[0-9]*; do
  c=${d##*cpu}; p=$(cat "$d/topology/physical_package_id" 2>/dev/null) || continue
  [ -z "${REP[$p]}" ] && REP[$p]=$c
done
SOCKETS=$(printf '%s\n' "${!REP[@]}" | sort -n)
CPUS=$(for d in "$CPUROOT"/cpu[0-9]*; do echo "${d##*cpu}"; done | sort -n)

wt(){ awk "BEGIN{printf \"%.1f\", $1}"; }
siblings(){
  local f l t
  for f in core_cpus_list thread_siblings_list; do
    l=$(cat "$CPUROOT/cpu$1/topology/$f" 2>/dev/null) && break
  done
  [ -z "$l" ] && { echo "$1"; return; }
  for t in ${l//,/ }; do
    case "$t" in *-*) seq "${t%-*}" "${t#*-}";; *) echo "$t";; esac
  done | sort -n
}
# board-specific nct6798 channel -> CPU rail map (verified by BIOS-vs-sysfs delta test)
# returns "railN_mV railM_mV ..." for known boards, empty otherwise
board_nct(){
  local dir="$1"   # hwmon dir of nct chip
  local board
  board=$( (${DMI:-dmidecode} -s baseboard-product-name 2>/dev/null || :) | head -1)
  case "$board" in
    *WRX90E-SAGE*)
      # in0=VDDCR_CPU0, in6=VDDCR_CPU1 (both confirmed vs BIOS override delta on 9995WX)
      echo "VDDCR_CPU0:$(cat "$dir/in0_input" 2>/dev/null) VDDCR_CPU1:$(cat "$dir/in6_input" 2>/dev/null)"
      ;;
    *) echo "" ;;
  esac
}
# fetch a single mapped rail value in volts, or empty. $1=rail label
board_vcore(){
  local want="$1" h n pair k v
  for h in /sys/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null) || continue
    case "$n" in nct*) ;; *) continue ;; esac
    for pair in $(board_nct "$h"); do
      k=${pair%%:*}; v=${pair#*:}
      [ "$k" = "$want" ] && [ -n "$v" ] && { awk "BEGIN{printf \"%.3f\", $v/1000}"; return 0; }
    done
  done
  return 1
}
platform_info(){
  local sb ld oc="" f
  DRAMSPD=$( (${DMI:-dmidecode} -t 17 2>/dev/null || :) | awk -F": " '
    /Configured Memory Speed: [0-9]/{spd=$2}
    /Configured Voltage:/{ if(spd!=""){ v=($2 ~ /^[0-9]/) ? " @ " $2 : ""; c[spd v]++; spd="" } }
    END{n=0; for(k in c){printf "%s%s (%d DIMMs)",(n++?", ":""),k,c[k]}}')
  [ -z "$DRAMSPD" ] && DRAMSPD="N/A (need dmidecode)"
  f=$(ls "${SBDIR:-/sys/firmware/efi/efivars}"/SecureBoot-* 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    sb=$( [ "$(od -An -tu1 "$f" 2>/dev/null | awk "{v=\$NF} END{print v}")" = 1 ] && echo Enabled || echo Disabled)
  else sb="N/A"; fi
  ld=$(grep -o "\[[a-z]*\]" "${LDF:-/sys/kernel/security/lockdown}" 2>/dev/null | tr -d "[]" || :)
  [ -z "$ld" ] && ld=none
  if [ "$VEN" = GenuineIntel ]; then
    local v194
    if v194=$("$READOC" -p 0 -u 0x194 2>/dev/null); then
      oc="  OC Lock $( [ "$(bits "$v194" 20 1)" = 1 ] && echo Enabled || echo Disabled)"
    fi
  fi
  local smt numa smu=""
  smt=$( [ "$(cat "$CPUROOT/smt/active" 2>/dev/null)" = 1 ] && echo On || echo Off)
  numa=$(ls -d "${NODEROOT:-/sys/devices/system/node}"/node[0-9]* 2>/dev/null | wc -l)
  if [ "$VEN" = AuthenticAMD ]; then
    local sv
    if sv=$(hsmp_q 0x02 1 0); then
      smu="  SMU FW $(( (sv>>16)&255 )).$(( (sv>>8)&255 )).$(( sv&255 ))"
    fi
  fi
  echo "== Platform =="
  printf "  Secure Boot %s  Lockdown %s%s  SMT %s  NUMA %s node(s)%s\n" "$sb" "$ld" "$oc" "$smt" "$numa" "$smu"
  local h n lab v out=""
  for h in /sys/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null) || continue
    case "$n" in nct*|it87*|asus*|w83*) ;; *) continue ;; esac
    for f in "$h"/in[0-9]*_input; do
      [ -e "$f" ] || continue
      lab=$(cat "${f%_input}_label" 2>/dev/null || basename "${f%_input}")
      v=$(awk "{printf \"%.3f\", \$1/1000}" "$f" 2>/dev/null) || continue
      out="$out$lab $v V  "
    done
  done
  [ -n "$out" ] && printf "  Rails: %s\n" "$out" || :
}
wt4(){ awk "BEGIN{printf \"%.4f\", $1}"; }

UNC="${UNCSYS:-/sys/devices/system/cpu/intel_uncore_frequency}"
intel_uncore(){
  local d pk mesh="" iod="" lo="" hi=""
  [ -d "$UNC" ] || modprobe intel-uncore-frequency-tpmi 2>/dev/null || modprobe intel-uncore-frequency 2>/dev/null || true
  for d in "$UNC"/uncore* "$UNC"/package_0"$1"_die_*; do
    [ -e "$d/current_freq_khz" ] || continue
    pk=$(cat "$d/package_id" 2>/dev/null || echo "$1")
    [ "$pk" = "$1" ] || continue
    if [ -z "$mesh" ]; then mesh=$(( $(cat "$d/current_freq_khz") / 1000 ))
      lo=$(( $(cat "$d/min_freq_khz" 2>/dev/null || echo 0) / 1000 ))
      hi=$(( $(cat "$d/max_freq_khz" 2>/dev/null || echo 0) / 1000 ))
    else iod="$iod $(( $(cat "$d/current_freq_khz") / 1000 ))"; fi
  done
  if [ -n "$mesh" ]; then
    local it="" m0="Mesh"; set -- $iod
    case $# in
      0) ;;
      2) it="  IOD-S $1 MHz  IOD-N $2 MHz" ;;
      3) m0="Mesh0"; it="  Mesh1 $1 MHz  IOD-S $2 MHz  IOD-N $3 MHz" ;;
      *) it="  IOD $(echo $iod | tr " " "/") MHz" ;;
    esac
    printf "%s %s MHz (Min %s, Max %s)%s" "$m0" "$mesh" "$lo" "$hi" "$it"
  else
    local v621 cur
    if v621=$("$READOC" -p "$2" -u 0x621 2>/dev/null) && cur=$(( (v621 & 127) * 100 )) && [ "$cur" -gt 0 ]; then
      printf "Mesh %d MHz (Min %d, Max %d)" "$cur" \
        $(( $(bits "$(rf "$2" 0x620)" 8 7) * 100 )) $(( $(bits "$(rf "$2" 0x620)" 0 7) * 100 ))
    else printf "Mesh N/A (need intel-uncore-frequency driver)"; fi
  fi
}
intel_sock(){
  local c=$2 v198 v19c v610 eu pu e1 e2 d1 d2 de dd tj base pl1 pl2 en thr
  tj=$(bits "$(rf "$c" 0x1A2)" 16 8); base=$(bits "$(rf "$c" 0xCE)" 8 8)
  eu=$(bits "$(rf "$c" 0x606)" 8 5);  pu=$(bits "$(rf "$c" 0x606)" 0 4)
  v610=$(rf "$c" 0x610)
  pl1=$(wt "$(bits "$v610" 0 15)/2^$pu"); pl2=$(wt "$(bits "$v610" 32 15)/2^$pu")
  local en1 en2 lk
  en1=$( [ "$(bits "$v610" 15 1)" = 1 ] && echo Enabled || echo Disabled)
  en2=$( [ "$(bits "$v610" 47 1)" = 1 ] && echo Enabled || echo Disabled)
  lk=$( [ "$(bits "$v610" 63 1)" = 1 ] && echo "  [PL Locked]" || : )
  local ts1 ts2 p21="" p61="" pcs=""
  ts1=$(rf "$c" 0x10)
  p21=$("$READOC" -p "$c" -u 0x60D 2>/dev/null) || p21=""
  p61=$("$READOC" -p "$c" -u 0x3F9 2>/dev/null) || p61=""
  e1=$(bits "$(rf "$c" 0x611)" 0 32); d1=$(bits "$(rf "$c" 0x619)" 0 32)
  sleep "$INT"
  e2=$(bits "$(rf "$c" 0x611)" 0 32); d2=$(bits "$(rf "$c" 0x619)" 0 32)
  ts2=$(rf "$c" 0x10); local dts=$(( ts2 - ts1 )); [ "$dts" -le 0 ] && dts=1
  [ -n "$p21" ] && pcs="$pcs  PC2 $(( ($("$READOC" -p "$c" -u 0x60D 2>/dev/null || echo "$p21") - p21) * 100 / dts ))%" || true
  [ -n "$p61" ] && pcs="$pcs  PC6 $(( ($("$READOC" -p "$c" -u 0x3F9 2>/dev/null || echo "$p61") - p61) * 100 / dts ))%" || true
  de=$(( e2>=e1 ? e2-e1 : e2-e1+4294967296 )); dd=$(( d2>=d1 ? d2-d1 : d2-d1+4294967296 ))
  v198=$(rf "$c" 0x198); v19c=$(rf "$c" 0x19C)
  local mx=0 t cc
  for cc in $CPUS; do
    [ "$(cat "$CPUROOT/cpu$cc/topology/physical_package_id")" = "$1" ] || continue
    t=$(( tj - $(bits "$(rf "$cc" 0x19C)" 16 7) )); [ "$t" -gt "$mx" ] && mx=$t || true
  done
  local un; un=$(intel_uncore "$1" "$c")
  thr=""; [ "$(bits "$v19c" 0 1)" = 1 ] && thr="  [THROTTLING!]"; [ -z "$thr" ] && [ "$(bits "$v19c" 1 1)" = 1 ] && thr="  [Throttle-Log]"
  printf "  S%s  Vcore %s V  Temp Max %d°C (TjMax %d°C)%s\n" "$1" "$(wt4 "$(bits "$v198" 32 16)/8192")" "$mx" "$tj" "$thr"
  printf "      Core %d00 MHz (Base %d00 MHz)  %s\n" "$(bits "$v198" 8 8)" "$base" "$un"
  printf "      DRAM %s\n" "$DRAMSPD"
  printf "      Pkg %s W  DRAM %s W%s\n" "$(wt "$de/2^$eu/$INT")" "$(wt "$dd/2^$eu/$INT")" "$pcs"
  printf "      PL1 %s W (%s)  PL2 %s W (%s)%s\n" "$pl1" "$en1" "$pl2" "$en2" "$lk"
}

amd_p0(){ local v; v=$(rf "$1" 0xC0010064)
  if [ "$FAM" -ge 26 ]; then echo $(( (v & 0xFFF) * 5 ))
  else local f=$((v & 0xFF)) d=$(( (v>>8) & 0x3F )); [ "$d" -eq 0 ] && d=8; echo $(( f*200/d )); fi; }
amd_vid(){
  local ps v vid reg
  ps=$(( $(rf "$1" 0xC0010063) & 7 ))
  reg=$(printf '0x%X' $(( 0xC0010064 + ps )))
  v=$(rf "$1" "$reg")
  if [ "$FAM" -ge 26 ]; then
    vid=$(bits "$v" 12 8)   # fam26: VID[19:12], V = 0.250 + VID*5mV (calibrated on 9995WX)
    [ "$vid" -gt 0 ] && wt4 "0.250 + $vid*0.005" || echo ""
  elif [ "$FAM" -le 23 ]; then
    vid=$(bits "$v" 14 8)   # fam17h SVI2: VID[21:14], V = 1.55 - VID*6.25mV
    [ "$vid" -gt 0 ] && [ "$vid" -lt 248 ] && wt4 "1.55 - $vid*0.00625" || echo ""
  else echo ""; fi
}
amd_temp(){
  local h i=0 f t mx=""
  for h in "${HWROOT:-/sys/class/hwmon}"/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = k10temp ] || continue
    if [ "$i" -eq "$1" ]; then
      for f in "$h"/temp[0-9]*_input; do
        [ -e "$f" ] || continue
        t=$(( $(cat "$f") / 1000 ))
        if [ -z "$mx" ] || [ "$t" -gt "$mx" ]; then mx=$t; fi
      done
      if [ -n "$mx" ]; then printf "%d°C" "$mx"; return; fi
      break
    fi
    i=$((i+1))
  done
  printf "N/A (need k10temp)"; }
hsmp_q(){
  local h="${HSMP:-$( [ -x "$LIBEXEC/hsmp-msg" ] && echo "$LIBEXEC/hsmp-msg" || command -v hsmp-msg || echo /usr/local/bin/hsmp-msg )}"
  [ -e /dev/hsmp ] || modprobe amd_hsmp 2>/dev/null || modprobe hsmp_acpi 2>/dev/null || true
  [ -e /dev/hsmp ] && [ -x "$h" ] && "$h" "$@" 2>/dev/null
}
amd_fclk(){
  local out
  if out=$(hsmp_q 0x0F 2 "$1"); then printf "FCLK %s MHz / MCLK %s MHz" ${out}
  else printf "FCLK N/A (need amd_hsmp + BIOS HSMP)"; fi
}
amd_sock(){
  local c=$2 eu e1 e2 de
  eu=$(bits "$(rf "$c" 0xC0010299)" 8 5)
  e1=$(bits "$(rf "$c" 0xC001029B)" 0 32); sleep "$INT"; e2=$(bits "$(rf "$c" 0xC001029B)" 0 32)
  de=$(( e2>=e1 ? e2-e1 : e2-e1+4294967296 ))
  local ph="" ppt=""
  [ "$(hsmp_q 0x0B 1 "$1")" = 1 ] && ph="  [PROCHOT!]" || true
  local pl plm
  if pl=$(hsmp_q 0x06 1 "$1"); then
    plm=$(hsmp_q 0x07 1 "$1") || plm=""
    ppt="  PPT $(wt "$pl/1000") W${plm:+ (Max $(wt "$plm/1000") W)}"
  fi
  # prefer real per-rail vcore from board sensor map; fall back to P-state nominal
  local vctxt r0 r1
  r0=$(board_vcore VDDCR_CPU0) || r0=""
  r1=$(board_vcore VDDCR_CPU1) || r1=""
  if [ -n "$r0" ] || [ -n "$r1" ]; then
    vctxt="Vcore ${r0:+CPU0 $r0 V}${r0:+  }${r1:+CPU1 $r1 V}"
  else
    local vc; vc=$(amd_vid "$2")
    if [ -z "$vc" ]; then vctxt="Vcore N/A"
    elif [ "$FAM" -ge 26 ]; then vctxt="Vcore ~$vc V (P-state nominal, not rail V)"
    else vctxt="Vcore ~$vc V (P-state VID)"; fi
  fi
  printf "  S%s  Temp Max %s  %s%s\n" "$1" "$(amd_temp "$1")" "$vctxt" "$ph"
  local fm="" cl="" bw="" c0=""
  if fm=$(hsmp_q 0x1C 1 "$1"); then fm="  Fmax $(( (fm>>16)&65535 )) MHz / Fmin $(( fm&65535 )) MHz"; else fm=""; fi
  if cl=$(hsmp_q 0x10 1 "$1"); then cl="  CCLK Limit $cl MHz"; else cl=""; fi
  if bw=$(hsmp_q 0x14 1 "$1"); then bw="  BW $(( (bw>>8)&4095 ))/$(( (bw>>20)&4095 )) GB/s ($(( bw&255 ))%)"; else bw=""; fi
  if c0=$(hsmp_q 0x11 1 "$1"); then c0="  C0 ${c0}%"; else c0=""; fi
  printf "      P0 Base %d MHz  %s%s%s\n" "$(amd_p0 "$c")" "$(amd_fclk "$1")" "$fm" "$cl"
  printf "      DRAM %s%s\n" "$DRAMSPD" "$bw"
  printf "      Pkg %s W%s%s\n" "$(wt "$de/2^$eu/$INT")" "$ppt" "$c0"
}

percore(){
  local -A M1 A1 E1 TJ
  local c base eu=0
  for s in $SOCKETS; do TJ[$s]=$(bits "$(rf "${REP[$s]}" 0x1A2)" 16 8); done
  [ "$VEN" = AuthenticAMD ] && eu=$(bits "$(rf 0 0xC0010299)" 8 5)
  local -A CCD CCDT PKGMIN PKGSTEP TCTL
  if [ "$VEN" = AuthenticAMD ]; then
    local l3 pk h f lab s=0 prev
    for c in $CPUS; do
      l3=$(cat "$CPUROOT/cpu$c/cache/index3/id" 2>/dev/null) || l3=-1
      CCD[$c]=$l3
      pk=$(cat "$CPUROOT/cpu$c/topology/physical_package_id" 2>/dev/null || echo 0)
      if [ "$l3" -ge 0 ]; then
        if [ -z "${PKGMIN[$pk]}" ] || [ "$l3" -lt "${PKGMIN[$pk]}" ]; then PKGMIN[$pk]=$l3; fi
        # smallest positive delta between distinct L3 ids = CCD numbering step (1 on EPYC, 2 on fam26)
        prev=${PKGMIN[$pk]}
        if [ "$l3" -gt "$prev" ]; then
          local d=$(( l3 - prev ))
          [ -z "${PKGSTEP[$pk]}" ] && PKGSTEP[$pk]=$d
          [ "$d" -lt "${PKGSTEP[$pk]}" ] && [ "$d" -gt 0 ] && PKGSTEP[$pk]=$d
        fi
      fi
    done
    for h in "${HWROOT:-/sys/class/hwmon}"/hwmon*; do
      [ "$(cat "$h/name" 2>/dev/null)" = k10temp ] || continue
      for f in "$h"/temp[0-9]*_label; do
        [ -e "$f" ] || continue
        lab=$(cat "$f")
        case "$lab" in
          Tccd[0-9]*) CCDT["$s:$(( ${lab#Tccd} - 1 ))"]=$(( $(cat "${f%_label}_input") / 1000 )) ;;
          Tctl)       TCTL[$s]=$(( $(cat "${f%_label}_input") / 1000 )) ;;
        esac
      done
      s=$((s+1))
    done
  fi
  local -A T1 C61
  for c in $CPUS; do
    M1[$c]=$(rf "$c" 0xE7); A1[$c]=$(rf "$c" 0xE8); T1[$c]=$(rf "$c" 0x10)
    [ "$VEN" = GenuineIntel ] && C61[$c]=$(rf "$c" 0x3FD)
    [ "$VEN" = AuthenticAMD ] && E1[$c]=$(bits "$(rf "$c" 0xC001029A)" 0 32)
  done
  sleep "$INT"
  for c in $CPUS; do
    local m2 a2 dm da bm=-1 sib extra=""
    sib=$(siblings "$c")
    [ "$(echo "$sib" | head -1)" = "$c" ] || continue
    local c0m=0 t2 dt c0
    for t in $sib; do
      m2=$(rf "$t" 0xE7); a2=$(rf "$t" 0xE8); t2=$(rf "$t" 0x10)
      dm=$(( m2 - M1[$t] )); da=$(( a2 - A1[$t] )); dt=$(( t2 - T1[$t] )); [ "$dt" -le 0 ] && dt=1
      c0=$(( dm * 100 / dt )); [ "$c0" -gt 100 ] && c0=100; [ "$c0" -gt "$c0m" ] && c0m=$c0 || true
      [ "$dm" -gt 0 ] && [ $(( da * 1000 / dm )) -gt "$bm" ] && { bm=$(( da * 1000 / dm )); } || true
    done
    [ "$bm" -lt 0 ] && continue
    if [ "$VEN" = GenuineIntel ]; then
      base=$(bits "$(rf "$c" 0xCE)" 8 8)
      local pkg; pkg=$(cat "$CPUROOT/cpu$c/topology/physical_package_id")
      local c62 dc6 c6p
      c62=$(rf "$c" 0x3FD); dc6=$(( c62 - C61[$c] )); [ "$dc6" -lt 0 ] && dc6=0
      c6p=$(( dc6 * 100 / dt )); [ "$c6p" -gt 100 ] && c6p=100
      extra="  $(printf '%3d' $(( TJ[$pkg] - $(bits "$(rf "$c" 0x19C)" 16 7) )))°C  $(wt4 "$(bits "$(rf "$c" 0x198)" 32 16)/8192") V  C0 $(printf '%3d' "$c0m")%  C6 $(printf '%3d' "$c6p")%"
    else
      base=$(( $(amd_p0 "$c") / 100 ))
      local e2 dE; e2=$(bits "$(rf "$c" 0xC001029A)" 0 32)
      dE=$(( e2>=E1[$c] ? e2-E1[$c] : e2-E1[$c]+4294967296 ))
      local pk2 rel tp td cd step
      pk2=$(cat "$CPUROOT/cpu$c/topology/physical_package_id" 2>/dev/null || echo 0)
      step=${PKGSTEP[$pk2]:-1}; [ "$step" -lt 1 ] && step=1
      if [ "${CCD[$c]}" -ge 0 ] && [ -n "${PKGMIN[$pk2]}" ]; then
        rel=$(( (CCD[$c] - PKGMIN[$pk2]) / step ))
        tp=${CCDT["$pk2:$rel"]:-}
        cd=$(printf 'ccd%-2d' "$rel")
      else rel=-1; tp=""; cd="ccd- "; fi
      # Tccd missing (e.g. k10temp lacks per-CCD on fam26): fall back to socket Tctl, mark with *
      if [ -n "$tp" ]; then td="$(printf '%3d' "$tp")°C"
      elif [ -n "${TCTL[$pk2]:-${TCTL[0]}}" ]; then td="$(printf '%3d' "${TCTL[$pk2]:-${TCTL[0]}}")*C"
      else td=" N/A "; fi
      extra="  $(printf '%6s' "$(wt "($dE) * ($base) * 100000000 / (2^$eu * ($dt))")") W  $cd $td  C0 $(printf '%3d' "$c0m")%"
    fi
    printf "  core%-3d %5d MHz%s\n" "$c" $(( base * 100 * bm / 1000 )) "$extra"
  done
}

mon(){
  platform_info
  echo "== $VEN fam${FAM}  Per-socket Overview =="
  for s in $SOCKETS; do
    if [ "$VEN" = GenuineIntel ]; then intel_sock "$s" "${REP[$s]}"; else amd_sock "$s" "${REP[$s]}"; fi
  done
  echo "== Per-core Overview =="
  if [ "$VEN" = GenuineIntel ]; then
    echo "  Core      Freq      Temp   Vcore        C0      C6"
  else
    local hasccd=0 hf
    for hf in "${HWROOT:-/sys/class/hwmon}"/hwmon*/temp[0-9]*_label; do
      [ -e "$hf" ] || continue
      case "$(cat "$hf" 2>/dev/null)" in Tccd*) hasccd=1; break ;; esac
    done
    if [ "$hasccd" = 1 ]; then
      echo "  Core      Freq       Power     CCD-Temp     C0"
    else
      echo "  Core      Freq       Power     CCD-Temp     C0   (*C = socket Tctl; k10temp lacks per-CCD)"
    fi
  fi
  percore
}

case "${1:-mon}" in
  mon) mon ;;
  dump) shift; for s in $SOCKETS; do
        printf "  S%s cpu%-3s = 0x%s\n" "$s" "${REP[$s]}" \
          "$("$READOC" -p "${REP[$s]}" ${2:+-f $2} -X "$1" 2>/dev/null)"; done ;;
  vcore)
    if [ "$VEN" = GenuineIntel ]; then
      echo "== Per-core Vcore (0x198[47:32], 平台若为包级则各核相同) =="
      for c in $CPUS; do
        [ "$(siblings "$c" | head -1)" = "$c" ] || continue
        printf "  core%-3d %s V\n" "$c" "$(wt4 "$(bits "$(rf "$c" 0x198)" 32 16)/8192")"
      done
    else
      br0=$(board_vcore VDDCR_CPU0) || br0=""
      br1=$(board_vcore VDDCR_CPU1) || br1=""
      if [ -n "$br0" ] || [ -n "$br1" ]; then
        echo "== Per-rail Vcore (board sensor, nct6798) =="
        [ -n "$br0" ] && printf "  VDDCR_CPU0  %s V\n" "$br0"
        [ -n "$br1" ] && printf "  VDDCR_CPU1  %s V\n" "$br1"
        echo "  (per-core identical: AMD exposes no per-core voltage; rails are VRM-domain)"
        exit 0
      fi
      v=$(amd_vid 0)
      [ -n "$v" ] || { echo "fam$FAM P-state VID 未验证 (需 zenpower/ryzen_smu 或已收录主板)"; exit 1; }
      if [ "$FAM" -ge 26 ]; then
        echo "== Per-core Vcore: P-state nominal only. fam26 dual-rail BIOS voltage is NOT in MSR =="
        echo "==   Real per-rail needs a mapped board sensor or BIOS. =="
      else
        echo "== Per-core Vcore (P-state VID; per-rail override & LLC not visible) =="
      fi
      for c in $CPUS; do
        [ "$(siblings "$c" | head -1)" = "$c" ] || continue
        printf "  core%-3d ~%s V\n" "$c" "$(amd_vid "$c")"
      done
    fi ;;
  -V|version) echo "sckoc $MSRVER"; exit 0 ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "sckoc: unknown command '$1'"; echo "try: sckoc help"; exit 1 ;;
esac
MSR_SH
chmod 755 /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/hsmp-msg

mkdir -p /etc/bash_completion.d
cat > /etc/bash_completion.d/sckoc <<'COMP_SH'
_sckoc(){
  local cur prev
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD-1]}
  local cmds="mon vcore dump uninstall version help -V -h --help"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
    return
  fi
  case "$prev" in
    dump)
      COMPREPLY=($(compgen -W "0x10 0x198 0x1A2 0xCE 0xC0010063 0xC0010064 0xC0010299 0xC001029A 0xC001029B" -- "$cur"))
      return ;;
    uninstall)
      COMPREPLY=($(compgen -W "-y" -- "$cur"))
      return ;;
  esac
}
complete -F _sckoc sckoc
COMP_SH

modprobe msr
mkdir -p /etc/modules-load.d && echo msr > /etc/modules-load.d/msr.conf

if [ "$(awk '/vendor_id/{print $3;exit}' /proc/cpuinfo)" = AuthenticAMD ]; then
  echo "== AMD platform: setting up k10temp + HSMP =="
  AMDMODS=""
  modprobe k10temp 2>/dev/null && AMDMODS="k10temp" || true
  [ -e /dev/hsmp ] || modprobe amd_hsmp 2>/dev/null || modprobe hsmp_acpi 2>/dev/null || true
  if [ ! -e /dev/hsmp ]; then
    SBON=0
    f=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
    [ -n "$f" ] && [ "$(od -An -tu1 "$f" 2>/dev/null | awk '{v=$NF} END{print v}')" = 1 ] && SBON=1
    if [ "$SBON" = 1 ]; then
      echo "== Secure Boot ENABLED: unsigned DKMS hsmp module cannot load =="
      echo "==   disable Secure Boot, or enroll a MOK key so DKMS signs the module (see README) =="
    else
      echo "== in-tree amd_hsmp not usable on this CPU, building DKMS amd_hsmp (module: hsmp_acpi) =="
      HV=2.4
      if command -v apt-get >/dev/null; then
        apt-get -y install git build-essential dkms "linux-headers-$(uname -r)"
      elif command -v dnf >/dev/null; then
        dnf -y install git gcc make "kernel-devel-$(uname -r)" || dnf -y install git gcc make kernel-devel
        dnf -y install dkms || { dnf -y install epel-release && dnf -y install dkms; }
      elif command -v yum >/dev/null; then
        yum -y install git gcc make "kernel-devel-$(uname -r)" || true
        yum -y install dkms || { yum -y install epel-release && yum -y install dkms; }
      fi
      [ -d "/usr/src/amd_hsmp-$HV" ] || git clone https://github.com/amd/amd_hsmp.git "/usr/src/amd_hsmp-$HV" || echo "== git clone failed (network?) =="
      if [ -d "/usr/src/amd_hsmp-$HV" ]; then
        dkms status 2>/dev/null | grep -q "amd_hsmp.*$HV" || dkms add -m amd_hsmp -v "$HV" || true
        if dkms build -m amd_hsmp -v "$HV" && dkms install -m amd_hsmp -v "$HV"; then
          mkdir -p /var/lib/sckoc && echo "$HV" > /var/lib/sckoc/dkms-amd-hsmp
        else echo "== DKMS build failed, FCLK/PPT will show N/A =="; fi
        modprobe hsmp_acpi 2>/dev/null || modprobe amd_hsmp 2>/dev/null || true
      fi
    fi
  fi
  if [ -e /dev/hsmp ]; then
    H=$(lsmod | awk '$1=="amd_hsmp"||$1=="hsmp_acpi"{print $1;exit}')
    [ -n "$H" ] && AMDMODS="$AMDMODS $H"
    echo "== /dev/hsmp OK (${H:-builtin}) =="
  else
    echo "== /dev/hsmp still absent: check BIOS HSMP Support (AMD CBS / NBIO), then rerun install.sh =="
  fi
  [ -n "$AMDMODS" ] && printf '%s\n' $AMDMODS > /etc/modules-load.d/sckoc-amd.conf || true
fi

SENS=""
for m in nct6775 asus_ec_sensors; do modprobe "$m" 2>/dev/null && SENS="$SENS $m" || true; done
[ -n "$SENS" ] && printf '%s\n' $SENS > /etc/modules-load.d/sckoc-sensors.conf || true

echo "== installed: $(/usr/local/bin/sckoc -V) @ $(awk '/vendor_id/{print $3;exit}' /proc/cpuinfo) =="
echo "== usage: sckoc | sckoc dump <reg> [hi:lo] | sckoc vcore | sckoc -V | INT=<sec> sckoc =="
echo "== tab completion installed (new shells; or: source /etc/bash_completion.d/sckoc) =="
echo "== first run: =="
/usr/local/bin/sckoc

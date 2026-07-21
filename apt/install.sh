#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# install.sh: one-click install/upgrade for sckoc (Intel/AMD read-only monitor)
set -e
[ "$(id -u)" = 0 ] || { echo "run as root / sudo"; exit 1; }

OLD=$(/usr/local/bin/sckoc -V 2>/dev/null || true)
[ -n "$OLD" ] && echo "== old version detected: $OLD, upgrading =="
rm -f /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/hsmp-msg /usr/local/bin/tpmi-uncore \
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

# ipmitool enables the BMC temperature path (CPU + per-DIMM) with no kernel
# driver. Best-effort: try to install it, but never fail the whole install if
# it cannot be had (e.g. an EOL repo) - sckoc degrades gracefully without it.
command -v ipmitool >/dev/null || {
  { command -v dnf >/dev/null && dnf -y install ipmitool; } || { command -v yum >/dev/null && yum -y install ipmitool; } || { command -v apt-get >/dev/null && apt-get -y install ipmitool; } || true
} 2>/dev/null

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/version.h" <<'VER_H'
/* SPDX-License-Identifier: GPL-2.0-only */
#define VERSION_STRING "3.0.12"
VER_H
cat > "$T/readoc.c" <<'READOC_C'
// SPDX-License-Identifier: GPL-2.0-only
/*
 * readoc.c - MSR reader for sckoc (socket/overclock monitor)
 *
 * Reads Model-Specific Registers from /dev/cpu/N/msr.
 *
 * Part of sckoc. Original implementation, GPL-2.0-only.
 * Copyright (C) 2026 SkyWalkerAMD
 *
 * Single mode (backward compatible): one CPU, one register, optional
 * [high:low] bitfield, printed as unsigned decimal (default) or hex.
 *
 * Batch mode: -p accepts a CPU list ("0-27" or "0,4,8-11") and the
 * register argument accepts a comma-separated list ("0xE7,0xE8,0x10").
 * If more than one cpu/register pair results, output is one line per
 * readable pair: "<cpu> <0xreg> <value>" (unsigned decimal; -f/-x/-X
 * do not apply). Unreadable pairs are silently skipped; exit 0 if at
 * least one pair was printed, 4 if none.
 *
 * READOC_DEV may override the device path printf pattern (default
 * "/dev/cpu/%d/msr"); intended for the test suite.
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

#define MAX_CPUS 8192
#define MAX_REGS 64

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s [-p cpu[,cpu|a-b]...] [-f high:low] [-u|-x|-X] regno[,regno...]\n"
		"  -p cpus       CPU number, or list/ranges e.g. 0-27 or 0,4,8-11 (default 0)\n"
		"  -f high:low   extract bitfield [high:low] only (single mode)\n"
		"  -u            unsigned decimal output (default)\n"
		"  -x            hexadecimal output (lower case)\n"
		"  -X            hexadecimal output (upper case)\n"
		"  -V            print version\n"
		"  -h            print this help\n"
		"With multiple cpu/register pairs, prints one line per readable pair:\n"
		"  <cpu> <0xreg> <value>\n",
		prog);
}

static int parse_cpu_list(const char *s, int *out, int max)
{
	int n = 0;
	while (*s) {
		char *end;
		long a = strtol(s, &end, 0);
		if (end == s || a < 0 || a >= MAX_CPUS)
			return -1;
		long b = a;
		if (*end == '-') {
			s = end + 1;
			b = strtol(s, &end, 0);
			if (end == s || b < a || b >= MAX_CPUS)
				return -1;
		}
		for (long v = a; v <= b; v++) {
			if (n >= max)
				return -1;
			out[n++] = (int)v;
		}
		if (*end == ',')
			s = end + 1;
		else if (*end == '\0')
			s = end;
		else
			return -1;
	}
	return n;
}

static int parse_reg_list(const char *s, uint32_t *out, int max)
{
	int n = 0;
	while (*s) {
		char *end;
		unsigned long v = strtoul(s, &end, 0);
		if (end == s)
			return -1;
		if (n >= max)
			return -1;
		out[n++] = (uint32_t)v;
		if (*end == ',')
			s = end + 1;
		else if (*end == '\0')
			s = end;
		else
			return -1;
	}
	return n;
}

int main(int argc, char *argv[])
{
	static int cpus[MAX_CPUS];
	static uint32_t regs[MAX_REGS];
	int ncpu = 1;
	unsigned hi = 63, lo = 0;
	enum out_fmt fmt = FMT_UDEC;
	int c;

	cpus[0] = 0;

	while ((c = getopt(argc, argv, "p:f:uxXVh")) != -1) {
		switch (c) {
		case 'p':
			ncpu = parse_cpu_list(optarg, cpus, MAX_CPUS);
			if (ncpu < 1) {
				usage(argv[0]);
				return 127;
			}
			break;
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

	int nreg = parse_reg_list(argv[optind], regs, MAX_REGS);
	if (nreg < 1) {
		usage(argv[0]);
		return 127;
	}

	const char *devfmt = getenv("READOC_DEV");
	if (!devfmt || !*devfmt)
		devfmt = "/dev/cpu/%d/msr";

	/* single mode: exactly one cpu and one register, legacy output */
	if (ncpu == 1 && nreg == 1) {
		char path[256];
		snprintf(path, sizeof(path), devfmt, cpus[0]);

		int fd = open(path, O_RDONLY);
		if (fd < 0) {
			fprintf(stderr, "readoc: cannot open %s: %s\n",
				path, strerror(errno));
			return 2;
		}

		uint64_t val;
		if (pread(fd, &val, sizeof(val), regs[0]) !=
		    (ssize_t)sizeof(val)) {
			fprintf(stderr, "readoc: cannot read MSR 0x%" PRIx32
				" on cpu %d: %s\n", regs[0], cpus[0],
				strerror(errno));
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

	/* batch mode: one line per readable cpu/register pair */
	int printed = 0;
	for (int i = 0; i < ncpu; i++) {
		char path[256];
		snprintf(path, sizeof(path), devfmt, cpus[i]);
		int fd = open(path, O_RDONLY);
		if (fd < 0)
			continue;
		for (int j = 0; j < nreg; j++) {
			uint64_t val;
			if (pread(fd, &val, sizeof(val), regs[j]) !=
			    (ssize_t)sizeof(val))
				continue;
			printf("%d 0x%" PRIx32 " %" PRIu64 "\n",
			       cpus[i], regs[j], val);
			printed++;
		}
		close(fd);
	}
	return printed ? 0 : 4;
}
READOC_C
gcc -std=gnu99 -I"$T" -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 "$T/readoc.c" -o /usr/local/bin/readoc
cat > "$T/hsmp-msg.c" <<'HSMP_C'
// SPDX-License-Identifier: GPL-2.0-only
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
gcc -std=gnu99 -Wall -O2 "$T/hsmp-msg.c" -o /usr/local/bin/hsmp-msg

cat > "$T/tpmi-uncore.c" <<'TPMI_C'
/* SPDX-License-Identifier: GPL-2.0-only */
/* tpmi-uncore.c - read-only Intel TPMI uncore frequency reader for sckoc
 *
 * Finds OOBMSM PCI devices carrying the TPMI VSEC (ID 0x42), parses the
 * PFS directory in the BAR, locates the Uncore Frequency feature (TPMI ID 2)
 * and prints, one line per fabric cluster:
 *
 *     <dev-index> <cur-MHz> <min-MHz> <max-MHz>
 *
 * Field layout verified against intel-uncore-frequency-tpmi.c and anchored
 * on live data (Xeon 658X: mesh 2900/2900/2900, IOD 2500/800/2500 x2).
 *
 * Strictly read-only: O_RDONLY, PROT_READ. Never writes to hardware.
 * Env: TPMI_PCI_ROOT overrides /sys/bus/pci/devices (for testing).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define VSEC_CAP_ID     0x000b
#define VSEC_ID_TPMI    0x0042
#define TPMI_ID_UNCORE  0x02

static uint32_t cfg_dw(const uint8_t *cfg, size_t len, size_t off)
{
    if (off + 4 > len) return 0;
    return (uint32_t)cfg[off] | (uint32_t)cfg[off+1] << 8 |
           (uint32_t)cfg[off+2] << 16 | (uint32_t)cfg[off+3] << 24;
}

/* decode one uncore feature region; returns clusters printed */
static int decode_uncore(volatile uint8_t *bar, size_t barsz, uint64_t off,
                         int nent, int esz_dw, int devidx)
{
    int printed = 0;
    size_t stride = (size_t)esz_dw * 4;

    for (int i = 0; i < nent; i++) {
        volatile uint8_t *inst = bar + off + (size_t)i * stride;
        if (off + (size_t)(i + 1) * stride > barsz) break;

        uint64_t hdr = *(volatile uint64_t *)inst;
        if ((uint32_t)hdr == 0xffffffffu) continue;      /* absent die */

        int nclus = (int)((hdr >> 8) & 0xff);
        if (nclus <= 0 || nclus > 8) continue;

        uint64_t offs = *(volatile uint64_t *)(inst + 8); /* cluster offset bytes */
        for (int c = 0; c < nclus; c++) {
            unsigned cb = ((offs >> (8 * c)) & 0xff) * 8; /* 8-byte units */
            if (cb + 16 > stride) continue;
            volatile uint8_t *cl = inst + cb;

            uint64_t status  = *(volatile uint64_t *)(cl + 0);
            uint64_t control = *(volatile uint64_t *)(cl + 8);

            unsigned cur = (unsigned)(status & 0x7f) * 100;
            unsigned max = (unsigned)((control >> 8)  & 0x7f) * 100;
            unsigned min = (unsigned)((control >> 15) & 0x7f) * 100;
            if (!cur) continue;                            /* sanity */
            printf("%d %u %u %u\n", devidx, cur, min, max);
            printed++;
        }
    }
    return printed;
}

static int probe_device(const char *root, const char *bdf, int devidx)
{
    char path[512];
    uint8_t cfg[4096];

    snprintf(path, sizeof path, "%s/%s/config", root, bdf);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t clen = read(fd, cfg, sizeof cfg);
    close(fd);
    if (clen < 0x104) return 0;                    /* no extended caps */
    if (cfg_dw(cfg, clen, 0) == 0xffffffffu) return 0;
    if ((cfg_dw(cfg, clen, 0) & 0xffff) != 0x8086) return 0;  /* Intel only */

    /* walk PCIe extended capabilities for VSEC id 0x42 (TPMI) */
    size_t cap = 0x100;
    int bir = -1; uint64_t tbl_off = 0; int guard = 64;
    while (cap && guard--) {
        uint32_t h = cfg_dw(cfg, clen, cap);
        if ((h & 0xffff) == VSEC_CAP_ID) {
            uint32_t h1 = cfg_dw(cfg, clen, cap + 4);
            if ((h1 & 0xffff) == VSEC_ID_TPMI) {
                uint32_t tbl = cfg_dw(cfg, clen, cap + 0xc);
                bir = tbl & 7;
                tbl_off = tbl & ~7u;
                break;
            }
        }
        cap = (h >> 20) & 0xffc;
    }
    if (bir < 0) return 0;

    snprintf(path, sizeof path, "%s/%s/resource%d", root, bdf, bir);
    fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open BAR (root required)"); return 0; }
    struct stat st;
    if (fstat(fd, &st) < 0 || st.st_size <= 0) { close(fd); return 0; }
    size_t barsz = (size_t)st.st_size;

    volatile uint8_t *bar = mmap(NULL, barsz, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (bar == MAP_FAILED) { perror("mmap BAR (lockdown enabled?)"); return 0; }

    /* PFS directory: 8-byte entries at tbl_off. Count comes from the VSEC
     * num_entries byte, but scanning until an all-ones/zero-size entry is
     * equally safe and avoids re-reading config. Cap at 64.               */
    int printed = 0;
    for (int e = 0; e < 64; e++) {
        uint64_t q = *(volatile uint64_t *)(bar + tbl_off + (size_t)e * 8);
        if ((uint32_t)q == 0xffffffffu) break;
        unsigned id   = q & 0xff;
        unsigned nent = (q >> 8) & 0xff;
        unsigned esz  = (q >> 16) & 0xffff;          /* dwords */
        uint64_t coff = ((q >> 32) & 0xffff) * 1024; /* KB units */
        if (!nent || !esz) break;
        if (id == TPMI_ID_UNCORE) {
            printed = decode_uncore(bar, barsz, coff, nent, esz, devidx);
            break;
        }
    }
    munmap((void *)bar, barsz);
    return printed;
}

int main(void)
{
    const char *root = getenv("TPMI_PCI_ROOT");
    if (!root) root = "/sys/bus/pci/devices";

    struct dirent **list;
    int n = scandir(root, &list, NULL, alphasort);
    if (n < 0) { perror("scandir"); return 1; }

    int devidx = 0, total = 0;
    for (int i = 0; i < n; i++) {
        if (list[i]->d_name[0] == '.') { free(list[i]); continue; }
        int p = probe_device(root, list[i]->d_name, devidx);
        if (p > 0) { devidx++; total += p; }
        free(list[i]);
    }
    free(list);
    return total > 0 ? 0 : 1;
}
TPMI_C
gcc -std=gnu99 -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 "$T/tpmi-uncore.c" -o /usr/local/bin/tpmi-uncore

cat > /usr/local/bin/sckoc <<'MSR_SH'
#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# sckoc: Intel/AMD read-only hardware monitor (no writes)
MSRVER=3.0.12
# No 'set -e': this is a read-only monitor built from many best-effort MSR
# reads, and blocks use the `[ cond ] && action` idiom throughout (which
# returns non-zero when the guard is false). Each block degrades on its own;
# a missing reading must never abort the rest of the panel or report. Fatal
# conditions are handled with explicit guarded exits instead.
LIBEXEC=/usr/libexec/sckoc
READOC="${READOC:-$( [ -x "$LIBEXEC/readoc" ] && echo "$LIBEXEC/readoc" || command -v readoc || echo /usr/local/bin/readoc )}"
INT="${INT:-1}"
rf(){ "$READOC" -p "$1" -u "$2" 2>/dev/null || echo 0; }
bits(){ echo $(( ($1 >> $2) & ((1 << $3) - 1) )); }
# unified sampling snapshots: SNAP["cpu:reg:phase"]=value, filled by ONE batched
# readoc invocation per (cpu set, phase). Register keys use readoc's canonical
# lower-case hex. Unreadable pairs simply have no key (sk tests presence).
declare -A SNAP
declare -A BASEM   # per-socket base MHz, filled by mon() for the CPU block
snap_load(){ local c r v; while read -r c r v; do case "$v" in ''|*[!0-9]*) continue ;; esac; SNAP["$c:$r:$3"]=$v; done < <("$READOC" -p "$1" "$2" 2>/dev/null); }
sv(){ printf '%s' "${SNAP["$1:$2:$3"]:-0}"; }
# per-CPU interrupt counts, IRQ["cpu:phase"], summed across every line of
# /proc/interrupts (all IRQ sources) at T0 and T1; the delta is the number of
# interrupts that CPU serviced during the sampling window. Header maps column
# position -> CPU number (robust to offline CPUs); rows with fewer than the
# CPU-count columns (ERR:/MIS: totals) are skipped. Pure read of a procfs file,
# no driver needed. IRQSRC overridable for tests.
declare -A IRQ
irq_snap(){  # $1 = phase (T0/T1)
  local cpu sum
  while read -r cpu sum; do [ -n "$cpu" ] && IRQ["$cpu:$1"]=$sum; done < <(
    awk 'NR==1{for(i=1;i<=NF;i++){c=$i;sub(/^CPU/,"",c);col[i]=c;n=i};next}
         NF>n{for(i=1;i<=n;i++)s[col[i]]+=$(i+1)}
         END{for(c in s)print c,s[c]}' "${IRQSRC:-/proc/interrupts}" 2>/dev/null)
}
# interrupts serviced during the window by a core = sum of the delta over its
# hardware threads; prints the count, or "-" when the procfs read was empty.
irq_delta(){  # $1 = space-separated sibling CPU list
  local t d0 d1 tot=0 got=0
  for t in $1; do
    d0=${IRQ["$t:T0"]:-}; d1=${IRQ["$t:T1"]:-}
    [ -n "$d0" ] && [ -n "$d1" ] && { tot=$(( tot + d1 - d0 )); got=1; }
  done
  [ "$got" = 1 ] && printf '%d' "$tot" || printf '-'
}
sk(){ [ -n "${SNAP["$1:$2:$3"]+x}" ]; }

# --- ryzen_smu PM-table fallback (read-only) ---------------------------------
# Consumer Ryzen has no HSMP, and pre-6.x kernels lack fam-1Ah k10temp; the
# out-of-tree ryzen_smu driver exposes the SMU power-metrics table instead.
# Offsets below are ONLY used when the table version matches the layout they
# were verified against (Granite Ridge / 9950X3D, anchors: FCLK=BIOS 2000,
# MCLK=DDR5-6000 1:1, per-core freq vs APERF/MPERF). Unknown version => N/A.
SMUDRV="${SMUDRV:-/sys/kernel/ryzen_smu_drv}"
SMU_PMT_VER=00620205  # fam26 Granite Ridge
# verified offsets: 0x0C PPT W | 0x2C Tctl degC | 0x11C FCLK | 0x13C MCLK
#                   0x534+4i per-core degC (16) | 0x570+4i per-core GHz
# SVI3 rails:       0x48 VDDCR_CPU V | 0xD8/0xDC/0xE0 SOC V/A/W (VxA=W verified)
#                   0xA8 VDDIO_MEM V | 0xE8 VDD_MISC V (1.1 nominal; not DIMM VDDQ)
smu_ok(){
  [ -r "$SMUDRV/pm_table" ] && [ -r "$SMUDRV/pm_table_version" ] || return 1
  [ "$(od -An -tx4 -N4 "$SMUDRV/pm_table_version" 2>/dev/null | tr -d ' \n')" = "$SMU_PMT_VER" ]
}
smu_f(){ od -An -j "$1" -N4 -tf4 "$SMUDRV/pm_table" 2>/dev/null | awk '{printf "%.1f",$1}'; }
smu_f3(){ od -An -j "$1" -N4 -tf4 "$SMUDRV/pm_table" 2>/dev/null | awk '{printf "%.3f",$1}'; }
smu_fi(){ od -An -j "$1" -N4 -tf4 "$SMUDRV/pm_table" 2>/dev/null | awk '{printf "%d",$1}'; }
# ------------------------------------------------------------------------------

usage(){
  cat <<USAGE
sckoc $MSRVER - read-only MSR/HSMP hardware monitor for Intel & AMD

USAGE:
  Overview
    sckoc [mon] [--json]    key live metrics per socket and per core
                            (--json = machine-readable document, schema v1)
  Detail
    sckoc info              static platform report: security state, CPU
                            identity/ratio ceilings, turbo bins, thermal,
                            power limits + envelope, per-DIMM memory, cache
    sckoc vid               per-core VID / per-rail voltage (Intel: requested
                            regulator target, not measured; AMD: measured
                            board/SMU rails where available)
    sckoc uncore [--json]   uncore/mesh frequency limits: Current, Min/Max
                            and the BIOS boot values (Intel)
    sckoc dump <reg> [hi:lo]  read an MSR on every socket, optional bitfield
  Maintenance
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
  sudo sckoc info                  # full static platform report
  sudo sckoc vid                   # per-core VID / rail voltage
  sudo sckoc uncore                # mesh/uncore limits + BIOS boot values
  sudo sckoc --json                # monitor as JSON (schema sckoc-mon-v1)
  sudo sckoc uncore --json         # uncore limits as JSON
  sudo sckoc dump 0x198 47:32      # Intel core VID field, all sockets
  sudo sckoc dump 0xC0010064       # AMD P-state 0 definition
  sudo sckoc uninstall -y          # remove without prompt

NOTES:
  The monitor panel deliberately shows key live data only; static platform
  configuration and per-topic detail live in the Detail commands above.
  'vcore' is accepted as a deprecated alias of 'vid'.
  Root required. Reads only - never writes MSRs (Secure Boot / lockdown safe).
  Intel needs the msr module; 'sckoc uncore' and 'sckoc info' also work
  without it (uncore needs the intel-uncore-frequency sysfs driver, kernel
  6.5+ / EL9 backport; info then omits the MSR-backed blocks).
  Per-core rows within 10°C of TjMax are flagged with '!'.
  AMD FCLK/PPT need /dev/hsmp (amd_hsmp or hsmp_acpi
  plus BIOS HSMP). AMD temperature needs k10temp. Voltage rails need a board
  Super I/O driver (nct6775 etc). On consumer Ryzen (no HSMP) or old kernels
  (no fam-1Ah k10temp), the out-of-tree ryzen_smu driver is used as a read-only
  fallback for temperature/FCLK/PPT/Vcore when present; values are marked (smu).
  On TPMI-era Xeon (Granite Rapids+) with pre-6.5 kernels, mesh/IOD frequency
  is read directly from TPMI MMIO by the tpmi-uncore helper; marked (tpmi).
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
    rm -f /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/hsmp-msg /usr/local/bin/tpmi-uncore \
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
    if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^ryzen[-_]smu'; then
      echo "note: DKMS ryzen_smu is third-party (optional sckoc data source) - kept."
      echo "      remove manually: dkms remove -m ryzen_smu -v <ver> --all; rm -rf /usr/src/ryzen_smu-<ver>;"
      echo "      rm -f /etc/modules-load.d/ryzen_smu.conf"
    fi
    if command -v dnf >/dev/null && dnf copr list 2>/dev/null | grep -q sckoc; then
      dnf -y copr remove skywalkeramd/sckoc 2>/dev/null || dnf -y copr disable skywalkeramd/sckoc 2>/dev/null || true
    fi
    rm -f /etc/yum.repos.d/_copr*skywalkeramd*sckoc*.repo
    echo "sckoc fully removed. (shared deps gcc/dmidecode/dkms/git kept; loaded kernel modules stay until reboot)"
    exit 0 ;;
esac

case "${1:-mon}" in
  uncore|info) ;;  # sysfs/firmware paths need no msr module; MSR extras degrade on their own
  *) [ -e /dev/cpu/0/msr ] || { echo "msr module not loaded, run: sudo modprobe msr"; exit 1; } ;;
esac
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
# DRAM speed summary from SMBIOS; sets the global DRAMSPD used by the
# per-socket rows. Only the configured (actual running) transfer rate - the
# SMBIOS "Configured Voltage" is a JEDEC nominal (e.g. 1.1 V) that never
# reflects the real rail, so it is not shown here (the measured VDDQ appears
# under 'sckoc info' instead).
dram_speed(){
  DRAMSPD=$( (${DMI:-dmidecode} -t 17 2>/dev/null || :) | awk -F": " '
    /Configured Memory Speed: [0-9]/{ c[$2]++ }
    END{n=0; for(k in c){printf "%s%s (%d DIMMs)",(n++?", ":""),k,c[k]}}')
  [ -z "$DRAMSPD" ] && DRAMSPD="N/A (need dmidecode)"
}
# platform configuration line (static: firmware/kernel security + topology).
# Shown by 'sckoc info', not by the monitor panel.
platform_line(){
  local sb ld oc="" f
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
  local smt smtlab numa smu=""
  smt=$( [ "$(cat "$CPUROOT/smt/active" 2>/dev/null)" = 1 ] && echo On || echo Off)
  smtlab=$( [ "$VEN" = GenuineIntel ] && echo HT || echo SMT)   # Intel calls it Hyper-Threading
  numa=$(ls -d "${NODEROOT:-/sys/devices/system/node}"/node[0-9]* 2>/dev/null | wc -l)
  if [ "$VEN" = AuthenticAMD ]; then
    local sv
    if sv=$(hsmp_q 0x02 1 0); then
      smu="  SMU FW $(( (sv>>16)&255 )).$(( (sv>>8)&255 )).$(( sv&255 ))"
    elif [ -r "$SMUDRV/version" ]; then
      sv=$(sed 's/^SMU v//' "$SMUDRV/version" 2>/dev/null | tr -d '\n')
      [ -n "$sv" ] && smu="  SMU FW $sv (smu)"
    fi
  fi
  echo "== Platform =="
  printf "  Secure Boot %s  Lockdown %s%s  %s %s  NUMA %s node(s)%s\n" "$sb" "$ld" "$oc" "$smtlab" "$smt" "$numa" "$smu"
}
# board voltage rails (Super I/O sensors) - live data, stays on the monitor.
board_rails(){
  local h n lab v f out=""
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
# RAPL time-window field -> seconds. $1=Y (exp, 5 bits), $2=Z (mantissa, 2
# bits), $3=time unit exponent (0x606[19:16]); window = (1+Z/4)*2^Y / 2^unit.
rapl_win(){ awk "BEGIN{printf \"%.3f\", (1 + $2/4) * 2^$1 / 2^$3}"; }

# CPU identity + configured ratio ceilings, per socket. Intel decodes
# 0xCE (MSR_PLATFORM_INFO): base (max non-turbo), max-efficiency and min
# operating ratios plus the "programmable" flags that say what BIOS/OC may
# change. AMD lists the enabled P-state base clocks.
info_cpu(){
  echo "== CPU =="
  local s c mn md st uc cor thr cc v
  for s in $SOCKETS; do
    c=${REP[$s]}
    mn=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^model name/{print $2; exit}' /proc/cpuinfo)
    md=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^model[ \t]*$/{print $2; exit}' /proc/cpuinfo)
    st=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^stepping/{print $2; exit}' /proc/cpuinfo)
    uc=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^microcode/{print $2; exit}' /proc/cpuinfo)
    thr=0; cor=0
    for cc in $CPUS; do
      [ "$(cat "$CPUROOT/cpu$cc/topology/physical_package_id" 2>/dev/null)" = "$s" ] || continue
      thr=$((thr+1)); [ "$(siblings "$cc" | head -1)" = "$cc" ] && cor=$((cor+1))
    done
    printf "  S%s  %s  %sC/%sT  fam%s model %s stepping %s%s\n" \
      "$s" "${mn:-unknown}" "$cor" "$thr" "$FAM" "${md:--}" "${st:--}" "${uc:+  ucode $uc}"
    if [ "$VEN" = GenuineIntel ]; then
      if v=$("$READOC" -p "$c" -u 0xCE 2>/dev/null); then
        printf "      Base %sx (%d MHz)  Max-Eff %sx  Min %sx\n" \
          "$(bits "$v" 8 8)" "$(( $(bits "$v" 8 8) * 100 ))" "$(bits "$v" 40 8)" "$(bits "$v" 48 8)"
        printf "      Programmable: turbo-ratio %s  TDP-limit %s  TjMax-offset %s\n" \
          "$( [ "$(bits "$v" 28 1)" = 1 ] && echo yes || echo no)" \
          "$( [ "$(bits "$v" 29 1)" = 1 ] && echo yes || echo no)" \
          "$( [ "$(bits "$v" 30 1)" = 1 ] && echo yes || echo no)"
      fi
    else
      local ps reg pv line=""
      for ps in 0 1 2; do
        reg=$(printf '0x%X' $(( 0xC0010064 + ps )))
        pv=$("$READOC" -p "$c" -u "$reg" 2>/dev/null) || continue
        [ "$(bits "$pv" 63 1)" = 1 ] || continue
        if [ "$FAM" -ge 26 ]; then line="$line  P$ps $(( (pv & 0xFFF) * 5 )) MHz"
        else local f=$((pv & 0xFF)) d=$(( (pv>>8) & 0x3F )); [ "$d" -eq 0 ] && d=8; line="$line  P$ps $(( f*200/d )) MHz"; fi
      done
      [ -n "$line" ] && printf "     %s\n" "$line"
    fi
  done
  return 0
}

# Intel turbo ratio limits: 0x1AD holds up to 8 max-ratio bins, 0x1AE the
# active-core-count threshold each bin applies up to (Skylake-SP+ scheme).
# Ratios are package-uniform, so this shows socket 0. Falls back to a bin
# index when 0x1AE is unavailable/implausible.
info_turbo(){
  [ "$VEN" = GenuineIntel ] || return 0
  local c i r n rl rc out="" ncpu cnt=0 last=""
  c=${REP[$(printf '%s\n' $SOCKETS | head -1)]}
  rl=$("$READOC" -p "$c" -u 0x1AD 2>/dev/null) || return 0
  rc=$("$READOC" -p "$c" -u 0x1AE 2>/dev/null) || rc=""
  ncpu=$(printf '%s\n' $CPUS | wc -l)
  for i in 0 1 2 3 4 5 6 7; do
    r=$(bits "$rl" $((i*8)) 8); [ "$r" -gt 0 ] || continue
    cnt=$((cnt+1)); last="${r}x"
    n=""; [ -n "$rc" ] && n=$(bits "$rc" $((i*8)) 8)
    case "$n" in ''|0) out="$out  bin$i ${r}x" ;; *) [ "$n" -le "$ncpu" ] && out="$out  <=${n}C ${r}x" || out="$out  bin$i ${r}x" ;; esac
  done
  [ "$cnt" = 0 ] && return 0
  echo "== Turbo Ratio Limits (0x1AD/0x1AE) =="
  # a single populated bin has no per-core-count structure to show, so print
  # the ratio bare; multiple bins keep their <=NC (or binN fallback) labels.
  if [ "$cnt" = 1 ]; then printf "      %s\n" "$last"; else printf "    %s\n" "$out"; fi
  return 0
}

# Intel thermal config: TjMax and the TCC/PROCHOT activation offset (0x1A2).
info_thermal(){
  [ "$VEN" = GenuineIntel ] || return 0
  local s c v shown=""
  for s in $SOCKETS; do
    c=${REP[$s]}
    v=$("$READOC" -p "$c" -u 0x1A2 2>/dev/null) || continue
    [ -z "$shown" ] && { echo "== Thermal =="; shown=y; }
    printf "  S%s  TjMax %d°C  TCC/PROCHOT offset %d°C\n" "$s" "$(bits "$v" 16 8)" "$(bits "$v" 24 6)"
  done
  return 0
}

# Intel power: PL1/PL2 with enable, time window and lock (0x610), plus the
# package power envelope TDP/Min/Max/window (0x614 PKG_POWER_INFO).
intel_power(){
  local s c v606 v610 v614 pu tu shown=""
  echo "== Power Limits (RAPL) =="
  for s in $SOCKETS; do
    c=${REP[$s]}
    v606=$("$READOC" -p "$c" -u 0x606 2>/dev/null) || continue
    v610=$("$READOC" -p "$c" -u 0x610 2>/dev/null) || continue
    pu=$(bits "$v606" 0 4); tu=$(bits "$v606" 16 4)
    printf "  S%s  PL1 %s W (%s, %s s)  PL2 %s W (%s, %s s)%s\n" "$s" \
      "$(wt "$(bits "$v610" 0 15)/2^$pu")" \
      "$( [ "$(bits "$v610" 15 1)" = 1 ] && echo Enabled || echo Disabled)" \
      "$(rapl_win "$(bits "$v610" 17 5)" "$(bits "$v610" 22 2)" "$tu")" \
      "$(wt "$(bits "$v610" 32 15)/2^$pu")" \
      "$( [ "$(bits "$v610" 47 1)" = 1 ] && echo Enabled || echo Disabled)" \
      "$(rapl_win "$(bits "$v610" 49 5)" "$(bits "$v610" 54 2)" "$tu")" \
      "$( [ "$(bits "$v610" 63 1)" = 1 ] && echo "  [Locked]" || : )"
    if v614=$("$READOC" -p "$c" -u 0x614 2>/dev/null) && [ "$(bits "$v614" 0 15)" -gt 0 ]; then
      local pmin pmax line
      pmin=$(bits "$v614" 16 15); pmax=$(bits "$v614" 32 15)
      line="        Package: TDP $(wt "$(bits "$v614" 0 15)/2^$pu") W"
      [ "$pmin" -gt 0 ] && line="$line  Min $(wt "$pmin/2^$pu") W"
      [ "$pmax" -gt 0 ] && line="$line  Max $(wt "$pmax/2^$pu") W  Max window $(rapl_win "$(bits "$v614" 48 5)" "$(bits "$v614" 53 2)" "$tu") s"
      printf '%s\n' "$line"
    fi
    shown=y
  done
  [ -n "$shown" ] || echo "  N/A (need msr module: sudo modprobe msr)"
  return 0
}

# AMD power: PPT limit (and its max) from HSMP, where available.
amd_power(){
  local s pl plm shown=""
  for s in $SOCKETS; do
    pl=$(hsmp_q 0x06 1 "$s") || continue
    plm=$(hsmp_q 0x07 1 "$s") || plm=""
    [ -z "$shown" ] && { echo "== Power Limits (HSMP) =="; shown=y; }
    printf "  S%s  PPT %s W%s\n" "$s" "$(wt "$pl/1000")" "${plm:+  (Max $(wt "$plm/1000") W)}"
  done
  [ -n "$shown" ] || echo "== Power Limits: N/A (need /dev/hsmp) =="
  return 0
}

# Per-DIMM memory configuration from SMBIOS (dmidecode -t 17): each populated
# slot's configured speed, voltage and size.
dram_detail(){
  local out slots="" temps="" sl rest disp t
  while IFS='|' read -r sl rest; do
    [ -n "$sl" ] || continue
    t=$(bmc_read_sensor "$sl" "${rest%%|*}" "${rest##*|}")   # full name for sdr get
    disp=${sl%_Temp}; disp=${disp%_TEMP}; disp=${disp% Temp}  # strip only for display
    slots="$slots $disp"
    temps="$temps ${t:--}"
  done <<EOFSL
$(bmc_dimm_slots)
EOFSL
  slots=${slots# }; temps=${temps# }
  local vq; vq=$(bmc_vddq)   # measured DRAM VDDQ (one platform-wide rail), trails each DIMM's frequency
  out=$( (${DMI:-dmidecode} -t 17 2>/dev/null || :) | awk -v slots="$slots" -v temps="$temps" -v vq="$vq" '
    function val(s){ sub(/.*:[ \t]*/, "", s); return s }
    # slot designator = trailing letter+digits (CPU0_DIMM_A1 -> A1, DIMMA1 -> A1)
    function slotkey(x,  t){ t=toupper(x); if(match(t,/[A-Z][0-9]+$/)) return substr(t,RSTART); return "" }
    function stash(){ if(inblk && sz!="" && sz !~ /No Module/){ n++; L[n]=loc; SP[n]=sp; JS[n]=js; SZ[n]=sz; if(n==1) first=loc; else if(loc!=first) mixed=1 } }
    BEGIN{ nslot=split(slots, slot, " "); split(temps, tt, " ")
           for(j=1;j<=nslot;j++){ k=slotkey(slot[j]); if(k!="") bt[k]=tt[j] } }
    /^Memory Device/{loc="";sz="";sp="";js="";inblk=1;next}
    inblk && /Bank Locator:/{next}
    inblk && /Locator:/{loc=val($0)}
    inblk && /Size:[ \t]*[0-9]/{sz=val($0)}
    inblk && /Configured Memory Speed:[ \t]*[0-9]/{sp=val($0)}
    inblk && /^[ \t]*Speed:[ \t]*[0-9]/{js=val($0)}
    /^$/{ stash(); inblk=0 }
    END{ stash()
      # Branch B: SMBIOS locators carry no information (all identical) and the
      # count matches the BMC-populated slots -> substitute real names, and
      # append the temp (whole DIMM identity comes from the BMC).
      usebmc = (n>0 && !mixed && n==nslot && nslot>0)
      # first pass: resolve display name + per-DIMM temp; note which optional columns carry data
      hastemp=0
      for(i=1;i<=n;i++){
        if(usebmc){
          NAME[i]=slot[i]
          T[i]=(tt[i] ~ /^[0-9]+$/) ? tt[i] : ""
        } else {
          # Branch A: locators are meaningful -> keep the SMBIOS name, and
          # append the BMC temp whose slot designator matches this locator.
          seen[L[i]]++; nm=L[i]; if(seen[L[i]]>1) nm=L[i] " #" seen[L[i]]
          NAME[i]=nm
          k=slotkey(L[i]); T[i]=(k!="" && (k in bt) && bt[k] ~ /^[0-9]+$/) ? bt[k] : ""
        }
        if(T[i]!="") hastemp=1
      }
      hasvddq=(vq!="")
      # column table (parallels the per-core panel): a header row, then one aligned
      # row per DIMM. Speed = actual configured rate, JEDEC = SMBIOS nominal rate;
      # the VDDQ and Temp columns appear only when the BMC populates them.
      if(n>0){
        h=sprintf("  %-14s %-11s %-11s", "DIMM", "Speed", "JEDEC")
        if(hasvddq) h=h sprintf(" %-8s", "VDDQ")
        h=h sprintf(" %-8s", "Size")
        if(hastemp) h=h " Temp"
        sub(/ +$/,"",h); print h
        for(i=1;i<=n;i++){
          r=sprintf("  %-14s %-11s %-11s", NAME[i], (SP[i]!=""?SP[i]:"-"), (JS[i]!=""?JS[i]:"-"))
          if(hasvddq) r=r sprintf(" %-8s", vq " V")
          r=r sprintf(" %-8s", SZ[i])
          if(hastemp) r=r sprintf(" %s", (T[i]!=""?T[i] "°C":""))
          sub(/ +$/,"",r); print r
        }
      }
    }')
  [ -n "$out" ] && { echo "== Memory (per DIMM) =="; printf '%s\n' "$out"; }
  return 0
}

# Cache hierarchy from sysfs (cpu0): per-core L1/L2 sizes and shared L3.
cache_topo(){
  local d lvl typ sz t out=""
  [ -d "$CPUROOT/cpu0/cache" ] || return 0
  for d in "$CPUROOT"/cpu0/cache/index*; do
    [ -e "$d/level" ] || continue
    lvl=$(cat "$d/level"); typ=$(cat "$d/type" 2>/dev/null); sz=$(cat "$d/size" 2>/dev/null)
    case "$typ" in Data) t="L${lvl}d" ;; Instruction) t="L${lvl}i" ;; *) t="L${lvl}" ;; esac
    out="$out  $t $sz"
  done
  [ -n "$out" ] && { echo "== Cache (per core; L3 shared) =="; printf "   %s\n" "$out"; }
  return 0
}

# `sckoc info`: the static platform report - everything that does not change
# at runtime, kept out of the live-refreshing monitor panel. Security state,
# CPU identity and ratio ceilings, turbo bins, thermal config, power limits
# and envelope, per-DIMM memory and cache topology. MSR-backed blocks degrade
# on their own without the msr module; the sysfs/SMBIOS blocks always show.
info_cmd(){
  platform_line
  info_cpu
  info_turbo
  info_thermal
  if [ "$VEN" = GenuineIntel ]; then intel_power; else amd_power; fi
  dram_detail
  cache_topo
}
wt4(){ awk "BEGIN{printf \"%.4f\", $1}"; }

UNC="${UNCSYS:-/sys/devices/system/cpu/intel_uncore_frequency}"
intel_uncore(){
  local d pk mesh="" iod="" tag=""
  [ -d "$UNC" ] || modprobe intel-uncore-frequency-tpmi 2>/dev/null || modprobe intel-uncore-frequency 2>/dev/null || true
  for d in "$UNC"/uncore* "$UNC"/package_0"$1"_die_*; do
    [ -e "$d/current_freq_khz" ] || continue
    pk=$(cat "$d/package_id" 2>/dev/null || echo "$1")
    [ "$pk" = "$1" ] || continue
    if [ -z "$mesh" ]; then mesh=$(( $(cat "$d/current_freq_khz") / 1000 ))
    else iod="$iod $(( $(cat "$d/current_freq_khz") / 1000 ))"; fi
  done
  if [ -z "$mesh" ]; then
    # pre-TPMI Xeon: uncore ratio MSRs (0x621 current, 0x620 min/max)
    local v621 cur
    if v621=$("$READOC" -p "$2" -u 0x621 2>/dev/null) && cur=$(( (v621 & 127) * 100 )) && [ "$cur" -gt 0 ]; then
      mesh=$cur
    fi
  fi
  if [ -z "$mesh" ]; then
    # TPMI-era Xeon (GNR+) on pre-6.5 kernels: read the uncore TPMI MMIO
    # region directly via the read-only tpmi-uncore helper. OOBMSM device
    # order is assumed to match package order.
    local tp tl tc tn tx
    tp="${TPMIU:-$( [ -x "$LIBEXEC/tpmi-uncore" ] && echo "$LIBEXEC/tpmi-uncore" || command -v tpmi-uncore || echo /usr/local/bin/tpmi-uncore )}"
    if [ -x "$tp" ]; then
      tl=$("$tp" 2>/dev/null | awk -v s="$1" '$1==s{print $2,$3,$4}')
      while read -r tc tn tx; do
        [ -n "$tc" ] || continue
        if [ -z "$mesh" ]; then mesh=$tc; else iod="$iod $tc"; fi
      done <<< "$tl"
      [ -n "$mesh" ] && tag=" (tpmi)"
    fi
  fi
  if [ -n "$mesh" ]; then
    local it="" m0="Mesh"; set -- $iod
    case $# in
      0) ;;
      2) it="  IOD-S $1 MHz  IOD-N $2 MHz" ;;
      3) m0="Mesh0"; it="  Mesh1 $1 MHz  IOD-S $2 MHz  IOD-N $3 MHz" ;;
      *) it="  IOD $(echo $iod | tr " " "/") MHz" ;;
    esac
    printf "%s %s MHz%s%s" "$m0" "$mesh" "$it" "$tag"
  else
    printf "Mesh N/A (need intel-uncore-frequency driver, or tpmi-uncore helper on pre-6.5 kernels)"
  fi
}

# `sckoc uncore`: per-domain uncore/mesh frequency limits, including the BIOS
# boot values. Min/Max are runtime-programmable (sysfs, wrmsr, intel-speed-
# select tooling); sysfs initial_*_freq_khz preserves what firmware wrote at
# boot, so a mismatch means the limits were changed after boot. The MSR and
# TPMI fallback paths carry no boot values (a single register, overwritten in
# place) - those columns show "-" there.
uncore_cmd(){
  local JS=""; [ "${1:-}" = "--json" ] && JS=1
  if [ "$VEN" != GenuineIntel ]; then
    [ -n "$JS" ] && { printf '{"schema":"sckoc-uncore-v1","source":null,"domains":[]}\n'; exit 1; }
    echo "uncore: Intel-only (AMD fabric clock appears in the monitor as FCLK)"; exit 1
  fi
  [ -d "$UNC" ] || modprobe intel-uncore-frequency-tpmi 2>/dev/null || modprobe intel-uncore-frequency 2>/dev/null || true
  k2m(){ local v; if v=$(cat "$1" 2>/dev/null) && [ -n "$v" ]; then echo $((v/1000)); else echo "-"; fi; }
  jn(){ case "$1" in ''|-|'?') printf null ;; *) printf '%s' "$1" ;; esac; }
  local shown="" chg="" src="" JOUT="" d n pk cur mn mx imn imx star v621 v620 s c out tp
  if [ -d "$UNC" ]; then
    for d in "$UNC"/uncore* "$UNC"/package_*_die_*; do
      [ -e "$d/min_freq_khz" ] || continue
      if [ -z "$shown" ] && [ -z "$JS" ]; then echo "== Uncore/mesh frequency limits, MHz (sysfs) =="
        printf "  %-19s %-4s %-8s %-6s %-6s %-9s %-9s\n" Domain Pkg Current Min Max BIOS-Min BIOS-Max; fi
      n=${d##*/}
      if ! pk=$(cat "$d/package_id" 2>/dev/null); then
        case $n in package_*) pk=${n#package_}; pk=$((10#${pk%%_*})) ;; *) pk="?" ;; esac
      fi
      cur=$(k2m "$d/current_freq_khz"); mn=$(k2m "$d/min_freq_khz"); mx=$(k2m "$d/max_freq_khz")
      imn=$(k2m "$d/initial_min_freq_khz"); imx=$(k2m "$d/initial_max_freq_khz")
      star=""
      if [ "$imn" != "-" ] && { [ "$mn" != "$imn" ] || [ "$mx" != "$imx" ]; }; then star=" *"; chg=y; fi
      if [ -n "$JS" ]; then
        JOUT="$JOUT${JOUT:+,}{\"name\":\"$n\",\"pkg\":$(jn "$pk"),\"current_mhz\":$(jn "$cur"),\"min_mhz\":$(jn "$mn"),\"max_mhz\":$(jn "$mx"),\"bios_min_mhz\":$(jn "$imn"),\"bios_max_mhz\":$(jn "$imx"),\"changed\":$( [ -n "$star" ] && printf true || printf false )}"
      else
        printf "  %-19s %-4s %-8s %-6s %-6s %-9s %-9s%s\n" "$n" "$pk" "$cur" "$mn" "$mx" "$imn" "$imx" "$star"
      fi
      shown=y; src=sysfs
    done
    [ -z "$JS" ] && [ -n "$chg" ] && echo "  * Min/Max differ from the BIOS boot values (changed at runtime)" || true
  fi
  if [ -z "$shown" ]; then
    # pre-TPMI Xeon fallback: MSR 0x621 current, 0x620 min/max limits
    for s in $SOCKETS; do
      c=${REP[$s]}
      v621=$("$READOC" -p "$c" -u 0x621 2>/dev/null) || continue
      cur=$(( (v621 & 127) * 100 )); [ "$cur" -gt 0 ] || continue
      if [ -z "$shown" ] && [ -z "$JS" ]; then echo "== Uncore/mesh frequency limits, MHz (MSR 0x620/0x621; no boot values via MSR) =="
        printf "  %-7s %-8s %-6s %-6s %-9s %-9s\n" Socket Current Min Max BIOS-Min BIOS-Max; fi
      v620=$(rf "$c" 0x620)
      mn=$(( $(bits "$v620" 8 7) * 100 )); mx=$(( $(bits "$v620" 0 7) * 100 ))
      if [ -n "$JS" ]; then
        JOUT="$JOUT${JOUT:+,}{\"name\":\"S$s\",\"pkg\":$s,\"current_mhz\":$cur,\"min_mhz\":$mn,\"max_mhz\":$mx,\"bios_min_mhz\":null,\"bios_max_mhz\":null,\"changed\":null}"
      else
        printf "  S%-6s %-8s %-6s %-6s %-9s %-9s\n" "$s" "$cur" "$mn" "$mx" - -
      fi
      shown=y; src=msr
    done
  fi
  if [ -z "$shown" ]; then
    # TPMI-era Xeon on pre-6.5 kernels: read-only tpmi-uncore helper
    tp="${TPMIU:-$( [ -x "$LIBEXEC/tpmi-uncore" ] && echo "$LIBEXEC/tpmi-uncore" || command -v tpmi-uncore || echo /usr/local/bin/tpmi-uncore )}"
    if [ -x "$tp" ] && out=$("$tp" 2>/dev/null) && [ -n "$out" ]; then
      if [ -z "$JS" ]; then echo "== Uncore/mesh frequency limits, MHz (TPMI MMIO; no boot values via TPMI) =="
        printf "  %-7s %-8s %-6s %-6s %-9s %-9s\n" Pkg Current Min Max BIOS-Min BIOS-Max; fi
      while read -r pk cur mn mx; do
        [ -n "$pk" ] || continue
        if [ -n "$JS" ]; then
          JOUT="$JOUT${JOUT:+,}{\"name\":\"S$pk\",\"pkg\":$pk,\"current_mhz\":$cur,\"min_mhz\":$mn,\"max_mhz\":$mx,\"bios_min_mhz\":null,\"bios_max_mhz\":null,\"changed\":null}"
        else
          printf "  S%-6s %-8s %-6s %-6s %-9s %-9s\n" "$pk" "$cur" "$mn" "$mx" - -
        fi
        shown=y; src=tpmi
      done <<< "$out"
    fi
  fi
  if [ -n "$JS" ]; then
    printf '{"schema":"sckoc-uncore-v1","source":%s,"domains":[%s]}\n' "$( [ -n "$src" ] && printf '"%s"' "$src" || printf null )" "$JOUT"
    [ -n "$shown" ] || exit 1
    return
  fi
  [ -n "$shown" ] || { echo "uncore: no data (need intel-uncore-frequency driver, readable MSR 0x620/0x621, or tpmi-uncore helper)"; exit 1; }
}

# CPU identification block shown above the per-core overview: marketing name,
# core/thread topology per socket, base clock (when the caller filled BASEM),
# family/model/stepping and microcode rev.
cpu_model_block(){
  local s c mn md st uc thr cor cc bl
  echo "== CPU =="
  for s in $SOCKETS; do
    c=${REP[$s]}
    mn=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^model name/{print $2; exit}' /proc/cpuinfo)
    md=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^model[ \t]*$/{print $2; exit}' /proc/cpuinfo)
    st=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^stepping/{print $2; exit}' /proc/cpuinfo)
    uc=$(awk -F':[ \t]*' -v p="$c" '$1 ~ /^processor/{cur=$2+0} cur==p && $1 ~ /^microcode/{print $2; exit}' /proc/cpuinfo)
    thr=0; cor=0
    for cc in $CPUS; do
      [ "$(cat "$CPUROOT/cpu$cc/topology/physical_package_id" 2>/dev/null)" = "$s" ] || continue
      thr=$((thr+1))
      [ "$(siblings "$cc" | head -1)" = "$cc" ] && cor=$((cor+1))
    done
    bl=""; [ -n "${BASEM[$s]:-}" ] && bl="  Base ${BASEM[$s]} MHz"
    printf "  S%s  %s  %sC/%sT%s  fam%s model %s stepping %s%s\n" \
      "$s" "${mn:-unknown}" "$cor" "$thr" "$bl" "$FAM" "${md:--}" "${st:--}" "${uc:+  ucode $uc}"
  done
}
intel_sock(){
  local c=$2 v198 v19c eu e1 e2 d1 d2 de dd tj thr
  tj=$(bits "$(rf "$c" 0x1A2)" 16 8)
  eu=$(bits "$(rf "$c" 0x606)" 8 5)
  # counters come from the shared sampling window (see mon_sample)
  local ts1 ts2 dts pcs=""
  ts1=$(sv "$c" 0x10 T0); ts2=$(sv "$c" 0x10 T1)
  dts=$(( ts2 - ts1 )); [ "$dts" -le 0 ] && dts=1
  sk "$c" 0x60d T0 && sk "$c" 0x60d T1 && pcs="$pcs  PC2 $(( ( $(sv "$c" 0x60d T1) - $(sv "$c" 0x60d T0) ) * 100 / dts ))%" || true
  sk "$c" 0x3f9 T0 && sk "$c" 0x3f9 T1 && pcs="$pcs  PC6 $(( ( $(sv "$c" 0x3f9 T1) - $(sv "$c" 0x3f9 T0) ) * 100 / dts ))%" || true
  e1=$(( $(sv "$c" 0x611 T0) & 4294967295 )); e2=$(( $(sv "$c" 0x611 T1) & 4294967295 ))
  d1=$(( $(sv "$c" 0x619 T0) & 4294967295 )); d2=$(( $(sv "$c" 0x619 T1) & 4294967295 ))
  de=$(( e2>=e1 ? e2-e1 : e2-e1+4294967296 )); dd=$(( d2>=d1 ? d2-d1 : d2-d1+4294967296 ))
  v198=$(sv "$c" 0x198 T1); v19c=$(sv "$c" 0x19c T1)
  local mx=0 t cc
  for cc in $CPUS; do
    [ "$(cat "$CPUROOT/cpu$cc/topology/physical_package_id")" = "$1" ] || continue
    t=$(( tj - $(bits "$(sv "$cc" 0x19c T1)" 16 7) )); [ "$t" -gt "$mx" ] && mx=$t || true
  done
  local un; un=$(intel_uncore "$1" "$c")
  thr=""; [ "$(bits "$v19c" 0 1)" = 1 ] && thr="  [THROTTLING!]"; [ -z "$thr" ] && [ "$(bits "$v19c" 1 1)" = 1 ] && thr="  [Throttle-Log]"
  printf "  S%s  VID %s V  Temp Max %d°C (TjMax %d°C)%s\n" "$1" "$(wt4 "$(bits "$v198" 32 16)/8192")" "$mx" "$tj" "$thr"
  printf "      Core %d00 MHz  %s\n" "$(bits "$v198" 8 8)" "$un"
  local mmx; mmx=$(bmc_dimm_max); [ -n "$mmx" ] && mmx="  Mem Max $mmx"
  printf "      DRAM %s%s\n" "$DRAMSPD" "$mmx"
  printf "      Pkg %s W  DRAM %s W%s\n" "$(wt "$de/2^$eu/$INT")" "$(wt "$dd/2^$eu/$INT")" "$pcs"
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
# BMC sensors over the IPMI side-band (ipmitool): need no kernel driver, so
# they work where k10temp does not know the CPU yet (e.g. new AMD parts on
# old kernels). Slow-KCS aware: the one-off SDR probe (per boot, cached in
# /run) gets BMCPROBET seconds and a timeout is retried next tick - only a
# truly absent BMC is negative-cached. Cache lines are name|id|mode: at
# probe time each sensor gets one raw Get Sensor Reading (a single IPMI
# message; "sdr get" would rescan the whole SDR every time) validated
# against the SDR value - matching sensors refresh via raw, others fall
# back to sdr get. Soft dependency on ipmitool.
bmc_prep(){
  BMCIPT="${IPMITOOL:-$(command -v ipmitool || :)}"
  [ -n "$BMCIPT" ] || return 1
  [ -e /dev/ipmi0 ] || modprobe ipmi_devintf 2>/dev/null || true
  [ -e /dev/ipmi0 ] || modprobe ipmi_si 2>/dev/null || true
}
bmc_read_sensor(){  # $1=name $2=id $3=mode -> prints integer reading or nothing
  local raw t
  [ -n "$BMCIPT" ] || bmc_prep || return 0
  if [ "$3" = raw ]; then
    raw=$(timeout "${BMCREADT:-3}" "$BMCIPT" raw 0x04 0x2d "0x$2" 2>/dev/null) || return 0
    set -- $raw
    case "${1:-}" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
    t=$(( 16#$1 ))
  else
    t=$(timeout "${BMCPROBET:-20}" "$BMCIPT" sdr get "$1" 2>/dev/null \
        | awk -F': *' '/Sensor Reading/{print $2+0; exit}')
  fi
  case "$t" in ''|0|*[!0-9]*) return 0 ;; esac
  [ "$t" -lt 150 ] || return 0
  printf '%s' "$t"
}
bmc_probe(){  # scan the SDR once, write "name|id|mode" lines: $1 -> CPU cache, $2 -> DIMM cache
  local cc=$1 dc=$2 tbl rc c1 c2 d1 d2 c5 n i v m ck cpu="" dimm=""
  tbl=$(timeout "${BMCPROBET:-20}" "$BMCIPT" sdr type Temperature 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$tbl" ]; then
    # 124 = killed by timeout (slow BMC): retry next tick, don't negative-cache
    [ "$rc" -eq 124 ] && return 1
    echo none > "$cc" 2>/dev/null || true; echo none > "$dc" 2>/dev/null || true
    return 1
  fi
  while IFS='|' read -r c1 c2 d1 d2 c5; do
    n=$(echo $c1)
    case "$c5" in *degrees*) ;; *) continue ;; esac
    case "$(printf '%s' "$n" | tr 'A-Z' 'a-z')" in
      *vr*|*pch*|*pci*) continue ;;
      *dimm*) v=dimm ;;
      *cpu*|*processor*) v=cpu ;;
      *) continue ;;
    esac
    i=$(echo $c2); i=${i%h}
    case "$i" in ''|*[!0-9a-fA-F]*) continue ;; esac
    m=sdr
    ck=$(timeout "${BMCREADT:-3}" "$BMCIPT" raw 0x04 0x2d "0x$i" 2>/dev/null) || ck=""
    set -- $ck
    case "${1:-}" in ''|*[!0-9a-fA-F]*) ;; *)
      # accept raw if it lands within 5C of the SDR reading (a sensor drifts
      # a degree or two between the SDR scan and this probe - an exact-match
      # rule would wrongly demote it to the slower per-tick "sdr get")
      d=$(( 16#$1 - $(echo ${c5%%degrees*}) )); [ "$d" -ge -5 ] && [ "$d" -le 5 ] && m=raw ;;
    esac
    if [ "$v" = dimm ]; then dimm="$dimm$n|$i|$m
"; else cpu="$cpu$n|$i|$m
"; fi
  done <<EOFTBL
$tbl
EOFTBL
  { [ -n "$cpu" ] && printf '%s' "$cpu" || echo none; } > "$cc" 2>/dev/null || true
  { [ -n "$dimm" ] && printf '%s' "$dimm" | sort || echo none; } > "$dc" 2>/dev/null || true
  return 0
}
bmc_temp(){  # $1 = socket index; prints e.g. "31°C" or returns 1
  local so=$1 cache="${BMCCACHE:-/run/sckoc-bmc}" dcache="${BMCDIMMS:-/run/sckoc-bmc-dimm}"
  bmc_prep || return 1
  local line t
  if [ ! -s "$cache" ] || ! grep -q '|' "$cache" 2>/dev/null && [ "$(cat "$cache" 2>/dev/null)" != none ]; then
    bmc_probe "$cache" "$dcache" || return 1
  fi
  line=$(sed -n "$(( so + 1 ))p" "$cache" 2>/dev/null)
  [ -n "$line" ] && [ "$line" != none ] || return 1
  t=$(bmc_read_sensor "${line%%|*}" "$(printf '%s' "$line" | cut -d'|' -f2)" "${line##*|}")
  [ -n "$t" ] || return 1
  printf "%d°C" "$t"
}
bmc_dimm_slots(){  # prints "name|id|mode" lines for populated DIMM slots, possibly nothing
  local cache="${BMCCACHE:-/run/sckoc-bmc}" dcache="${BMCDIMMS:-/run/sckoc-bmc-dimm}"
  bmc_prep || return 0
  if [ ! -s "$dcache" ] || ! grep -q '|' "$dcache" 2>/dev/null && [ "$(cat "$dcache" 2>/dev/null)" != none ]; then
    bmc_probe "$cache" "$dcache" || return 0
  fi
  [ "$(cat "$dcache" 2>/dev/null)" = none ] && return 0
  cat "$dcache" 2>/dev/null
  return 0
}
# hottest populated DIMM from the BMC, for the mon summary (parallels the CPU
# Temp Max). Reads each populated slot once; prints "NN°C" or nothing.
bmc_dimm_max(){
  local sl rest t max=""
  while IFS='|' read -r sl rest; do
    [ -n "$sl" ] || continue
    t=$(bmc_read_sensor "$sl" "${rest%%|*}" "${rest##*|}")
    case "$t" in ''|*[!0-9]*) continue ;; esac
    { [ -z "$max" ] || [ "$t" -gt "$max" ]; } && max=$t
  done <<EOFSL
$(bmc_dimm_slots)
EOFSL
  [ -n "$max" ] && printf "%d°C" "$max"
}
# Measured DRAM VDDQ rail from the BMC. Unlike the SMBIOS "Configured
# Voltage" (a JEDEC nominal, e.g. 1.1 V, that stays put even on an
# overclocked/overvolted rail), this is the real reading. Scans the voltage
# SDRs once for a VDDQ sensor and reads it - preferring the value already
# carried in the SDR row, falling back to an exact "sdr get" by name. Prints
# e.g. "1.39" (volts) or nothing. One-shot, cached in /run for the run so the
# static 'sckoc info' does not rescan. Soft dependency on ipmitool.
bmc_vddq(){
  local cache="${BMCVDDQ:-/run/sckoc-bmc-vddq}" v tbl row name
  bmc_prep || return 0
  if [ -s "$cache" ]; then
    v=$(cat "$cache" 2>/dev/null); [ "$v" = none ] && return 0
    printf '%s' "$v"; return 0
  fi
  tbl=$(timeout "${BMCPROBET:-20}" "$BMCIPT" sdr type Voltage 2>/dev/null)
  row=$(printf '%s\n' "$tbl" | grep -i vddq | head -1)
  if [ -n "$row" ]; then
    # reading carried inline in the SDR row: "... | 1.39 Volts | ok"
    v=$(printf '%s\n' "$row" | grep -oiE '[0-9]+(\.[0-9]+)? +Volts' | head -1 \
        | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$v" ]; then
      # no inline reading -> exact fetch by sensor name (SDR column 1)
      name=$(printf '%s\n' "$row" | cut -d'|' -f1 | sed 's/[[:space:]]*$//')
      v=$(timeout "${BMCPROBET:-20}" "$BMCIPT" sdr get "$name" 2>/dev/null \
          | awk -F': *' '/Sensor Reading/{ n=$2+0; if(n>0) printf "%.2f", n; exit }')
    fi
  fi
  case "$v" in ''|0|0.00|*[!0-9.]*) echo none > "$cache" 2>/dev/null || true; return 0 ;; esac
  echo "$v" > "$cache" 2>/dev/null || true
  printf '%s' "$v"
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
  # no k10temp sensor for this socket: PM-table Tctl (socket 0 only; table is socket-local)
  if [ "$1" = 0 ] && smu_ok; then
    t=$(smu_fi 0x2C)
    case "$t" in ''|*[!0-9]*) ;; *) [ "$t" -gt 0 ] && [ "$t" -lt 150 ] && { printf "%d°C (smu)" "$t"; return; } ;; esac
  fi
  local bt; if bt=$(bmc_temp "$1"); then printf '%s' "$bt"; return; fi
  printf "N/A (need k10temp)"; }
hsmp_q(){
  local h="${HSMP:-$( [ -x "$LIBEXEC/hsmp-msg" ] && echo "$LIBEXEC/hsmp-msg" || command -v hsmp-msg || echo /usr/local/bin/hsmp-msg )}"
  [ -e /dev/hsmp ] || modprobe amd_hsmp 2>/dev/null || modprobe hsmp_acpi 2>/dev/null || true
  [ -e /dev/hsmp ] && [ -x "$h" ] && "$h" "$@" 2>/dev/null
}
amd_fclk(){
  local out f m
  if out=$(hsmp_q 0x0F 2 "$1"); then printf "FCLK %s MHz / MCLK %s MHz" ${out}
  elif [ "$1" = 0 ] && smu_ok; then
    f=$(smu_fi 0x11C); m=$(smu_fi 0x13C)
    printf "FCLK %s MHz / MCLK %s MHz (smu)" "$f" "$m"
  elif [ "$FAM" -ge 25 ] && ! grep -Eqi 'epyc|threadripper' /proc/cpuinfo 2>/dev/null; then
    printf "FCLK N/A (consumer Ryzen has no HSMP; ryzen_smu provides it, see README)"
  else printf "FCLK N/A (need amd_hsmp + BIOS HSMP)"; fi
}
amd_sock(){
  local c=$2 eu e1 e2 de
  eu=$(bits "$(rf "$c" 0xC0010299)" 8 5)
  e1=$(( $(sv "$c" 0xc001029b T0) & 4294967295 )); e2=$(( $(sv "$c" 0xc001029b T1) & 4294967295 ))
  de=$(( e2>=e1 ? e2-e1 : e2-e1+4294967296 ))
  local ph="" ppt=""
  [ "$(hsmp_q 0x0B 1 "$1")" = 1 ] && ph="  [PROCHOT!]" || true
  local pl plm
  if pl=$(hsmp_q 0x06 1 "$1"); then
    plm=$(hsmp_q 0x07 1 "$1") || plm=""
    ppt="  PPT $(wt "$pl/1000") W${plm:+ (Max $(wt "$plm/1000") W)}"
  elif [ "$1" = 0 ] && smu_ok; then
    pl=$(smu_f 0x0C); [ -n "$pl" ] && ppt="  PPT $pl W (smu)"
  fi
  # prefer real per-rail vcore from board sensor map; then SMU SVI3 telemetry; then P-state nominal
  local vctxt r0 r1
  r0=$(board_vcore VDDCR_CPU0) || r0=""
  r1=$(board_vcore VDDCR_CPU1) || r1=""
  if [ -n "$r0" ] || [ -n "$r1" ]; then
    vctxt="Vcore ${r0:+CPU0 $r0 V}${r0:+  }${r1:+CPU1 $r1 V}"
  elif [ "$1" = 0 ] && smu_ok; then
    local sv3; sv3=$(smu_f3 0x48)
    case "$sv3" in
      0.???|1.???) vctxt="Vcore $sv3 V (smu SVI3)" ;;
      *) vctxt="Vcore N/A" ;;
    esac
  else
    local vc; vc=$(amd_vid "$2")
    if [ -z "$vc" ]; then vctxt="VID N/A"
    elif [ "$FAM" -ge 26 ]; then vctxt="VID ~$vc V (P-state nominal)"
    else vctxt="VID ~$vc V (P-state)"; fi
  fi
  printf "  S%s  Temp Max %s  %s%s\n" "$1" "$(amd_temp "$1")" "$vctxt" "$ph"
  local fm="" cl="" bw="" c0=""
  if fm=$(hsmp_q 0x1C 1 "$1"); then fm="  Fmax $(( (fm>>16)&65535 )) MHz / Fmin $(( fm&65535 )) MHz"; else fm=""; fi
  if cl=$(hsmp_q 0x10 1 "$1"); then cl="  CCLK Limit $cl MHz"; else cl=""; fi
  if bw=$(hsmp_q 0x14 1 "$1"); then bw="  BW $(( (bw>>8)&4095 ))/$(( (bw>>20)&4095 )) GB/s ($(( bw&255 ))%)"; else bw=""; fi
  if c0=$(hsmp_q 0x11 1 "$1"); then c0="  C0 ${c0}%"; else c0=""; fi
  printf "      %s%s%s\n" "$(amd_fclk "$1")" "$fm" "$cl"
  local mmx; mmx=$(bmc_dimm_max); [ -n "$mmx" ] && mmx="  Mem Max $mmx"
  printf "      DRAM %s%s%s\n" "$DRAMSPD" "$bw" "$mmx"
  # a counter that does not advance between the two samples (dead counter,
  # or an unreadable MSR snapped as 0) would render a misleading "Pkg 0.0 W":
  # no running package sits at zero. Prefer HSMP ReadSocketPower, else N/A.
  local pkgtxt sp
  if [ "$de" -gt 0 ]; then pkgtxt="Pkg $(wt "$de/2^$eu/$INT") W"
  elif sp=$(hsmp_q 0x04 1 "$1"); then pkgtxt="Pkg $(wt "$sp/1000") W (hsmp)"
  else pkgtxt="Pkg N/A (energy counter not advancing; need BIOS HSMP)"; fi
  printf "      %s%s%s\n" "$pkgtxt" "$ppt" "$c0"
}

percore(){
  local -A TJ
  local c base eu=0 HOTANY=""
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
    # PM-table fallback: build CCD temps from per-core sensors (max per CCD group)
    if [ ${#CCDT[@]} -eq 0 ] && smu_ok; then
      local nc=0 nccd gi gt grel gsz
      for c in $CPUS; do [ "$(siblings "$c" | head -1)" = "$c" ] && nc=$((nc+1)); done
      nccd=$(printf '%s\n' "${CCD[@]}" | sort -un | grep -c -v '^-1$' || echo 0)
      if [ "$nccd" -gt 0 ] && [ "$nc" -ge "$nccd" ]; then
        gsz=$(( nc / nccd )); [ "$gsz" -lt 1 ] && gsz=1
        gi=0
        while [ "$gi" -lt "$nc" ]; do
          gt=$(smu_fi $(( 0x534 + gi * 4 )))
          case "$gt" in ''|*[!0-9]*) gi=$((gi+1)); continue ;; esac
          if [ "$gt" -gt 0 ] && [ "$gt" -lt 150 ]; then
            grel=$(( gi / gsz ))
            if [ -z "${CCDT["0:$grel"]}" ] || [ "$gt" -gt "${CCDT["0:$grel"]}" ]; then CCDT["0:$grel"]=$gt; fi
          fi
          gi=$((gi+1))
        done
      fi
      if [ -z "${TCTL[0]}" ]; then
        gt=$(smu_fi 0x2C)
        case "$gt" in ''|*[!0-9]*) ;; *) [ "$gt" -gt 0 ] && [ "$gt" -lt 150 ] && TCTL[0]=$gt ;; esac
      fi
    fi
  fi
  for c in $CPUS; do
    local dm da bm=-1 sib extra="" hot=""
    sib=$(siblings "$c")
    [ "$(echo "$sib" | head -1)" = "$c" ] || continue
    local c0m=0 dt c0
    for t in $sib; do
      dm=$(( $(sv "$t" 0xe7 T1) - $(sv "$t" 0xe7 T0) ))
      da=$(( $(sv "$t" 0xe8 T1) - $(sv "$t" 0xe8 T0) ))
      dt=$(( $(sv "$t" 0x10 T1) - $(sv "$t" 0x10 T0) )); [ "$dt" -le 0 ] && dt=1
      c0=$(( dm * 100 / dt )); [ "$c0" -gt 100 ] && c0=100; [ "$c0" -gt "$c0m" ] && c0m=$c0 || true
      [ "$dm" -gt 0 ] && [ $(( da * 1000 / dm )) -gt "$bm" ] && { bm=$(( da * 1000 / dm )); } || true
    done
    [ "$bm" -lt 0 ] && continue
    if [ "$VEN" = GenuineIntel ]; then
      base=$(bits "$(rf "$c" 0xCE)" 8 8)
      local pkg; pkg=$(cat "$CPUROOT/cpu$c/topology/physical_package_id")
      local c62 dc6 c6p
      c62=$(sv "$c" 0x3fd T1); dc6=$(( c62 - $(sv "$c" 0x3fd T0) )); [ "$dc6" -lt 0 ] && dc6=0
      c6p=$(( dc6 * 100 / dt )); [ "$c6p" -gt 100 ] && c6p=100
      local tc; tc=$(( TJ[$pkg] - $(bits "$(sv "$c" 0x19c T1)" 16 7) ))
      [ "$tc" -ge $(( TJ[$pkg] - 10 )) ] && { hot=" !"; HOTANY=1; }
      extra="  $(printf '%3d' "$tc")°C  $(wt4 "$(bits "$(sv "$c" 0x198 T1)" 32 16)/8192") V  C0 $(printf '%3d' "$c0m")%  C6 $(printf '%3d' "$c6p")%  $(printf '%6s' "$(irq_delta "$sib")")$hot"
    else
      base=$(( $(amd_p0 "$c") / 100 ))
      local e2 e1a dE; e2=$(( $(sv "$c" 0xc001029a T1) & 4294967295 )); e1a=$(( $(sv "$c" 0xc001029a T0) & 4294967295 ))
      dE=$(( e2>=e1a ? e2-e1a : e2-e1a+4294967296 ))
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
      extra="  $(printf '%6s' "$(wt "($dE) * ($base) * 100000000 / (2^$eu * ($dt))")") W  $cd $td  C0 $(printf '%3d' "$c0m")%  $(printf '%6s' "$(irq_delta "$sib")")"
    fi
    printf "  core%-3d %5d MHz%s\n" "$c" $(( base * 100 * bm / 1000 )) "$extra"
  done
  { [ "$VEN" = GenuineIntel ] && [ -n "$HOTANY" ] && echo "  ! = within 10°C of TjMax"; } || true
}

# one shared sampling window for the whole panel: every time-delta counter
# (aperf/mperf/tsc, C6/PC2/PC6 residency, package & DRAM/core energy) is read
# for all CPUs in one batched readoc call at T0 and one at T1, with a single
# sleep in between - instead of one sleep per socket plus one for the cores.
mon_sample(){
  local CPUL REPL s
  CPUL=$(printf '%s,' $CPUS); CPUL=${CPUL%,}
  REPL=$(for s in $SOCKETS; do printf '%s,' "${REP[$s]}"; done); REPL=${REPL%,}
  if [ "$VEN" = GenuineIntel ]; then
    snap_load "$CPUL" 0xe7,0xe8,0x10,0x3fd,0x19c,0x198 T0
    snap_load "$REPL" 0x60d,0x3f9,0x611,0x619 T0
    irq_snap T0
    sleep "$INT"
    snap_load "$CPUL" 0xe7,0xe8,0x10,0x3fd,0x19c,0x198 T1
    snap_load "$REPL" 0x60d,0x3f9,0x611,0x619 T1
    irq_snap T1
  else
    snap_load "$CPUL" 0xe7,0xe8,0x10,0xc001029a T0
    snap_load "$REPL" 0xc001029b T0
    irq_snap T0
    sleep "$INT"
    snap_load "$CPUL" 0xe7,0xe8,0x10,0xc001029a T1
    snap_load "$REPL" 0xc001029b T1
    irq_snap T1
  fi
}
mon(){
  dram_speed
  mon_sample
  echo "== $VEN fam${FAM}  Per-socket Overview =="
  for s in $SOCKETS; do
    if [ "$VEN" = GenuineIntel ]; then intel_sock "$s" "${REP[$s]}"; else amd_sock "$s" "${REP[$s]}"; fi
  done
  board_rails
  for s in $SOCKETS; do
    if [ "$VEN" = GenuineIntel ]; then BASEM[$s]=$(( $(bits "$(rf "${REP[$s]}" 0xCE)" 8 8) * 100 ))
    else BASEM[$s]=$(amd_p0 "${REP[$s]}"); fi
  done
  cpu_model_block
  echo "== Per-core Overview =="
  if [ "$VEN" = GenuineIntel ]; then
    echo "  Core      Freq      Temp   VID          C0      C6      IRQ"
  else
    local hasccd=0 hf
    for hf in "${HWROOT:-/sys/class/hwmon}"/hwmon*/temp[0-9]*_label; do
      [ -e "$hf" ] || continue
      case "$(cat "$hf" 2>/dev/null)" in Tccd*) hasccd=1; break ;; esac
    done
    [ "$hasccd" = 0 ] && smu_ok && hasccd=1
    if [ "$hasccd" = 1 ]; then
      echo "  Core      Freq       Power     CCD-Temp     C0      IRQ"
    else
      echo "  Core      Freq       Power     CCD-Temp     C0      IRQ   (*C = socket Tctl; per-CCD needs newer k10temp, or ryzen_smu)"
    fi
  fi
  percore
}

# --json v1 (schema sckoc-mon-v1): machine-readable core subset of the panel.
# Text-only extras (PC-states, DRAM, mesh, throttle flags, board rails) stay
# in the human panel; platform config and PL1/PL2 live under 'sckoc info'.
# Scripts get sockets + per-core essentials.
mon_json(){
  mon_sample
  local first=1 s c p tj basec eu de e1 e2
  printf '{"schema":"sckoc-mon-v1","version":"%s","vendor":"%s","family":%s,"interval_s":%s,"sockets":[' "$MSRVER" "$VEN" "$FAM" "$INT"
  for s in $SOCKETS; do
    c=${REP[$s]}
    [ $first = 1 ] || printf ','
    first=0
    if [ "$VEN" = GenuineIntel ]; then
      tj=$(bits "$(rf "$c" 0x1A2)" 16 8); basec=$(bits "$(rf "$c" 0xCE)" 8 8)
      eu=$(bits "$(rf "$c" 0x606)" 8 5)
      e1=$(( $(sv "$c" 0x611 T0) & 4294967295 )); e2=$(( $(sv "$c" 0x611 T1) & 4294967295 ))
      de=$(( e2>=e1 ? e2-e1 : e2-e1+4294967296 ))
      local mx=0 t cc v198
      for cc in $CPUS; do
        [ "$(cat "$CPUROOT/cpu$cc/topology/physical_package_id" 2>/dev/null)" = "$s" ] || continue
        t=$(( tj - $(bits "$(sv "$cc" 0x19c T1)" 16 7) )); [ "$t" -gt "$mx" ] && mx=$t || true
      done
      v198=$(sv "$c" 0x198 T1)
      printf '{"id":%s,"tjmax_c":%s,"temp_max_c":%s,"vid_v":%s,"core_mhz":%s,"base_mhz":%s,"pkg_w":%s}' \
        "$s" "$tj" "$mx" "$(wt4 "$(bits "$v198" 32 16)/8192")" "$(( $(bits "$v198" 8 8) * 100 ))" "$(( basec * 100 ))" "$(wt "$de/2^$eu/$INT")"
    else
      eu=$(bits "$(rf "$c" 0xC0010299)" 8 5)
      e1=$(( $(sv "$c" 0xc001029b T0) & 4294967295 )); e2=$(( $(sv "$c" 0xc001029b T1) & 4294967295 ))
      de=$(( e2>=e1 ? e2-e1 : e2-e1+4294967296 ))
      local pw=null; [ "$de" -gt 0 ] && pw=$(wt "$de/2^$eu/$INT")
      printf '{"id":%s,"pkg_w":%s}' "$s" "$pw"
    fi
  done
  printf '],"cores":['
  first=1
  for c in $CPUS; do
    local sib dm da dt bm=-1 c0m=0 c0 t
    sib=$(siblings "$c")
    [ "$(echo "$sib" | head -1)" = "$c" ] || continue
    for t in $sib; do
      dm=$(( $(sv "$t" 0xe7 T1) - $(sv "$t" 0xe7 T0) ))
      da=$(( $(sv "$t" 0xe8 T1) - $(sv "$t" 0xe8 T0) ))
      dt=$(( $(sv "$t" 0x10 T1) - $(sv "$t" 0x10 T0) )); [ "$dt" -le 0 ] && dt=1
      c0=$(( dm * 100 / dt )); [ "$c0" -gt 100 ] && c0=100; [ "$c0" -gt "$c0m" ] && c0m=$c0 || true
      [ "$dm" -gt 0 ] && [ $(( da * 1000 / dm )) -gt "$bm" ] && bm=$(( da * 1000 / dm )) || true
    done
    [ "$bm" -lt 0 ] && continue
    p=$(cat "$CPUROOT/cpu$c/topology/physical_package_id" 2>/dev/null || echo 0)
    [ $first = 1 ] || printf ','
    first=0
    if [ "$VEN" = GenuineIntel ]; then
      local bc tj2 c62 dc6 c6p
      bc=$(bits "$(rf "$c" 0xCE)" 8 8)
      tj2=$(bits "$(rf "${REP[$p]}" 0x1A2)" 16 8)
      c62=$(sv "$c" 0x3fd T1); dc6=$(( c62 - $(sv "$c" 0x3fd T0) )); [ "$dc6" -lt 0 ] && dc6=0
      c6p=$(( dc6 * 100 / dt )); [ "$c6p" -gt 100 ] && c6p=100
      printf '{"cpu":%s,"socket":%s,"mhz":%s,"temp_c":%s,"vid_v":%s,"c0_pct":%s,"c6_pct":%s}' \
        "$c" "$p" $(( bc * 100 * bm / 1000 )) "$(( tj2 - $(bits "$(sv "$c" 0x19c T1)" 16 7) ))" "$(wt4 "$(bits "$(sv "$c" 0x198 T1)" 32 16)/8192")" "$c0m" "$c6p"
    else
      local bc; bc=$(( $(amd_p0 "$c") / 100 ))
      printf '{"cpu":%s,"socket":%s,"mhz":%s,"c0_pct":%s}' "$c" "$p" $(( bc * 100 * bm / 1000 )) "$c0m"
    fi
  done
  printf ']}\n'
}

# `sckoc vid` (formerly `vcore`): per-core VID / per-rail voltage detail.
# On Intel this is the 0x198 request voltage, not a measurement; per-core
# values can differ where firmware programs cores individually - package-
# scope parts simply report one value for every core.
vid_cmd(){
  local c v br0 br1
  if [ "$VEN" = GenuineIntel ]; then
    echo "== Per-core VID (0x198[47:32]: requested voltage / regulator target; excludes load-line droop, not measured) =="
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
    if smu_ok; then
      echo "== Rails (ryzen_smu PM table, SMU SVI3 telemetry) =="
      printf "  VDDCR_CPU   %s V\n" "$(smu_f3 0x48)"
      printf "  VDDCR_SOC   %s V  (%s A, %s W)\n" "$(smu_f3 0xD8)" "$(smu_f 0xDC)" "$(smu_f 0xE0)"
      printf "  VDDIO_MEM   %s V   VDD_MISC %s V\n" "$(smu_f3 0xA8)" "$(smu_f3 0xE8)"
      echo "  (per-core identical: single VDDCR rail on AM5; SMU-reported telemetry)"
      exit 0
    fi
    v=$(amd_vid 0)
    [ -n "$v" ] || { echo "fam$FAM P-state VID not verified (needs zenpower/ryzen_smu, or a mapped board sensor)"; exit 1; }
    if [ "$FAM" -ge 26 ]; then
      echo "== Per-core VID: P-state nominal only. fam26 dual-rail BIOS voltage is NOT in MSR =="
      echo "==   Real per-rail needs a mapped board sensor or BIOS. =="
    else
      echo "== Per-core VID (P-state nominal; per-rail override & LLC not visible) =="
    fi
    for c in $CPUS; do
      [ "$(siblings "$c" | head -1)" = "$c" ] || continue
      printf "  core%-3d ~%s V\n" "$c" "$(amd_vid "$c")"
    done
  fi
}

case "${1:-mon}" in
  mon) if [ "${2:-}" = "--json" ]; then mon_json; else mon; fi ;;
  --json) mon_json ;;
  uncore) shift; uncore_cmd "$@" ;;
  info) info_cmd ;;
  dump) shift; for s in $SOCKETS; do
        printf "  S%s cpu%-3s = 0x%s\n" "$s" "${REP[$s]}" \
          "$("$READOC" -p "${REP[$s]}" ${2:+-f $2} -X "$1" 2>/dev/null)"; done ;;
  vid) vid_cmd ;;
  vcore) echo "note: 'vcore' has been renamed - use 'sckoc vid'" >&2; vid_cmd ;;
  -V|version) echo "sckoc $MSRVER"; exit 0 ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "sckoc: unknown command '$1'"; echo "try: sckoc help"; exit 1 ;;
esac
MSR_SH
chmod 755 /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/hsmp-msg /usr/local/bin/tpmi-uncore

mkdir -p /etc/bash_completion.d
cat > /etc/bash_completion.d/sckoc <<'COMP_SH'
# SPDX-License-Identifier: GPL-2.0-only
# bash completion for sckoc
_sckoc(){
  local cur prev words cword
  if declare -F _init_completion >/dev/null 2>&1; then
    _init_completion -n : || return
  else
    cur=${COMP_WORDS[COMP_CWORD]}; prev=${COMP_WORDS[COMP_CWORD-1]}
    words=("${COMP_WORDS[@]}"); cword=$COMP_CWORD
  fi
  local cmd=${words[1]:-}

  if [ "$cword" -eq 1 ]; then
    COMPREPLY=($(compgen -W "mon info vid uncore dump uninstall version help --json -V -h --help" -- "$cur"))
    return
  fi

  case "$cmd" in
    dump)
      if [ "$cword" -eq 2 ]; then
        # registers sckoc itself decodes, filtered by CPU vendor; hex match is
        # case-insensitive. Kept portable to old bash (EL7 is 4.2): tr + case
        # glob instead of the 4.0 ${var,,} expansion, and an explicit array.
        local ven intel amd regs w wl curl
        local -a out=()
        ven=$(awk '/vendor_id/{print $3;exit}' /proc/cpuinfo 2>/dev/null)
        intel="0x10 0xCE 0xE7 0xE8 0x194 0x198 0x19C 0x1A2 0x1AD 0x1AE 0x3F9 0x3FD 0x606 0x60D 0x610 0x611 0x614 0x619 0x620 0x621"
        amd="0xC0010015 0xC0010063 0xC0010064 0xC0010065 0xC0010066 0xC0010299 0xC001029A 0xC001029B"
        case "$ven" in
          GenuineIntel) regs=$intel ;;
          AuthenticAMD) regs=$amd ;;
          *)            regs="$intel $amd" ;;
        esac
        if [ -z "$cur" ]; then
          COMPREPLY=($(compgen -W "$regs" -- ""))          # common case: no fork per register
        else
          curl=$(printf '%s' "$cur" | tr 'A-Z' 'a-z')
          for w in $regs; do
            wl=$(printf '%s' "$w" | tr 'A-Z' 'a-z')
            case "$wl" in "$curl"*) out+=("$w") ;; esac
          done
          [ ${#out[@]} -gt 0 ] && COMPREPLY=("${out[@]}")
        fi
      elif [ "$cword" -eq 3 ]; then
        # common bitfields: halves, Intel VID 47:32, uncore/ratio fields
        COMPREPLY=($(compgen -W "63:32 47:32 31:16 31:0 21:15 15:0 14:8 7:0 6:0" -- "$cur"))
        declare -F __ltrim_colon_completions >/dev/null 2>&1 && __ltrim_colon_completions "$cur"
      fi
      return ;;
    mon|uncore)
      [ "$cword" -eq 2 ] && COMPREPLY=($(compgen -W "--json" -- "$cur"))
      return ;;
    uninstall)
      [ "$cword" -eq 2 ] && COMPREPLY=($(compgen -W "-y" -- "$cur"))
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
echo "== usage: sckoc | sckoc info | sckoc vid | sckoc uncore | sckoc dump <reg> [hi:lo] | sckoc -V | INT=<sec> sckoc =="
if [ -r /usr/share/bash-completion/bash_completion ] || [ -r /etc/bash_completion ]; then
  echo "== tab completion installed (new shells; or: source /etc/bash_completion.d/sckoc) =="
else
  echo "== tab completion installed, but 'bash-completion' was not detected =="
  echo "==   this shell: source /etc/bash_completion.d/sckoc  (subcommands + dump registers work) =="
  echo "==   full 'dump <reg> <TAB>' bitfield handling wants the bash-completion package =="
fi
echo "== first run: =="
/usr/local/bin/sckoc

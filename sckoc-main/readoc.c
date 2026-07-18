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

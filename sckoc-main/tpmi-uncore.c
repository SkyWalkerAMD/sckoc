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

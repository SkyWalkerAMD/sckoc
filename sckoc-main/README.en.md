# sckoc

> 中文文档 / Chinese documentation: [README.md](README.md)

A **read-only** hardware monitor for Intel and AMD servers and workstations. One command gives a complete three-level view (Platform, per-socket, per-core) covering voltage, temperature, frequency, power, C-state residency and platform security state. The tool is pure-read by design: it never writes a single MSR, so it works under Secure Boot and kernel lockdown (integrity mode).

**Current version: 2.3.0**

## Design principles

- **Read-only architecture**: reads through `/dev/cpu/*/msr` and `/dev/hsmp` only, never writes a register, never changes system state; safe on production machines
- **Honest output**: any field that cannot be read shows `N/A` or is hidden; sckoc never prints guessed or fabricated numbers
- **Zero-intrusion install**: package installs load no kernel modules and touch no system configuration; that is left to the administrator or the optional one-shot script
- **Cross-platform symmetry**: Intel and AMD share one presentation structure, each backed by its platform's native interfaces

## Supported platforms

- **Intel** family 6: Xeon W890/W790 platforms, HEDT (X299) and earlier MSR-capable parts
- **AMD** family 19h/1Ah (Zen3/4/5): EPYC, Threadripper (HSMP is in-kernel for EPYC; Threadripper PRO 9000WX needs a DKMS driver which the installer configures automatically, see below)

## Features

**Platform overview**: Secure Boot state, kernel lockdown level, OC Lock (Intel `0x194`), SMT/HT state (labelled per platform: HT on Intel, SMT on AMD), NUMA node count, SMU firmware version (AMD)

**Per socket**:

- VID request voltage (Intel `0x198`); on AMD, real dual-rail voltage from a supported board sensor or the P-state nominal value, see notes below
- Hottest-core temperature (against TjMax), package PC2/PC6 residency, throttle flags (THROTTLING / PROCHOT)
- Current/base core frequency; mesh and IOD-S/IOD-N multi-domain uncore frequency (TPMI sysfs, with Min/Max)
- DRAM frequency and voltage (SMBIOS), DRAM power (Intel RAPL), DDR bandwidth utilisation (AMD HSMP)
- Package power (RAPL), PL1/PL2 power limits with enable/lock state (Intel), PPT limit (AMD), FCLK/MCLK, Fmax/Fmin, CCLK limit, C0% (AMD)
- Board voltage rails (Super I/O drivers such as nct6775)

**Per core**: effective frequency (APERF/MPERF), temperature (per-core DTS on Intel, per-CCD on AMD, see below), VID request voltage, C0/C6 residency (Intel), core power (AMD). With SMT/HT enabled, threads are aggregated per physical core. Rows within 10 °C of TjMax are flagged with `!` (Intel).

## Intel platform notes

**VID**: Intel exposes an architectural voltage MSR. sckoc reads the [47:32] field of `0x198` (IA32_PERF_STATUS) per core with no extra driver. Note this is the VID *request* — the voltage the PCU asks the FIVR for — not a measured rail voltage; load-line droop is not included. True rail telemetry lives in the VR controller and is reachable only via BMC/PMBus.

**Per-core temperature**: every Intel core has its own digital thermal sensor (DTS); sckoc reads per-core MSR `0x19C` (IA32_THERM_STATUS) and converts against TjMax, accurate to the individual core.

**Uncore / mesh frequency**: mesh and IOD-S/IOD-N multi-domain uncore frequencies come from the TPMI sysfs interface (with Min/Max), which needs the `intel-uncore-frequency` or `intel-uncore-frequency-tpmi` driver (kernel 5.6+/6.5+, backported to RHEL 9). Legacy Xeons without the driver fall back to the uncore MSRs (`0x620/0x621`). **TPMI-era Xeons (Granite Rapids and later) on old kernels** (CentOS 7.9's 3.10, el8): the uncore MSRs are retired (read as 0) and the kernel has no TPMI driver, so sckoc uses its bundled `tpmi-uncore` helper to mmap the OOBMSM device's TPMI MMIO region **read-only** and decode it directly (field layout per the kernel `intel-uncore-frequency-tpmi` driver; verified on Xeon 658X: compute mesh plus IOD-S/N domains and Min/Max all match the driver's readings one for one). Such values are tagged `(tpmi)`. This path needs root and lockdown=none (Secure Boot enables lockdown and blocks userspace PCI BAR mmap; the sysfs path on newer kernels has no such restriction).

**Power limits**: PL1/PL2 limits with their enable/lock state come from the RAPL MSRs; package and DRAM power likewise. OC Lock state is read from `0x194` (MSR_FLEX_RATIO).

Everything on Intel relies only on the in-kernel `msr` module plus the optional uncore-frequency driver — no out-of-tree components — and works out of the box under Secure Boot + lockdown=integrity.

## AMD platform notes

**Vcore**: AMD has no architectural voltage MSR. The default reading is the current P-state's decoded VID, i.e. the **nominal voltage** the CPU requests from the VRM, not SVI telemetry. Conversion: fam 1Ah uses `V = 0.250 + VID×5 mV`, fam 17h SVI2 uses `V = 1.55 − VID×6.25 mV`; fam 19h mixes Zen3/Zen4 encodings so sckoc shows N/A rather than guess.

Note that on fam 1Ah (Zen5) the P-state VID is a single socket-wide value and does **not** equal the dual-rail BIOS settings. For boards in the support table, sckoc instead reads the real per-rail voltages from the board Super I/O. Currently listed: **ASUS Pro WS WRX90E-SAGE SE** (nct6798, `VDDCR_CPU0`=in0, `VDDCR_CPU1`=in6, confirmed by BIOS voltage-offset delta testing); on that board the socket line shows both real rails. Other boards fall back to the labelled P-state nominal value. For SVI telemetry, install zenpower/ryzen_smu.

**Per-core temperature**: AMD has no per-core DTS; the SMU aggregates temperature per CCD. The per-core table shows each core's CCD temperature, with CCD numbers normalised through the L3 topology stride (fam26 packs two CCX per CCD with alternating L3 ids, corrected to a contiguous 0…N). If the kernel's k10temp does not yet expose per-CCD sensors for the part (e.g. fam26/Zen5 sTR5 on kernel 6.8), sckoc falls back to the socket Tctl and marks it `*`.

**HSMP auto-configuration**: FCLK/MCLK, PPT, DDR bandwidth and C0% depend on `/dev/hsmp`. On AMD, install.sh handles it all: loads k10temp, tries the in-kernel `amd_hsmp`, and where that is unavailable (TR PRO 9000WX) automatically DKMS-builds [amd/amd_hsmp](https://github.com/amd/amd_hsmp) (producing the `hsmp_acpi` module) and persists autoload. **With Secure Boot enabled, unsigned DKMS modules cannot load**; the installer detects this and prompts: disable Secure Boot, or enroll a MOK key so DKMS signs the module (`mokutil --import`, then enroll on reboot). HSMP Support must also be enabled in BIOS (AMD CBS / NBIO menu; the name varies by board).

**Consumer Ryzen / old kernels (ryzen_smu fallback source)**: desktop Ryzen (e.g. Ryzen 9000) has no HSMP, so FCLK/PPT cannot come from `/dev/hsmp`; older kernels (Ubuntu 22.04's 5.15) also have a k10temp that predates new CPU families, so temperature is unreadable too. Installing the out-of-tree [ryzen_smu](https://github.com/kylon/ryzen_smu) driver (DKMS) helps: when sckoc sees `/sys/kernel/ryzen_smu_drv/pm_table` with a table version matching a verified layout, it fills in socket/CCD temperature, FCLK/MCLK, PPT, SMU firmware version and SVI3 voltage telemetry (`sckoc vcore` shows VDDCR_CPU/SOC/VDDIO_MEM and other rails) — all **read-only**, tagged `(smu)`. A non-matching table version stays `N/A`; sckoc never guesses. Verified platform: Granite Ridge (Ryzen 9000, table version 0x620205). Note ryzen_smu is a third-party module, not an sckoc dependency; **kernels before 5.18** need `-std=gnu11` added to its dkms.conf `CFLAGS_MODULE+=` (the kernel's default gnu89 fails with `'for' loop initial declarations`).

**DRAM line voltage**: the voltage in `DRAM ... @ x.x V` comes from SMBIOS (dmidecode) and is the firmware's JEDEC nominal value (always 1.1 V for DDR5); it does **not** reflect the actual EXPO/XMP setting. The real memory interface voltage is `VDDIO_MEM` in `sckoc vcore` (needs ryzen_smu).

## Installation

**Option 1: one-shot script** (any distribution; works from a clone or a standalone download)

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/install.sh | sudo bash
# if raw.githubusercontent.com is blocked or rate-limited (HTTP 429), use the CDN mirror:
curl -fsSL https://cdn.jsdelivr.net/gh/SkyWalkerAMD/sckoc@main/install.sh | sudo bash
```

Self-contained: installs dependencies (gcc, dmidecode), compiles the helpers, deploys the command and bash completion, and sets the msr module to load at boot. On AMD it additionally configures k10temp and HSMP (including DKMS, see above) and probes for a board sensor driver (nct6775 etc.) to enable voltage rails and real Vcore display. Re-running upgrades in place and cleans old versions.

**Option 2: packages** (download from [Releases](https://github.com/SkyWalkerAMD/sckoc/releases))

```bash
# Fedora: pick the fcNN package matching your release (example: Fedora 44; use the actual filename from the Releases page)
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/2.3.0/sckoc-2.3.0-1.fc44.x86_64.rpm
# Rocky / Alma / RHEL / CentOS Stream: pick the matching elN package (example: EL8); the COPR in option 3 is preferred as it matches your distro automatically
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/2.3.0/sckoc-2.3.0-1.el8.x86_64.rpm
# Ubuntu / Debian
sudo apt install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/2.3.0/sckoc_2.3.0-1_amd64.deb
```

Note: RPM binaries are tied to the distro that built them (glibc and dependencies differ); fcNN packages do not install on RHEL-family systems and vice versa — pick the asset matching your distribution.

**Option 3: repositories** (add once, then `dnf/apt install sckoc` with automatic updates)

The easiest path is the setup script, which configures the right repository, after which the standard `dnf install` / `apt install` works:

```bash
curl -fsSL https://skywalkeramd.github.io/sckoc/apt/setup.sh | sudo bash
sudo dnf install sckoc    # or on Debian/Ubuntu: sudo apt install sckoc
```

The setup script detects the distribution: RPM systems get the COPR enabled, Debian systems get an apt source. Manual setup also works:

Rocky / CentOS Stream / RHEL (COPR):

```bash
sudo dnf copr enable skywalkeramd/sckoc && sudo dnf install sckoc
```

Ubuntu / Debian (GitHub Pages apt repository):

```bash
echo "deb [trusted=yes] https://skywalkeramd.github.io/sckoc/apt stable main" | sudo tee /etc/apt/sources.list.d/sckoc.list
sudo apt update && sudo apt install sckoc
```

Note: both COPR and the apt repo are third-party repositories — adding the source once is the distro's third-party trust mechanism; afterwards `dnf/apt install sckoc` and upgrades behave like any other package. Self-building: deb via `bash packaging/build-deb.sh` (run from the repo root); rpm by fetching the source tarball first: `spectool -g -R packaging/sckoc.spec && rpmbuild -ba packaging/sckoc.spec` (or download Source code (tar.gz) from Releases into `~/rpmbuild/SOURCES/sckoc-2.3.0.tar.gz`). Package installs auto-probe and load k10temp/HSMP modules on AMD but **never run DKMS builds**; platforms that need DKMS (TR PRO 9000WX) should use install.sh or configure it once by hand as described above.

## Usage

```bash
sudo sckoc                    # full monitor panel (default: mon)
sudo sckoc vcore              # per-core / per-rail core voltage
sudo sckoc uncore             # uncore/mesh frequency limits + BIOS boot values (Intel)
sudo sckoc --json             # machine-readable JSON (both mon and uncore take --json)
sudo sckoc dump 0x198 47:32   # read any MSR bitfield on every socket
sudo sckoc help               # detailed usage and examples
sudo sckoc -V                 # version
sudo INT=2 sckoc              # 2-second sampling window (default 1)
sudo watch -n 3 sckoc         # continuous refresh
```

Tab completion covers the subcommands (mon/vcore/uncore/dump/uninstall/help/version) and `--json`, common MSR registers after `dump`, and `-y` after `uninstall`.

Subcommands:

- `mon` (default): the full three-section panel (Platform, per-socket, per-core); per-core rows within 10 °C of TjMax are flagged with `!`; with `--json` prints a machine-readable v1 document (schema `sckoc-mon-v1`) carrying the socket and per-core essentials
- `vcore`: Intel shows the per-core `0x198` VID request voltage (the PCU/FIVR target, droop not included — not a measurement); AMD shows real per-rail voltages (supported boards) or the P-state nominal value
- `uncore`: per-domain uncore/mesh frequency limits (Intel only); on the sysfs path it also shows the BIOS boot values (`initial_*_freq_khz`) and flags runtime-changed limits with `*`; the MSR/TPMI fallback paths have no boot-value concept and show `-` in those columns; with `--json` prints schema `sckoc-uncore-v1`; when the sysfs driver is present this command works without the msr module
- `dump <reg> [hi:lo]`: read the given MSR on every socket, optionally extracting the `hi:lo` bitfield, e.g. `dump 0x198 47:32`
- `uninstall [-y]`: detects how sckoc was installed and removes it completely; `-y` skips confirmation
- `help` / `-h`: detailed usage, environment variables, examples
- `version` / `-V`: print the version

Environment variables: `INT=<seconds>` sets the sampling window (default 1), `DMI=<path>` overrides the dmidecode path.

Note: on RHEL/Rocky systems, sudo's `secure_path` does not include `/usr/local/bin`, so after a script (install.sh) install, non-root users should run `sudo /usr/local/bin/sckoc` or switch to a root shell; rpm/deb installs land in `/usr/bin` and are unaffected.

## Uninstall

```bash
sudo sckoc uninstall          # interactive confirmation; add -y to skip
```

Detects the install method (script / rpm / deb) and removes everything: legacy-version files, bash completion, module autoload entries and repository configuration. Shared system packages (gcc/dmidecode/dkms/git) are kept by default. A DKMS amd_hsmp driver configured by install.sh is removed too (identified by a marker file); a manually installed amd_hsmp is kept, with the manual removal commands printed. Loaded kernel modules stay until the next reboot (hot removal races with concurrent readers). If the tool itself is broken, the standalone fallback:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/uninstall.sh | sudo bash
# mirror:
curl -fsSL https://cdn.jsdelivr.net/gh/SkyWalkerAMD/sckoc@main/uninstall.sh | sudo bash
```

## Requirements and permissions

Needs root and the `msr` kernel module (handled by the installer; `sckoc uncore` works without the msr module when the intel-uncore-frequency sysfs driver is present). Mesh/IOD frequency needs the `intel-uncore-frequency(-tpmi)` driver (kernel 5.6+/6.5+, backported to RHEL 9). AMD FCLK/PPT etc. need `/dev/hsmp`: in-kernel `amd_hsmp` on EPYC (5.18+), DKMS `hsmp_acpi` on Threadripper PRO 9000WX (installer handles it), both requiring HSMP enabled in BIOS. AMD temperature needs k10temp; voltage rails and real Vcore need a board Super I/O driver (nct6775 etc., auto-probed by the installer). Everything except the DKMS cases works under Secure Boot + lockdown=integrity; DKMS modules need MOK signing under Secure Boot.

## Project status

- **Distribution channels**: GitHub Releases (rpm / deb / source), COPR (Fedora / RHEL / EPEL 8-10 / Amazon Linux), GitHub Pages apt repository
- **Fedora official repository**: review submission in progress
- **Multi-socket (2S+) platforms**: the code is written for multiple sockets but has not yet been verified on real dual-socket hardware; test reports welcome

Feedback and board Super I/O channel mappings (to grow the supported-board table) are welcome via [Issues](https://github.com/SkyWalkerAMD/sckoc/issues).

## License

Released under GPL-2.0. All code is original work, including the monitor `sckoc`, the MSR reader `readoc`, the AMD HSMP helper `hsmp-msg.c`, and the packaging and installer scripts.

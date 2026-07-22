<!-- SPDX-License-Identifier: GPL-2.0-only -->
<div align="center">

# sckoc

[![license](https://img.shields.io/badge/license-GPL--2.0-blue)](COPYING)
![language](https://img.shields.io/badge/language-Bash%20%2B%20C-orange)
[![stars](https://img.shields.io/github/stars/SkyWalkerAMD/sckoc?logo=github&label=Stars)](https://github.com/SkyWalkerAMD/sckoc/stargazers)
[![downloads](https://img.shields.io/github/downloads/SkyWalkerAMD/sckoc/total?label=downloads&color=brightgreen&cacheSeconds=3600)](https://github.com/SkyWalkerAMD/sckoc/releases)
[![issues](https://img.shields.io/github/issues/SkyWalkerAMD/sckoc?label=issues&color=yellow)](https://github.com/SkyWalkerAMD/sckoc/issues)

English | [中文](README.md)

</div>

A **read-only** hardware monitor for Intel and AMD servers and workstations. A single `sckoc` command gives a live per-socket and per-core view covering voltage, temperature, frequency, power and C-state residency; `sckoc info` adds the static platform report (security state, CPU ratio configuration, power limits, memory and cache). It never writes an MSR and works under Secure Boot and kernel lockdown (integrity).

**Current version: 4.0.0**

## Design principles

- **Read-only architecture**: reads through `/dev/cpu/*/msr` and `/dev/hsmp` only; never writes a register or changes system state; safe on production machines
- **Honest output**: unreadable fields show `N/A` or are hidden; no guessed numbers
- **Zero-intrusion install**: package installs load no modules and touch no system configuration; that is left to the administrator or the optional script
- **Cross-platform symmetry**: Intel and AMD share one presentation structure, each backed by its platform's native interfaces

## Supported platforms

- **Intel** family 6: Xeon W890/W790 platforms, HEDT (X299) and earlier MSR-capable parts
- **AMD** family 19h/1Ah (Zen3/4/5): EPYC, Threadripper (HSMP is in-kernel for EPYC; TR PRO 9000WX needs a DKMS driver, configured automatically by the installer)

## Features

**`sckoc info` (static platform report)**: security state (Secure Boot, lockdown, OC Lock), HT/SMT and NUMA, SMU firmware (AMD); configured ratio ceilings (base / max-efficiency / min) with the 0xCE programmable flags; turbo ratio bins; thermal config (TjMax, TCC/PROCHOT offset); RAPL power limits (PL1/PL2 with time windows and lock) and the package power envelope; the per-DIMM memory table (next section); cache topology. Each block degrades independently without the msr module.

**Per socket**:

- VID request voltage (Intel `0x198`); on AMD, real dual-rail voltage from a supported board sensor or the P-state nominal (see AMD notes)
- Hottest-core temperature (against TjMax), package PC2/PC6 residency, throttle flags (THROTTLING / PROCHOT)
- Current core frequency; current mesh and IOD-S/IOD-N multi-domain uncore frequency (limits and BIOS boot values via `sckoc uncore`)
- Per-core IRQ column: interrupts serviced by the core within the sampling window (summed over every `/proc/interrupts` source, SMT siblings included); read-only, no driver
- Mem Max: the hottest populated DIMM temperature (BMC sensors), parallel to the CPU Temp Max
- DRAM actual running rate (SMBIOS), DRAM power (Intel RAPL), DDR bandwidth utilisation (AMD HSMP)
- Package power (RAPL), PPT limit (AMD), FCLK/MCLK, Fmax/Fmin, CCLK limit, C0% (AMD)
- Board voltage rails (Super I/O drivers such as nct6775)

**Per core**: effective frequency (APERF/MPERF), temperature (per-core DTS on Intel; per-CCD on AMD), VID request voltage, C0/C6 residency (Intel), core power (AMD). With SMT/HT, threads are aggregated per physical core. Rows within 10 °C of TjMax are flagged with `!` (Intel).

## Intel platform notes

**VID**: per-core read of `0x198` (IA32_PERF_STATUS) [47:32], no extra driver. This is the VID *request* - the target the PCU asks the FIVR for - not a measured rail; load-line droop is not included. True rail telemetry lives in the VR controller and is reachable only via BMC/PMBus. Per-core values can differ where firmware programs cores individually; package-scope parts report one value.

**Per-core temperature**: per-core DTS via MSR `0x19C` (IA32_THERM_STATUS), converted against TjMax, accurate to the individual core.

**Uncore / mesh frequency**: read from the TPMI sysfs interface; needs the `intel-uncore-frequency(-tpmi)` driver (kernel 5.6+/6.5+, backported to RHEL 9). Legacy Xeons without the driver fall back to the uncore MSRs (`0x620/0x621`). On TPMI-era Xeons (Granite Rapids+) with old kernels, where neither is available, the bundled `tpmi-uncore` helper decodes the TPMI MMIO region **read-only**; such values are tagged `(tpmi)`. That path needs root and lockdown=none (Secure Boot enables lockdown and blocks userspace PCI BAR mmap; the sysfs path on newer kernels is unaffected).

**Power limits**: PL1/PL2 with enable/lock state come from the RAPL MSRs; OC Lock from `0x194` (MSR_FLEX_RATIO). Both shown by `sckoc info`.

Everything on Intel relies only on the in-kernel `msr` module plus the optional uncore-frequency driver - no out-of-tree components - and works out of the box under Secure Boot + lockdown=integrity.

## AMD platform notes

**Vcore vs VID**: AMD has no architectural voltage MSR. The default reading (labelled `VID`) is the current P-state's decoded VID - the nominal voltage requested from the VRM, not SVI telemetry. Conversion: fam 1Ah `V = 0.250 + VID×5 mV`, fam 17h SVI2 `V = 1.55 − VID×6.25 mV`; fam 19h mixes Zen3/Zen4 encodings, so N/A rather than a guess.

On fam 1Ah (Zen5) the P-state VID is one socket-wide value and does not equal the dual-rail BIOS settings. On supported boards (currently: **ASUS Pro WS WRX90E-SAGE SE**) sckoc reads the real per-rail voltages from the board Super I/O and the socket line shows both rails; other boards fall back to the P-state nominal, labelled `VID`. For SVI telemetry, install zenpower/ryzen_smu.

**Per-core temperature**: AMD has no per-core DTS; the SMU aggregates per CCD, and the per-core table shows each core's CCD temperature. Where the kernel's k10temp does not expose per-CCD sensors for the part (e.g. fam26/Zen5 sTR5 on kernel 6.8), sckoc falls back to the socket Tctl, marked `*`.

**HSMP**: FCLK/MCLK, PPT, DDR bandwidth and C0% depend on `/dev/hsmp`. On AMD, install.sh configures it all: k10temp, the in-kernel `amd_hsmp`, and where that is unavailable (TR PRO 9000WX) a DKMS build of [amd/amd_hsmp](https://github.com/amd/amd_hsmp) (the `hsmp_acpi` module) with persistent autoload. Unsigned DKMS modules cannot load under Secure Boot; the installer prompts to disable Secure Boot or enroll a MOK key. HSMP Support must also be enabled in BIOS (AMD CBS / NBIO menu).

**Consumer Ryzen / old kernels**: desktop Ryzen has no HSMP, and older k10temp does not know new families. Installing the third-party [ryzen_smu](https://github.com/kylon/ryzen_smu) (DKMS) helps: when sckoc sees a pm_table whose version matches a verified layout, it fills in socket/CCD temperature, FCLK/MCLK, PPT, SMU firmware and SVI3 voltage telemetry (`sckoc vid` shows VDDCR_CPU/SOC/VDDIO_MEM and other rails) - all **read-only**, tagged `(smu)`; a non-matching version stays `N/A`. Verified: Granite Ridge (Ryzen 9000, table version 0x620205). Kernels before 5.18 need `-std=gnu11` added to its dkms.conf.

## Memory display (Intel and AMD alike)

The `sckoc mon` DRAM line is the actual running rate (SMBIOS Configured Speed). The `sckoc info` per-DIMM table columns: **Speed** (actual running rate), **JEDEC** (nominal rate), **VDDQ** (measured rail), **Size**, plus **Temp** where the BMC exposes DIMM temperature sensors; columns without a backing sensor are omitted.

VDDQ is read over IPMI (ipmitool) from the BMC DRAM-rail sensor (recognised under either the VDDQ or the VCCD naming); boards with one rail per memory controller show both, e.g. `1.40/1.39 V`. The SMBIOS Configured Voltage is the JEDEC nominal (1.1 V for all DDR5) and does not reflect the EXPO/XMP setting, so it is not shown. With ryzen_smu installed, `VDDIO_MEM` in `sckoc vid` is a further memory-interface voltage source.

## Installation

**Option 1: one-shot script** (any distribution)

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/install.sh | sudo bash
# CDN mirror if raw.githubusercontent.com is blocked or rate-limited (HTTP 429):
curl -fsSL https://cdn.jsdelivr.net/gh/SkyWalkerAMD/sckoc@main/install.sh | sudo bash
```

Self-contained: installs dependencies (gcc, dmidecode, ipmitool), builds and deploys, sets up bash completion and msr autoload; on AMD it configures k10temp/HSMP (DKMS included) and probes Super I/O drivers. Re-running upgrades in place.

**Option 2: packages** (from [Releases](https://github.com/SkyWalkerAMD/sckoc/releases); an RPM is tied to the distribution it was built for - pick the matching asset)

```bash
# Fedora (fc44 shown; use the actual asset name from Releases)
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/4.0.0/sckoc-4.0.0-1.fc44.x86_64.rpm
# Rocky / Alma / RHEL / CentOS Stream (el8 shown; option 3's COPR is preferred)
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/4.0.0/sckoc-4.0.0-1.el8.x86_64.rpm
# Ubuntu / Debian
sudo apt install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/4.0.0/sckoc_4.0.0-1_amd64.deb
```

**Option 3: repositories** (add once, then `dnf/apt install sckoc` with automatic updates)

```bash
curl -fsSL https://skywalkeramd.github.io/sckoc/apt/setup.sh | sudo bash   # detects the distribution
sudo dnf install sckoc    # or Debian/Ubuntu: sudo apt install sckoc
```

Manual setup: `sudo dnf copr enable skywalkeramd/sckoc` on RPM systems; on Debian systems:

```bash
echo "deb [trusted=yes] https://skywalkeramd.github.io/sckoc/apt stable main" | sudo tee /etc/apt/sources.list.d/sckoc.list
sudo apt update && sudo apt install sckoc
```

Self-building: `bash packaging/build-deb.sh` for deb; `spectool -g -R packaging/sckoc.spec && rpmbuild -ba packaging/sckoc.spec` for rpm. Packages auto-probe and load k10temp/HSMP on AMD but **never run DKMS builds**; platforms that need DKMS (TR PRO 9000WX) use install.sh or a one-time manual setup.

## Usage

```bash
sudo sckoc                    # live monitor (default: mon)
sudo sckoc info               # static platform report
sudo sckoc vid                # per-core VID / per-rail voltage
sudo sckoc uncore             # uncore/mesh frequency limits + BIOS boot values (Intel)
sudo sckoc --json             # JSON output (both mon and uncore take --json)
sudo sckoc dump 0x198 47:32   # read any MSR bitfield on every socket
sudo INT=2 sckoc              # 2-second sampling window (default 1)
sudo watch -n 3 sckoc         # continuous refresh
```

- `mon` (default): the live panel; `--json` prints schema `sckoc-mon-v1`
- `info`: the static platform report (security state, ratio ceilings, turbo bins, thermal, RAPL, memory table, cache)
- `vid`: Intel shows the per-core `0x198` VID request (not a measurement); AMD shows measured per-rail voltages (supported boards) or the P-state nominal. `vcore` is a deprecated alias
- `uncore`: per-domain limits with the BIOS boot values, runtime-changed limits flagged `*`; `--json` prints `sckoc-uncore-v1`; works without the msr module when the sysfs driver is present
- `dump <reg> [hi:lo]`: read an MSR on every socket, optional bitfield
- `uninstall [-y]`: detects the install method and removes sckoc completely
- `help` / `version`: usage and version

Tab completion covers all subcommands and options (including common registers and bitfields after `dump`). Environment variables: `INT=<seconds>` sampling window (default 1); `DMI=` and `IPMITOOL=` override the respective tool paths.

Note: sudo's `secure_path` on RHEL/Rocky excludes `/usr/local/bin`; after a script install, non-root users run `sudo /usr/local/bin/sckoc`. rpm/deb installs land in `/usr/bin` and are unaffected.

## Uninstall

```bash
sudo sckoc uninstall          # interactive confirmation; -y skips it
```

Detects the install method (script / rpm / deb) and removes everything: program files, bash completion, module autoload entries and repository configuration; a DKMS amd_hsmp configured by install.sh is removed too, a manually installed one is kept with removal commands printed. Shared system packages (gcc/dmidecode/dkms etc.) are kept; loaded kernel modules stay until reboot. Standalone fallback if the tool itself is broken:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/uninstall.sh | sudo bash
```

## Requirements and permissions

Needs root and the `msr` kernel module (handled by the installer). Mesh/IOD frequency needs the `intel-uncore-frequency(-tpmi)` driver. AMD FCLK/PPT etc. need `/dev/hsmp` (in-kernel `amd_hsmp` on EPYC, DKMS `hsmp_acpi` on TR PRO 9000WX) with HSMP enabled in BIOS. AMD temperature needs k10temp, with a BMC/IPMI side-band fallback where it cannot cover the CPU. BMC data (DIMM/CPU temperatures, VDDQ) needs ipmitool and a responding BMC. Voltage rails and real Vcore need a board Super I/O driver (auto-probed by the installer). Everything except the DKMS cases and the TPMI MMIO fallback works under Secure Boot + lockdown=integrity; DKMS modules need MOK signing under Secure Boot.

## Project status

- **Distribution channels**: GitHub Releases (rpm / deb / source), COPR (Fedora / RHEL / EPEL 8-10 / Amazon Linux), GitHub Pages apt repository
- **Fedora official repository**: review submission in progress
- **Multi-socket (2S+) platforms**: written for multiple sockets, not yet verified on real dual-socket hardware; test reports welcome

Feedback and board Super I/O channel mappings are welcome via [Issues](https://github.com/SkyWalkerAMD/sckoc/issues).

## License

GPL-2.0. All code is original work: the monitor `sckoc`, the MSR reader `readoc`, the AMD HSMP helper `hsmp-msg.c`, and the packaging and installer scripts.

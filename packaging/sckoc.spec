# SPDX-License-Identifier: GPL-2.0-only
Name:           sckoc
Version:        3.0.7
Release:        1%{?dist}
Summary:        Read-only hardware monitor for Intel/AMD servers
License:        GPL-2.0-only
URL:            https://github.com/SkyWalkerAMD/sckoc
Source0:        %{url}/archive/refs/tags/%{version}/%{name}-%{version}.tar.gz
BuildRequires:  gcc
BuildRequires:  make
Requires:       dmidecode
Recommends:     ipmitool
Requires:       kmod
Requires(post): kmod
ExclusiveArch:  x86_64

%description
sckoc is a read-only hardware monitor for Intel and AMD servers and
workstations. It reports per-socket and per-core voltage, temperature,
frequency (core/mesh/IOD/DRAM), power (RAPL, PL1/PL2, PPT), C-state residency
and platform security state, and works under Secure Boot / kernel lockdown
(integrity).

%prep
%autosetup

%build
%set_build_flags
%make_build CC=gcc

%install
# /usr/bin/sckoc is the monitor SCRIPT; compiled helpers go to libexec,
# which is the first place the script looks for them
install -D -p -m0755 sckoc    %{buildroot}%{_bindir}/sckoc
install -D -p -m0755 readoc   %{buildroot}%{_libexecdir}/%{name}/readoc
install -D -p -m0755 hsmp-msg %{buildroot}%{_libexecdir}/%{name}/hsmp-msg
install -D -p -m0755 tpmi-uncore %{buildroot}%{_libexecdir}/%{name}/tpmi-uncore
install -D -p -m0644 packaging/sckoc.completion %{buildroot}%{_datadir}/bash-completion/completions/sckoc
install -D -p -m0644 packaging/sckoc.modules-load %{buildroot}%{_prefix}/lib/modules-load.d/sckoc.conf
install -D -p -m0644 packaging/sckoc.1 %{buildroot}%{_mandir}/man1/sckoc.1
# ghost placeholder: the post scriptlet may create this on AMD hosts
mkdir -p %{buildroot}%{_sysconfdir}/modules-load.d
touch %{buildroot}%{_sysconfdir}/modules-load.d/sckoc-amd.conf

%check
bash -n %{buildroot}%{_bindir}/sckoc
head -c2 %{buildroot}%{_bindir}/sckoc | grep -q '#!'
%{buildroot}%{_libexecdir}/%{name}/readoc -V
test -x %{buildroot}%{_libexecdir}/%{name}/hsmp-msg
test -x %{buildroot}%{_libexecdir}/%{name}/tpmi-uncore

%post
modprobe msr 2>/dev/null || :
if grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null; then
  AMDMODS=""
  modprobe k10temp 2>/dev/null && AMDMODS="k10temp" || :
  [ -e /dev/hsmp ] || modprobe amd_hsmp 2>/dev/null || modprobe hsmp_acpi 2>/dev/null || :
  H=$(lsmod | awk '$1=="amd_hsmp"||$1=="hsmp_acpi"{print $1;exit}')
  [ -n "$H" ] && AMDMODS="$AMDMODS $H"
  [ -n "$AMDMODS" ] && printf '%s\n' $AMDMODS > /etc/modules-load.d/sckoc-amd.conf || :
fi

%postun
if [ "$1" = 0 ]; then rm -f /etc/modules-load.d/sckoc-amd.conf; fi

%files
%license COPYING
%doc README.md
%{_bindir}/sckoc
%{_libexecdir}/%{name}/
%dir %{_datadir}/bash-completion
%dir %{_datadir}/bash-completion/completions
%{_datadir}/bash-completion/completions/sckoc
%{_mandir}/man1/sckoc.1*
%{_prefix}/lib/modules-load.d/sckoc.conf
%ghost %{_sysconfdir}/modules-load.d/sckoc-amd.conf

%changelog
* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.7-1
- info: BMC-substituted DIMM rows also show each module's current
  temperature, read per sensor via raw Get Sensor Reading with the same
  probe-once-then-cache mechanism as the CPU sensor; shown only where the
  slot names themselves come from the BMC, so the pairing is exact

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.6-1
- info: when the SMBIOS DIMM locators carry no information (all identical)
  and the count matches the BMC's populated DIMM temperature sensors, the
  real slot names are shown instead, labelled (bmc) - e.g. DIMMC1/DIMMF1
  on boards that label every slot "DIMM 0"; boards with proper locators
  are untouched, and a count mismatch falls back to the #N numbering

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.5-1
- mon (AMD): rework the BMC path for slow KCS interfaces - the one-off SDR
  probe now gets 20s (BMCPROBET) and a timeout is retried next tick instead
  of being negative-cached (only a truly absent BMC is remembered); cached
  refreshes send one raw Get Sensor Reading by sensor id (a single IPMI
  message, validated against the SDR at probe time) instead of "sdr get",
  which rescans the whole SDR; the cache moved to /run/sckoc-bmc so hosts
  locked out by the old negative cache recover on upgrade

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.4-1
- mon (AMD): BMC temperature fallback - where k10temp/SMU cannot cover the
  CPU, a responding BMC is read over the IPMI side-band via ipmitool
  (sensor names probed once per boot and cached to /run; refreshes read a
  single sensor; values labelled (bmc)); ipmitool is a new weak dependency
- info: repeated SMBIOS DIMM locators get a #N suffix so boards that label
  every slot "DIMM 0" still show distinguishable per-DIMM rows

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.3-1
- mon/vid (AMD): P-state fallback readings are now labelled VID, matching
  the Intel convention (Vcore = measured rail voltage, VID = nominal /
  requested value); board-sensor and SMU SVI3 paths keep the Vcore label

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.2-1
- mon/--json (AMD): when the package energy counter (0xC001029B) does not
  advance between the two samples, report Pkg N/A with an HSMP hint (and
  pkg_w:null in JSON) instead of a misleading "Pkg 0.0 W"; fall back to
  HSMP ReadSocketPower (0x04) when available. Seen on Threadripper PRO
  9955WX where the package counter stays 0 while per-core counters advance

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.1-1
- build: compile the C helpers with -std=gnu99 everywhere (Makefile,
  install.sh, build-deb, tests) - EL7's gcc 4.8 defaults to gnu90 and
  rejects the C99 for-loop declarations, which broke the script install
  on CentOS 7.9

* Sun Jul 19 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.0-1
- completion: the dump register table catches up with the 2.6.0 decoders
  (Intel 0x1AE turbo core-count thresholds and 0x614 PKG_POWER_INFO; AMD
  P1/P2 at 0xC0010065/0xC0010066)
- info: a single populated turbo bin prints its ratio bare (48x), the
  binN / <=NC labels only appear with multiple bins
- help: --json invocation examples; README and man aligned with the full
  static platform report wording

* Sun Jul 19 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.6.0-1
- info: grow into a full static platform report - CPU identity with the
  configured ratio ceilings (base/max-efficiency/min) and programmable
  flags from 0xCE, turbo ratio limit bins (0x1AD/0x1AE), thermal config
  (TjMax and TCC/PROCHOT offset), RAPL power limits with time windows and
  the package power envelope (0x614 TDP/min/max), per-DIMM memory config
  and cache topology; MSR blocks degrade individually without the module

* Sat Jul 18 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.5.0-1
- rename: the 'vcore' subcommand is now 'vid' (the Intel reading is the
  0x198 request voltage, not a measured Vcore); 'vcore' stays as a
  deprecated alias, completion lists only 'vid'
- new 'sckoc info' command: platform configuration (Secure Boot, lockdown,
  OC Lock, HT/SMT, NUMA, SMU FW) plus the RAPL PL1/PL2 power limits;
  works without the msr module (MSR-sourced items omitted)
- monitor panel slimmed to key live data: the Platform line and the
  PL1/PL2 row moved to 'sckoc info'; base clock moved onto the CPU block
  line; board voltage rails stay on the monitor (live data)
- vid output header and the AMD fallback message are English now; help
  regrouped into Overview/Detail/Maintenance sections
- --json schemas unchanged (sckoc-mon-v1 / sckoc-uncore-v1)
- docs: Chinese README no longer calls the Intel 0x198 reading a measured
  voltage; READMEs, man page and completion updated for vid/info
- tests: rename/alias/info/panel-layout coverage added

* Fri Jul 17 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.3.0-1
- readoc: batch protocol (-p CPU list plus comma-separated registers; one
  "<cpu> <reg> <value>" line per readable pair) - the monitor now samples
  all counters for all CPUs in a handful of readoc calls instead of one
  process per core per register
- monitor: single shared sampling window (one sleep total, previously one
  per socket plus one for the per-core table)
- new --json output (schemas sckoc-mon-v1 and sckoc-uncore-v1) on mon and
  uncore for scripting and collectors
- per-core rows within 10 C of TjMax are flagged with an exclamation mark
- sckoc uncore no longer requires the msr module when the
  intel-uncore-frequency sysfs driver is present
- add tests/ regression suite and run it in CI

* Fri Jul 17 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.2.1-1
- drop obsolete pre-rename file names from the install/uninstall paths;
  rdmsr is no longer removed, so a co-installed msr-tools stays intact
- remove the retired packaging/fetch-el10.sh helper (the release workflow
  builds el10 in a Rocky Linux 10 container)

* Fri Jul 17 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.2.0-1
- new 'sckoc uncore' subcommand: per-domain uncore/mesh frequency limits,
  on sysfs incl. BIOS boot values (initial_*_freq_khz) with runtime-change flag
- relabel Intel per-core voltage as VID request (0x198 regulator target,
  load-line droop not included)
- CI: review SRPM now embeds the original GitHub tag tarball (spectool),
  so its Source0 checksum matches upstream exactly

* Sat Jul 11 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.1.1-1
- add SPDX license identifiers to all remaining source and packaging files
- reword Fedora spec description to avoid rpmlint spell-checker false positives

* Sat Jul 11 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.1.0-1
- add tpmi-uncore helper: read-only TPMI MMIO fallback for mesh/IOD frequency
  on TPMI-era Xeon (Granite Rapids+) with pre-6.5 kernels (values marked (tpmi))
- add ryzen_smu PM-table fallback on consumer Ryzen / old kernels: socket and
  per-CCD temperature, FCLK/MCLK, PPT, SVI3 rail voltages (values marked (smu))
- vendor-aware SMT label: Intel platforms now show HT, AMD platforms show SMT
- bash completion: vendor-filtered MSR register list, case-insensitive hex
  matching, bitfield (hi:lo) completion for dump
- uninstall hardening: full leftover verification, COPR repo file fallback
  cleanup, third-party ryzen_smu guidance

* Fri Jul 10 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.0.0-3
- add sckoc(1) man page
- add SPDX license identifiers to all source files

* Thu Jul 09 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.0.0-2
- fix: /usr/bin/sckoc was the compiled readoc ELF, not the monitor script
  (the build step compiled readoc.c to a file literally named 'sckoc',
  clobbering the script before install)
- fix: ship the MSR helper as libexec/sckoc/readoc; it was installed as
  libexec/sckoc/sckoc, a path the monitor script never looks at
- build via make with distro flags (set_build_flags); hsmp-msg now hardened too
- add packaging/sckoc.modules-load (referenced but missing from the 2.0.0 tag,
  which broke rpmbuild and build-deb.sh on tag checkouts)
- Source0 now points at the GitHub tag archive so COPR (rpkg) and local
  builds use identical sources; use autosetup
- own /etc/modules-load.d/sckoc-amd.conf as ghost; Requires(post): kmod
- smoke tests in check guard the script/binary roles
- real URL and maintainer address (were GITHUB_USER / example.com)

* Tue Jul 07 2026 SkyWalkerAMD <scka7t@gmail.com> - 2.0.0-1
- rename project to sckoc (was msr-sck); MSR reader binary is now 'readoc'
- 100%% original code

* Tue Jul 07 2026 SkyWalkerAMD <scka7t@gmail.com> - 1.2.0-1
- replace the MSR reader with an original implementation (sckoc); the package is now 100%% original code
- drop the derived rdmsr.c from intel/msr-tools

* Tue Jul 07 2026 SkyWalkerAMD <scka7t@gmail.com> - 1.1.3-1
- replace COPYING with standard GPLv2 text (fix incorrect-fsf-address for Fedora review)

* Tue Jul 07 2026 SkyWalkerAMD <you@example.com> - 1.1.2-1
- fix: 'local' used outside a function in the vcore command dispatch (harmless stderr warning on AMD, now clean)

* Tue Jul 07 2026 SkyWalkerAMD <you@example.com> - 1.1.1-1
- add setup.sh one-line repo bootstrap (curl | sudo bash) for easier dnf/apt install
- make-apt-repo ships setup.sh to the pages site

* Tue Jul 07 2026 SkyWalkerAMD <you@example.com> - 1.1.0-1
- AMD Vcore: real dual-rail readout on ASUS WRX90E-SAGE via nct6798 (VDDCR_CPU0=in0, VDDCR_CPU1=in6), verified by BIOS override delta test
- AMD per-core: fix CCD numbering (L3-id step normalization, fam26 now 0..11) and Tctl fallback when k10temp lacks per-CCD
- installer auto-provisions k10temp + HSMP (DKMS hsmp_acpi) + board sensor drivers
- uninstall removes installer-provisioned DKMS (marker-based), all module configs
- bash completion: full subcommand + dump register + uninstall flag completion
- add 'help' subcommand with detailed usage and examples

* Mon Jul 06 2026 SkyWalkerAMD <you@example.com> - 1.0.4-1
- AMD per-core: fix CCD numbering (normalize L3-id step; fam26 was showing 0,2,4..22 -> now 0..11)
- AMD per-core: CCD-Temp falls back to socket Tctl (marked *) when k10temp lacks per-CCD sensors (fam26 on kernel 6.8)
- AMD Vcore: fam26 P-state VID labeled 'nominal, not rail V' (dual-rail BIOS voltage is not exposed via MSR)

* Mon Jul 06 2026 SkyWalkerAMD <you@example.com> - 1.0.3-1
- uninstall: remove installer-provisioned DKMS amd_hsmp (marker-based; user-installed kept with hint)
- uninstall: clean all modules-load configs incl. amd/sensors; never hot-unload modules
- standalone uninstall.sh: same fixes

* Mon Jul 06 2026 SkyWalkerAMD <you@example.com> - 1.0.2-1
- AMD: Vcore readout via P-state VID decode (fam 1Ah verified on TR PRO 9995WX; fam 17h SVI2)
- AMD: per-CCD temperature column in per-core view (k10temp + L3 topology mapping)
- AMD: installer auto-configures k10temp and HSMP (in-tree amd_hsmp or DKMS hsmp_acpi), persists autoload
- installer: probe board sensor drivers (nct6775 etc.) for voltage rails
- hsmp autoload falls back to hsmp_acpi; apt repo Release file now carries checksums
- uninstall no longer hot-unloads the msr module (unload race with concurrent readers)

* Sun Jul 05 2026 SkyWalkerAMD <you@example.com> - 1.0.1-1
- Fix per-core power overestimation on high-core-count AMD (TSC-based window)
- Add sckoc uninstall subcommand, -V works without msr module

* Sat Jul 04 2026 SkyWalkerAMD <you@example.com> - 1.0.0-1
- Initial release

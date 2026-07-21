# SPDX-License-Identifier: GPL-2.0-only
Name:           sckoc
Version:        4.0.0
Release:        %autorelease
Summary:        Read-only hardware monitor for Intel and AMD servers

# All code is original to this project (monitor script, readoc, hsmp-msg)
License:        GPL-2.0-only
URL:            https://github.com/SkyWalkerAMD/sckoc
Source0:        %{url}/archive/refs/tags/%{version}/%{name}-%{version}.tar.gz

BuildRequires:  gcc
BuildRequires:  make

# runtime helpers invoked by the sckoc script
Requires:       dmidecode
Recommends:     ipmitool
# the script probes optional modules (amd_hsmp, intel-uncore-frequency) at runtime
Requires:       kmod

# architecture: MSR/HSMP interfaces are x86_64-only
ExclusiveArch:  x86_64

%description
sckoc is a read-only hardware monitor for Intel and AMD servers and
workstations. It reports per-socket and per-core voltage, temperature,
frequency (core, mesh, IOD and DRAM), power (RAPL, PL1/PL2, PPT), C-state
residency and platform security state. Being read-only it works under Secure
Boot and kernel lockdown (integrity).

The tool reads Model-Specific Registers via the kernel MSR interface and, on
AMD, queries the HSMP interface. Loading the required kernel modules and any
BIOS setup is left to the administrator and is intentionally not done by this
package.

%prep
%autosetup

%build
%set_build_flags
%make_build CC=gcc

%install
# /usr/bin/sckoc is the monitor SCRIPT; the compiled helpers live in libexec,
# which is the first place the script looks for them
install -D -p -m0755 sckoc    %{buildroot}%{_bindir}/sckoc
install -D -p -m0755 readoc   %{buildroot}%{_libexecdir}/%{name}/readoc
install -D -p -m0755 hsmp-msg %{buildroot}%{_libexecdir}/%{name}/hsmp-msg
install -D -p -m0755 tpmi-uncore %{buildroot}%{_libexecdir}/%{name}/tpmi-uncore
install -D -p -m0644 packaging/sckoc.completion \
        %{buildroot}%{_datadir}/bash-completion/completions/sckoc
install -D -p -m0644 packaging/sckoc.1 %{buildroot}%{_mandir}/man1/sckoc.1

%check
# smoke tests, no hardware access:
# the shipped /usr/bin/sckoc must be a parseable shell script (guards against
# ever again packaging a compiled binary under the script's name)
bash -n %{buildroot}%{_bindir}/sckoc
head -c2 %{buildroot}%{_bindir}/sckoc | grep -q '#!'
%{buildroot}%{_libexecdir}/%{name}/readoc -V
test -x %{buildroot}%{_libexecdir}/%{name}/hsmp-msg
test -x %{buildroot}%{_libexecdir}/%{name}/tpmi-uncore

%postun
# runtime BMC sensor caches under /run (tmpfs); removed on final erase
if [ $1 -eq 0 ]; then rm -f /run/sckoc-*; fi

%files
%license COPYING
%doc README.md
%{_bindir}/sckoc
%{_libexecdir}/%{name}/
%dir %{_datadir}/bash-completion
%dir %{_datadir}/bash-completion/completions
%{_datadir}/bash-completion/completions/sckoc
%{_mandir}/man1/sckoc.1*

%changelog
* Tue Jul 21 2026 SkyWalkerAMD <scka7t@gmail.com> - 4.0.0-1
- info: DIMM temperatures now match bare-channel SMBIOS locators
  (CPU0_DIMM_B <-> the BMC's DIMMB1 sensor, W890E SAGE SE style)
- info: the DRAM rail is also recognised under the VCCD sensor naming
  (Intel DDR5 memory VDD); one reading per memory-controller rail,
  joined with a slash, VDDQ column width follows the value
- tpmi-uncore: the PFS directory scan is now bounded against the BAR size
  (a bogus table offset degrades to no data instead of a crash)
- hsmp-msg: argument count clamped to the 8-word message limit
- tests: BMC probes are confined to the suite's tempdir; running the suite
  on a host with ipmitool installed no longer leaves caches under /run

* Tue Jul 21 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.2.0-1
- readoc: reject register numbers above 32 bits and malformed -f bitfields;
  a READOC_DEV pattern other than a fixed path or a single %%d now falls
  back to the default device instead of reaching snprintf as an arbitrary
  format string
- ci: the regression suite runs on every push; package builds, the Release
  upload and the apt repository publish only after tests pass (the apt repo
  previously published even when tests failed); release runs are
  single-flight; missing release assets now fail the upload


* Tue Jul 21 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.1.0-1
- info: per-DIMM memory reworked as a column table (Speed / JEDEC / VDDQ /
  Size, plus Temp when the BMC exposes DIMM sensors), mirroring the per-core
  panel; Speed is the actual configured rate, JEDEC the SMBIOS nominal
- info: measured DRAM VDDQ rail read from the BMC over ipmitool (new column)
- mon: DRAM line is rate-only now - the SMBIOS nominal voltage (JEDEC 1.1 V,
  never the real rail) was dropped
- output: BMC source labels "(bmc)" removed from the panels
- tests: temperature assertions made locale-proof (fixes CI under C.UTF-8)

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.12-1
- mon: the per-socket DRAM line now shows Mem Max, the hottest populated DIMM
  temperature from the BMC (parallels the CPU Temp Max), labelled (bmc)
- install: try to install ipmitool alongside dmidecode (best-effort, never
  fails the install) so the BMC temperature path works out of the box

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.11-1
- info: show per-DIMM temperature whenever the BMC exposes DIMM sensors, not
  only on boards with blank SMBIOS locators. With meaningful locators the
  SMBIOS slot name is kept and the BMC temperature is matched by slot
  designator (DIMMA1 <-> CPU0_DIMM_A1) and appended, labelled (bmc); the
  name-substitution path for all-identical locators is unchanged. Boards
  whose BMC has no DIMM sensors are untouched

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.10-1
- mon: add an IRQ column to the per-core table - interrupts serviced by each
  core during the sampling window, summed across all sources in
  /proc/interrupts (and across SMT threads) over the same T0/T1 window as the
  other counters. Read-only, no driver needed; IRQSRC overrides the source

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.9-1
- completion: keep the dump register completion working on old bash (EL7 is
  4.2) - the case-insensitive match no longer uses the bash 4.0 ${var,,}
  expansion, using tr + a case glob and an explicit array instead
- install: when the bash-completion package is not detected, say so and
  point at "source /etc/bash_completion.d/sckoc" for the current shell

* Mon Jul 20 2026 SkyWalkerAMD <scka7t@gmail.com> - 3.0.8-1
- mon/info (AMD BMC): fix the per-DIMM temperature path - the SDR sensor
  name is kept in full for the "sdr get" fallback (stripping _Temp only for
  display; a demoted DIMM sensor previously became unreadable), and the raw
  vs SDR probe check now allows a 5C drift instead of exact equality so a
  sensor is not wrongly pinned to the slow per-tick path

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

%autochangelog

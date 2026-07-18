# SPDX-License-Identifier: GPL-2.0-only
Name:           sckoc
Version:        3.0.0
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

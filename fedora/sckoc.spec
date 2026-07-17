# SPDX-License-Identifier: GPL-2.0-only
Name:           sckoc
Version:        2.2.1
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
%autochangelog

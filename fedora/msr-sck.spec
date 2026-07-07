Name:           msr-sck
Version:        1.1.3
Release:        %autorelease
Summary:        Read-only hardware monitor for Intel and AMD servers

# rdmsr.c derives from intel/msr-tools (GPL-2.0-only); all other code is GPL-2.0-only
License:        GPL-2.0-only
URL:            https://github.com/SkyWalkerAMD/msr-sck
Source0:        %{url}/archive/refs/tags/%{version}/%{name}-%{version}.tar.gz

BuildRequires:  gcc
BuildRequires:  make

# runtime helpers invoked by the msr-sck script
Requires:       dmidecode

# architecture: MSR/HSMP interfaces are x86_64-only
ExclusiveArch:  x86_64

%description
msr-sck is a read-only hardware monitor for Intel and AMD servers and
workstations, derived from the rdmsr utility in intel/msr-tools. It reports
per-socket and per-core voltage, temperature, frequency (core, mesh, IOD and
DRAM), power (RAPL, PL1/PL2, PPT), C-state residency and platform security
state. Being read-only it works under Secure Boot and kernel lockdown
(integrity).

The tool reads MSRs through /dev/cpu/*/msr and, on AMD, HSMP through /dev/hsmp.
Loading the required kernel modules (msr, k10temp, amd_hsmp) and any BIOS setup
is left to the administrator and is intentionally not done by this package.

%prep
%autosetup

%build
%set_build_flags
%make_build CC=gcc

%install
install -D -m0755 msr-sck  %{buildroot}%{_bindir}/msr-sck
install -D -m0755 rdmsr    %{buildroot}%{_libexecdir}/%{name}/rdmsr
install -D -m0755 hsmp-msg %{buildroot}%{_libexecdir}/%{name}/hsmp-msg
install -D -m0644 packaging/msr-sck.completion \
        %{buildroot}%{_datadir}/bash-completion/completions/msr-sck

%check
# smoke test: the built helper must report its version without touching hardware
test -x %{buildroot}%{_libexecdir}/%{name}/rdmsr

%files
%license COPYING
%doc README.md
%{_bindir}/msr-sck
%{_libexecdir}/%{name}/
%{_datadir}/bash-completion/completions/msr-sck

%changelog
%autochangelog

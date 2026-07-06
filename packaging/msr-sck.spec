Name:           msr-sck
Version:        1.0.1
Release:        1%{?dist}
Summary:        Read-only hardware monitor for Intel/AMD servers (rdmsr-based)
License:        GPL-2.0-only
URL:            https://github.com/GITHUB_USER/msr-sck
Source0:        %{name}-%{version}.tar.gz
BuildRequires:  gcc
Requires:       dmidecode
Requires:       kmod

%description
msr-sck is a read-only hardware monitor for Intel and AMD servers and
workstations, derived from intel/msr-tools rdmsr. It reports per-socket and
per-core voltage, temperature, frequency (core/mesh/IOD/DRAM), power (RAPL,
PL1/PL2, PPT), C-state residency and platform security state, and works under
Secure Boot / kernel lockdown (integrity).

%prep
%setup -q

%build
gcc %{optflags} -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I. rdmsr.c -o rdmsr
gcc %{optflags} hsmp-msg.c -o hsmp-msg

%install
install -D -m755 msr-sck  %{buildroot}%{_bindir}/msr-sck
install -D -m755 rdmsr    %{buildroot}%{_libexecdir}/msr-sck/rdmsr
install -D -m755 hsmp-msg %{buildroot}%{_libexecdir}/msr-sck/hsmp-msg
install -D -m644 packaging/msr-sck.completion %{buildroot}%{_datadir}/bash-completion/completions/msr-sck
install -D -m644 packaging/msr-sck.modules-load %{buildroot}%{_prefix}/lib/modules-load.d/msr-sck.conf

%post
modprobe msr 2>/dev/null || :

%files
%license COPYING
%doc README.md
%{_bindir}/msr-sck
%{_libexecdir}/msr-sck/
%{_datadir}/bash-completion/completions/msr-sck
%{_prefix}/lib/modules-load.d/msr-sck.conf

%changelog
* Sun Jul 05 2026 SkyWalkerAMD <you@example.com> - 1.0.1-1
- Fix per-core power overestimation on high-core-count AMD (TSC-based window)
- Add msr-sck uninstall subcommand, -V works without msr module

* Sat Jul 04 2026 SkyWalkerAMD <you@example.com> - 1.0.0-1
- Initial release

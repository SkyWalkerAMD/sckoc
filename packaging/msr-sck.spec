Name:           msr-sck
Version:        1.0.3
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
if grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null; then
  AMDMODS=""
  modprobe k10temp 2>/dev/null && AMDMODS="k10temp" || :
  [ -e /dev/hsmp ] || modprobe amd_hsmp 2>/dev/null || modprobe hsmp_acpi 2>/dev/null || :
  H=$(lsmod | awk '$1=="amd_hsmp"||$1=="hsmp_acpi"{print $1;exit}')
  [ -n "$H" ] && AMDMODS="$AMDMODS $H"
  [ -n "$AMDMODS" ] && printf '%s\n' $AMDMODS > /etc/modules-load.d/msr-sck-amd.conf || :
fi

%postun
if [ "$1" = 0 ]; then rm -f /etc/modules-load.d/msr-sck-amd.conf; fi

%files
%license COPYING
%doc README.md
%{_bindir}/msr-sck
%{_libexecdir}/msr-sck/
%{_datadir}/bash-completion/completions/msr-sck
%{_prefix}/lib/modules-load.d/msr-sck.conf

%changelog
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
- Add msr-sck uninstall subcommand, -V works without msr module

* Sat Jul 04 2026 SkyWalkerAMD <you@example.com> - 1.0.0-1
- Initial release

Name:           msr-sck
Version:        1.1.3
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
- Add msr-sck uninstall subcommand, -V works without msr module

* Sat Jul 04 2026 SkyWalkerAMD <you@example.com> - 1.0.0-1
- Initial release

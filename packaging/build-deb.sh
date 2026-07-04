#!/bin/bash
# build msr-sck .deb — run from repo root: bash packaging/build-deb.sh
set -e
V=1.0.0; R=1; A=$(dpkg --print-architecture)
D=$(mktemp -d)
gcc -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I. rdmsr.c -o "$D/rdmsr"
gcc -Wall -O2 hsmp-msg.c -o "$D/hsmp-msg"
P="$D/pkg"
install -D -m755 msr-sck        "$P/usr/bin/msr-sck"
install -D -m755 "$D/rdmsr"     "$P/usr/libexec/msr-sck/rdmsr"
install -D -m755 "$D/hsmp-msg"  "$P/usr/libexec/msr-sck/hsmp-msg"
install -D -m644 packaging/msr-sck.completion "$P/usr/share/bash-completion/completions/msr-sck"
install -D -m644 packaging/msr-sck.modules-load "$P/usr/lib/modules-load.d/msr-sck.conf"
install -D -m644 COPYING "$P/usr/share/doc/msr-sck/copyright"
install -D -m644 README.md "$P/usr/share/doc/msr-sck/README.md"
mkdir -p "$P/DEBIAN"
cat > "$P/DEBIAN/control" <<CTL
Package: msr-sck
Version: $V-$R
Architecture: $A
Maintainer: SkyWalkerAMD <you@example.com>
Depends: kmod
Recommends: dmidecode
Section: utils
Priority: optional
Homepage: https://github.com/GITHUB_USER/msr-sck
Description: Read-only hardware monitor for Intel/AMD servers
 Reports per-socket and per-core voltage, temperature, frequency
 (core/mesh/IOD/DRAM), power (RAPL, PL1/PL2, PPT), C-state residency and
 platform security state. Works under Secure Boot / lockdown (integrity).
 Derived from intel/msr-tools rdmsr.
CTL
cat > "$P/DEBIAN/postinst" <<'PI'
#!/bin/sh
modprobe msr 2>/dev/null || :
exit 0
PI
chmod 755 "$P/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$P" "msr-sck_${V}-${R}_${A}.deb"
rm -rf "$D"
echo "built: msr-sck_${V}-${R}_${A}.deb"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build sckoc .deb — run from repo root: bash packaging/build-deb.sh
set -e
V=3.0.7; R=1; A=$(dpkg --print-architecture 2>/dev/null || echo amd64)
D=$(mktemp -d)
# helpers are compiled under their real names; /usr/bin/sckoc is the SCRIPT
gcc -std=gnu99 -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I. readoc.c -o "$D/readoc"
gcc -std=gnu99 -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 hsmp-msg.c -o "$D/hsmp-msg"
gcc -std=gnu99 -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 tpmi-uncore.c -o "$D/tpmi-uncore"
P="$D/pkg"
install -D -m755 sckoc          "$P/usr/bin/sckoc"
install -D -m755 "$D/readoc"    "$P/usr/libexec/sckoc/readoc"
install -D -m755 "$D/hsmp-msg"  "$P/usr/libexec/sckoc/hsmp-msg"
install -D -m755 "$D/tpmi-uncore" "$P/usr/libexec/sckoc/tpmi-uncore"
install -D -m644 packaging/sckoc.completion "$P/usr/share/bash-completion/completions/sckoc"
install -D -m644 packaging/sckoc.modules-load "$P/usr/lib/modules-load.d/sckoc.conf"
install -D -m644 packaging/sckoc.1 "$P/usr/share/man/man1/sckoc.1"
gzip -9n "$P/usr/share/man/man1/sckoc.1"
install -D -m644 COPYING "$P/usr/share/doc/sckoc/copyright"
install -D -m644 README.md "$P/usr/share/doc/sckoc/README.md"
mkdir -p "$P/DEBIAN"
cat > "$P/DEBIAN/control" <<CTL
Package: sckoc
Version: $V-$R
Architecture: $A
Maintainer: SkyWalkerAMD <scka7t@gmail.com>
Depends: kmod
Recommends: dmidecode, ipmitool
Section: utils
Priority: optional
Homepage: https://github.com/SkyWalkerAMD/sckoc
Description: Read-only hardware monitor for Intel/AMD servers
 Reports per-socket and per-core voltage, temperature, frequency
 (core/mesh/IOD/DRAM), power (RAPL, PL1/PL2, PPT), C-state residency and
 platform security state. Works under Secure Boot / lockdown (integrity).
CTL
cat > "$P/DEBIAN/postinst" <<'PI'
#!/bin/sh
modprobe msr 2>/dev/null || :
if grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null; then
  AMDMODS=""
  modprobe k10temp 2>/dev/null && AMDMODS="k10temp" || :
  [ -e /dev/hsmp ] || modprobe amd_hsmp 2>/dev/null || modprobe hsmp_acpi 2>/dev/null || :
  H=$(lsmod | awk '$1=="amd_hsmp"||$1=="hsmp_acpi"{print $1;exit}')
  [ -n "$H" ] && AMDMODS="$AMDMODS $H"
  [ -n "$AMDMODS" ] && printf '%s\n' $AMDMODS > /etc/modules-load.d/sckoc-amd.conf || :
fi
exit 0
PI
chmod 755 "$P/DEBIAN/postinst"
cat > "$P/DEBIAN/postrm" <<'PR'
#!/bin/sh
if [ "$1" = remove ] || [ "$1" = purge ]; then rm -f /etc/modules-load.d/sckoc-amd.conf; fi
exit 0
PR
chmod 755 "$P/DEBIAN/postrm"
dpkg-deb --build --root-owner-group "$P" "sckoc_${V}-${R}_${A}.deb"
rm -rf "$D"
echo "built: sckoc_${V}-${R}_${A}.deb"

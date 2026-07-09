#!/bin/bash
# uninstall.sh: remove sckoc completely (script-, rpm- or deb-installed)
# usage: sudo bash uninstall.sh [--purge-deps]
set -e
[ "$(id -u)" = 0 ] || { echo "run as root / sudo"; exit 1; }

PURGE=0; [ "$1" = "--purge-deps" ] && PURGE=1

# 1) package-manager installs
if command -v rpm >/dev/null && rpm -q sckoc >/dev/null 2>&1; then
  echo "== removing rpm package =="
  { command -v dnf >/dev/null && dnf -y remove sckoc; } || { command -v yum >/dev/null && yum -y remove sckoc; } || rpm -e sckoc
fi
if command -v dpkg >/dev/null && dpkg -s sckoc >/dev/null 2>&1; then
  echo "== removing deb package =="
  { command -v apt-get >/dev/null && apt-get -y remove sckoc; } || dpkg -r sckoc
fi

# 2) script installs + legacy names
echo "== removing files =="
rm -f /usr/local/bin/sckoc /usr/local/bin/readoc /usr/local/bin/rdmsr /usr/local/bin/hsmp-msg \
      /usr/local/bin/msr /usr/local/bin/msr-w890e /usr/local/bin/msr-tr /usr/local/bin/hsmp-fclk \
      /etc/bash_completion.d/sckoc

# 3) module autoload config + unload (safe if other tools use msr: they can modprobe again)
rm -f /etc/modules-load.d/msr.conf /etc/modules-load.d/sckoc.conf \
      /etc/modules-load.d/sckoc-amd.conf /etc/modules-load.d/sckoc-sensors.conf \
      /usr/lib/modules-load.d/sckoc.conf
# note: modules stay loaded until reboot (hot-unload races with concurrent MSR readers)

# 3b) DKMS amd_hsmp: only if our installer set it up (marker file)
if [ -f /var/lib/sckoc/dkms-amd-hsmp ]; then
  HV=$(cat /var/lib/sckoc/dkms-amd-hsmp)
  dkms remove -m amd_hsmp -v "$HV" --all 2>/dev/null || true
  rm -rf "/usr/src/amd_hsmp-$HV"
  echo "== removed DKMS amd_hsmp $HV (installed by sckoc) =="
elif command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^amd_hsmp'; then
  echo "== note: DKMS amd_hsmp not installed by sckoc - kept =="
fi
rm -rf /var/lib/sckoc

# 4) repo configs we may have suggested
rm -f /etc/apt/sources.list.d/sckoc.list
if command -v dnf >/dev/null && dnf copr list 2>/dev/null | grep -q sckoc; then
  dnf -y copr remove skywalkeramd/sckoc 2>/dev/null || dnf -y copr disable skywalkeramd/sckoc 2>/dev/null || true
fi

# 5) optional dependency purge (dangerous: shared system packages)
if [ "$PURGE" = 1 ]; then
  echo "== WARNING: removing gcc/dmidecode - other software may depend on them =="
  { command -v dnf >/dev/null && dnf -y remove dmidecode gcc; } || \
  { command -v yum >/dev/null && yum -y remove dmidecode gcc; } || \
  { command -v apt-get >/dev/null && apt-get -y remove dmidecode gcc; } || true
fi

# 6) verify
LEFT=""
for f in /usr/local/bin/sckoc /usr/local/bin/readoc /usr/bin/sckoc /usr/local/bin/rdmsr /usr/libexec/sckoc; do
  [ -e "$f" ] && LEFT="$LEFT $f"
done
if [ -n "$LEFT" ]; then echo "== WARNING: leftovers:$LEFT =="; exit 1; fi
echo "== sckoc fully removed =="
[ "$PURGE" = 0 ] && echo "(shared deps gcc/dmidecode/dkms/git kept; rerun with --purge-deps for gcc/dmidecode)"
exit 0

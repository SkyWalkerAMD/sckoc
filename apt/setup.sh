#!/bin/sh
# sckoc repository setup - adds the right repo for your distro,
# then you can use the normal 'dnf install sckoc' or 'apt install sckoc'.
# Usage:  curl -fsSL https://skywalkeramd.github.io/sckoc/apt/setup.sh | sudo bash
set -e

COPR_OWNER=skywalkeramd
COPR_PROJECT=sckoc
APT_URL="https://skywalkeramd.github.io/sckoc/apt"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

. /etc/os-release 2>/dev/null || true

is_cmd(){ command -v "$1" >/dev/null 2>&1; }

if is_cmd dnf || is_cmd yum; then
    PM=$(is_cmd dnf && echo dnf || echo yum)
    echo "== detected RPM distro ($ID $VERSION_ID), using COPR =="
    # dnf copr needs the copr plugin; yum needs yum-plugin-copr
    if [ "$PM" = dnf ]; then
        $PM -y install 'dnf-command(copr)' 2>/dev/null || $PM -y install dnf-plugins-core
        $PM -y copr enable "$COPR_OWNER/$COPR_PROJECT"
    else
        $PM -y install yum-plugin-copr
        $PM -y copr enable "$COPR_OWNER/$COPR_PROJECT"
    fi
    echo "== done. now run:  $PM install sckoc =="

elif is_cmd apt-get; then
    echo "== detected Debian/Ubuntu ($ID $VERSION_ID), adding apt repo =="
    echo "deb [trusted=yes] $APT_URL stable main" > /etc/apt/sources.list.d/sckoc.list
    apt-get update
    echo "== done. now run:  apt install sckoc =="

else
    echo "no supported package manager found (need dnf/yum or apt)."
    echo "use the one-shot installer instead:"
    echo "  curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/install.sh | sudo bash"
    exit 1
fi

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# fetch-el10.sh — download the newest sckoc el10 rpm from COPR into the
# current directory (el10 is the one chroot the GitHub Actions release
# workflow does not build, so its Release asset is fetched from COPR).
#
# Usage:  bash fetch-el10.sh [chroot]     # default chroot: epel-10-x86_64
# Needs:  dnf-plugins-core (for `dnf download`)
set -euo pipefail

CHROOT="${1:-epel-10-x86_64}"
REPO="https://download.copr.fedorainfracloud.org/results/skywalkeramd/sckoc/$CHROOT/"

rm -f sckoc-*.rpm

echo ">> downloading newest sckoc from COPR $CHROOT ..."
dnf download sckoc --refresh \
  --repofrompath=tmp,"$REPO" \
  --repo=tmp --setopt=tmp.gpgcheck=0

RPM=$(ls -t sckoc-*.rpm 2>/dev/null | head -1)
[ -n "$RPM" ] || { echo "!! nothing downloaded"; exit 1; }
echo ">> downloaded: $RPM  ($(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$RPM" 2>/dev/null))"

# guard 1: /usr/bin/sckoc must be in the package (the 2.0.0 mispackaging bug)
rpm -qlp "$RPM" | grep '^/usr/bin/sckoc$' >/dev/null \
  || { echo "!! /usr/bin/sckoc missing from package - broken build, do not ship"; exit 1; }
# guard 2: man page must be present (added in 2.0.0-3; catches stale repo metadata)
rpm -qlp "$RPM" | grep 'man1/sckoc\.1' >/dev/null \
  || { echo "!! man page missing - COPR likely has not rebuilt yet or repo"; \
       echo "   metadata is stale; check the Builds page and re-run."; exit 1; }
echo ">> guards passed (script + man page present)"

echo ">> sha256 (compare with the Release page after upload):"
sha256sum "$RPM"
echo ">> done - upload $RPM to the GitHub Release assets."

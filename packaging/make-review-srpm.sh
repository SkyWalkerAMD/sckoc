#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# make-review-srpm.sh — regenerate the Fedora-review SRPM (+ matching
# sckoc.spec copy) for a released tag, inside a Fedora container.
#
# Usage:   bash make-review-srpm.sh [tag]      # tag defaults to 3.0.7
# Needs:   curl, podman
# Output:  ~/review-srpm/sckoc.spec  and  ~/review-srpm/sckoc-<V>-1.fc<NN>.src.rpm
#          (filenames match the Spec/SRPM URLs posted on the review ticket)
#
# Speed tip: the container installs rpmdevtools+rpmautospec on every run.
# To make runs near-instant, bake them into a local image once:
#   podman run --name t registry.fedoraproject.org/fedora:44 \
#       dnf install -y rpmdevtools rpmautospec
#   podman commit t localhost/srpm-f44 && podman rm t
# then run with:  SRPM_IMAGE=localhost/srpm-f44 bash make-review-srpm.sh
# (the in-container install is skipped automatically when tools exist)
set -euo pipefail

TAG="${1:-3.0.7}"
SRPM_IMAGE="${SRPM_IMAGE:-registry.fedoraproject.org/fedora:44}"
WORK=~/review-srpm
TARBALL="sckoc-$TAG.tar.gz"

mkdir -p "$WORK"; cd "$WORK"
rm -rf "sckoc-$TAG" sckoc.spec sckoc-*.src.rpm   # clean products, keep tarball

# ---- 1. get the tag tarball ----------------------------------------
# reuse an existing file only if it is a valid gzip (a Ctrl-C can leave
# a truncated download behind); otherwise try GitHub, then a mirror with
# a cache-busting query string (mirrors may cache a previous cut of the
# same tag).
if [ -s "$TARBALL" ] && tar tzf "$TARBALL" >/dev/null 2>&1; then
  echo ">> reusing existing $WORK/$TARBALL"
else
  rm -f "$TARBALL"; ok=""
  for u in \
    "https://github.com/SkyWalkerAMD/sckoc/archive/refs/tags/$TAG/sckoc-$TAG.tar.gz" \
    "https://ghfast.top/https://github.com/SkyWalkerAMD/sckoc/archive/refs/tags/$TAG/sckoc-$TAG.tar.gz?t=$(date +%s)"
  do
    echo ">> trying: $u"
    if curl -fL --connect-timeout 10 --max-time 60 --retry 1 -o "$TARBALL" "$u" \
       && tar tzf "$TARBALL" >/dev/null 2>&1; then ok=1; break; fi
    rm -f "$TARBALL"
  done
  [ -n "$ok" ] || { echo "!! all download sources failed or returned a broken file."
                    echo "   Download 'Source code (tar.gz)' from the GitHub Release page"
                    echo "   in a browser, place it at $WORK/$TARBALL, and re-run."; exit 1; }
fi

# ---- 2. guards: the tag must be the FIXED content -------------------
tar tzf "$TARBALL" | grep "^sckoc-$TAG/packaging/sckoc.1\$" >/dev/null \
  || { echo "!! packaging/sckoc.1 missing from the tag - was the tag re-cut"; \
       echo "   before the files were uploaded to main?"; exit 1; }
tar xzf "$TARBALL"
grep "SPDX-License-Identifier" "sckoc-$TAG/sckoc" >/dev/null \
  || { echo "!! SPDX header missing from the sckoc script - wrong tag content"; exit 1; }
if grep -E "Temple Place|Mass Ave" "sckoc-$TAG/COPYING" >/dev/null; then
  echo "!! COPYING still carries the old FSF postal address - wrong tag content"; exit 1
fi
echo ">> tag content verified (man page + SPDX + current COPYING)"

# ---- 3. build the SRPM in the container (non-interactive) -----------
podman run --rm -e TAG="$TAG" -v "$PWD":/src:Z "$SRPM_IMAGE" bash -ec '
  rpm -q rpmdevtools rpmautospec >/dev/null 2>&1 \
    || dnf install -y -q rpmdevtools rpmautospec
  mkdir -p /root/rpmbuild/SOURCES
  cp "/src/sckoc-$TAG.tar.gz" /root/rpmbuild/SOURCES/
  rpmbuild -bs "/src/sckoc-$TAG/fedora/sckoc.spec"
  cp /root/rpmbuild/SRPMS/sckoc-*.src.rpm /src/
'

# ---- 4. lay out the two deliverables + checksums ---------------------
cp "sckoc-$TAG/fedora/sckoc.spec" sckoc.spec
SRPM=$(ls sckoc-*.src.rpm | head -1)
echo
echo ">> done - deliverables in $WORK/ :"
sha256sum sckoc.spec "$SRPM"
echo
echo ">> upload both to the GitHub Release assets; the filenames match the"
echo "   Spec/SRPM URLs already posted on the Bugzilla ticket."

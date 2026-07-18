#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# make-srpm.sh - fetch a released tag from GitHub and build its SRPM for COPR.
# Works on any RPM distro (Rocky/RHEL/Fedora/AlmaLinux) with rpm-build installed.
#
# Usage:
#   ./make-srpm.sh 3.0.0
#   ./make-srpm.sh            # defaults to the latest tag (GitHub API, jsDelivr fallback)
#
# After it finishes, upload the printed .src.rpm to COPR:
#   COPR project -> Builds -> New Build -> Upload -> select the file -> Submit
#   (remember to tick ALL chroots: epel-8/9/10, fedora-*, amazonlinux)
# or with copr-cli:
#   copr-cli build skywalkeramd/sckoc <path-to-srpm>

set -e

REPO="SkyWalkerAMD/sckoc"
NAME="sckoc"
RPMTOP="$HOME/rpmbuild"

# --- resolve version -------------------------------------------------
VER="$1"
if [ -z "$VER" ]; then
    echo "== no version given, querying latest release tag =="
    VER=$(curl -fsSL --retry 2 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
          | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') || true
    if [ -z "$VER" ]; then
        echo "== github api unreachable, trying jsDelivr =="
        VER=$(curl -fsSL --retry 2 "https://data.jsdelivr.com/v1/packages/gh/$REPO/resolved" 2>/dev/null \
              | grep -oE '"version": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/') || true
    fi
    [ -n "$VER" ] || { echo "could not determine latest tag; pass it explicitly: $0 3.0.0"; exit 1; }
    echo "== latest tag is $VER =="
fi

TARBALL="$RPMTOP/SOURCES/$NAME-$VER.tar.gz"
SPEC="$RPMTOP/SPECS/$NAME.spec"

# --- prerequisites ---------------------------------------------------
command -v rpmbuild >/dev/null || {
    echo "rpmbuild not found. install it first:"
    echo "  sudo dnf install -y rpm-build"
    exit 1
}
mkdir -p "$RPMTOP/SOURCES" "$RPMTOP/SPECS" "$RPMTOP/SRPMS"

# --- clean any stale artifacts for this version ----------------------
rm -f "$TARBALL" "$SPEC" "$RPMTOP/SRPMS/$NAME-$VER"-*.src.rpm
rm -rf "/tmp/$NAME-$VER"

# --- download the released source tarball ----------------------------
# (same content as Source0: .../archive/refs/tags/VER/NAME-VER.tar.gz;
#  saved under the Source0 basename so rpmbuild finds it)
echo "== downloading tag $VER =="
DL_OK=""
for URL in \
    "https://github.com/$REPO/archive/refs/tags/$VER.tar.gz" \
    "https://ghfast.top/https://github.com/$REPO/archive/refs/tags/$VER.tar.gz?t=$(date +%s)"
do
    echo "   trying: $URL"
    if curl -fL --connect-timeout 10 --max-time 120 --retry 1 -o "$TARBALL" "$URL" \
       && tar tzf "$TARBALL" >/dev/null 2>&1; then DL_OK=1; break; fi
    rm -f "$TARBALL"
done
[ -n "$DL_OK" ] || { echo "ERROR: could not download a valid tarball from any source."; exit 1; }

SZ=$(stat -c%s "$TARBALL")
if [ "$SZ" -lt 10000 ]; then
    echo "ERROR: downloaded file is only $SZ bytes - the tag probably does not"
    echo "       exist yet on GitHub. Check https://github.com/$REPO/tags"
    exit 1
fi
echo "== tarball OK ($SZ bytes) =="

# --- guard: the tag must contain the FIXED packaging files ------------
# packaging/sckoc.modules-load only exists after the 2.0.0 tag was re-cut
# with the packaging fixes; an old/stale tag would build a broken package.
if ! tar tzf "$TARBALL" | grep "^$NAME-$VER/packaging/$NAME.modules-load\$" >/dev/null; then
    echo "ERROR: this tag still has the OLD (broken) content -"
    echo "       packaging/$NAME.modules-load is missing from the tarball."
    echo "       Re-cut the $VER tag from the fixed main branch first,"
    echo "       then run this script again."
    exit 1
fi
# packaging/sckoc.1 is installed by the spec since 2.0.0-3; an older tag
# without it would fail every COPR chroot build.
if ! tar tzf "$TARBALL" | grep "^$NAME-$VER/packaging/$NAME.1\$" >/dev/null; then
    echo "ERROR: packaging/$NAME.1 (man page) is missing from the tarball;"
    echo "       the tag predates the 2.0.0-3 packaging - re-cut it first."
    exit 1
fi

# --- extract the spec that ships inside the tag (always in sync) ------
tar xzf "$TARBALL" -C /tmp "$NAME-$VER/packaging/$NAME.spec"
cp "/tmp/$NAME-$VER/packaging/$NAME.spec" "$SPEC"
SPECVER=$(grep -m1 '^Version:' "$SPEC" | awk '{print $2}')
echo "== spec version: $SPECVER =="
if [ "$SPECVER" != "$VER" ]; then
    echo "ERROR: spec Version ($SPECVER) != requested tag ($VER)."
    echo "       The tag content and the spec are out of sync; fix the repo first."
    exit 1
fi

# --- build the SRPM --------------------------------------------------
rpmbuild --define "_topdir $RPMTOP" -bs "$SPEC"

SRPM=$(ls -t "$RPMTOP/SRPMS/$NAME-$VER"-*.src.rpm 2>/dev/null | head -1)
echo
echo "======================================================"
echo " SRPM ready:"
echo "   $SRPM"
echo
echo " Next: upload it to COPR (tick ALL chroots)"
echo "   web:  Builds -> New Build -> Upload -> select the file"
echo "   cli:  copr-cli build skywalkeramd/$NAME \"$SRPM\""
echo
echo " After COPR finishes, fetch a binary rpm to verify:"
echo "   click the build -> chroot row (e.g. epel-8-x86_64) -> results dir"
echo "   or on a machine with the repo enabled:  dnf download $NAME --refresh"
echo "   then:  rpm -qlp $NAME-*.rpm   # must list /usr/bin/sckoc + libexec files"
echo "======================================================"

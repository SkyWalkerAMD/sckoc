#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build a flat apt repo under ./apt-repo from *.deb in cwd
set -e
mkdir -p apt-repo/pool apt-repo/dists/stable/main/binary-amd64
cp ./*.deb apt-repo/pool/
cd apt-repo
dpkg-scanpackages --arch amd64 pool /dev/null > dists/stable/main/binary-amd64/Packages
gzip -9c dists/stable/main/binary-amd64/Packages > dists/stable/main/binary-amd64/Packages.gz
if command -v apt-ftparchive >/dev/null 2>&1; then
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=sckoc \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    release dists/stable > /tmp/Release.tmp
  mv /tmp/Release.tmp dists/stable/Release
else
  # fallback for RPM hosts (Rocky/RHEL + EPEL dpkg-dev): hand-roll the Release file
  (
    cd dists/stable
    echo "Origin: sckoc"
    echo "Suite: stable"
    echo "Codename: stable"
    echo "Architectures: amd64"
    echo "Components: main"
    echo "Date: $(date -Ru)"
    echo "MD5Sum:"
    for f in main/binary-amd64/Packages main/binary-amd64/Packages.gz; do
      printf ' %s %16d %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
    done
    echo "SHA256:"
    for f in main/binary-amd64/Packages main/binary-amd64/Packages.gz; do
      printf ' %s %16d %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
    done
  ) > dists/stable/Release
fi
# ship the one-line repo setup script alongside the apt repo
[ -f ../packaging/setup.sh ] && cp ../packaging/setup.sh setup.sh && chmod +x setup.sh
[ -f ../setup.sh ] && cp ../setup.sh setup.sh && chmod +x setup.sh
# also mirror the one-shot installer/uninstaller next to the repo (Pages fallback)
[ -f ../install.sh ] && cp ../install.sh install.sh && chmod +x install.sh
[ -f ../uninstall.sh ] && cp ../uninstall.sh uninstall.sh && chmod +x uninstall.sh
printf '<h1>sckoc apt repository</h1><p>See <a href="https://github.com/SkyWalkerAMD/sckoc">GitHub</a> for install instructions.</p>' > index.html
echo "apt repo ready under apt-repo/ (setup.sh included if present)"

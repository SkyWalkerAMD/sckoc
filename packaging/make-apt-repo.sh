#!/bin/bash
# build a flat apt repo under ./apt-repo from *.deb in cwd
set -e
mkdir -p apt-repo/pool apt-repo/dists/stable/main/binary-amd64
cp ./*.deb apt-repo/pool/
cd apt-repo
dpkg-scanpackages --arch amd64 pool /dev/null > dists/stable/main/binary-amd64/Packages
gzip -9c dists/stable/main/binary-amd64/Packages > dists/stable/main/binary-amd64/Packages.gz
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=msr-sck \
  -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 \
  -o APT::FTPArchive::Release::Components=main \
  release dists/stable > /tmp/Release.tmp
mv /tmp/Release.tmp dists/stable/Release
printf '<h1>msr-sck apt repository</h1><p>See <a href="https://github.com/SkyWalkerAMD/msr-sck">GitHub</a> for install instructions.</p>' > index.html
echo "apt repo ready under apt-repo/"

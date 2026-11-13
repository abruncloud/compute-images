#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID != 0 || $# < 1 || $# > 2 ]]; then
  echo 'Usage: sudo ./build.sh OUTPUT_DIRECTORY [abrun-base|abrun-full]' >&2
  exit 2
fi

profile=${2:-abrun-full}
debian_mirror=${ABRUN_IMAGE_DEBIAN_MIRROR:-https://deb.debian.org/debian}
security_mirror=${ABRUN_IMAGE_SECURITY_MIRROR:-https://deb.debian.org/debian-security}
docker_mirror=${ABRUN_IMAGE_DOCKER_MIRROR:-https://download.docker.com/linux/debian}
for mirror in "$debian_mirror" "$security_mirror" "$docker_mirror"; do
  if [[ ! $mirror =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]+)?$ ]]; then
    echo 'Use an HTTPS APT mirror without credentials or query parameters.' >&2
    exit 2
  fi
done
packages=systemd-sysv,systemd-resolved,dbus,udev,iproute2,openssh-server,cloud-init,sudo,ca-certificates,htop
case "$profile" in
  abrun-base) ;;
  abrun-full) packages+=,curl,git,jq,python3,libatomic1 ;;
  *) echo "Unknown image profile: $profile" >&2; exit 2 ;;
esac

mkdir -p "$1"
output=$(realpath "$1")
architecture=$(dpkg --print-architecture)
asset=$profile-debian13-$architecture.root.ext4.zst
if [[ -e "$output/$asset" || -e "$output/SHA256SUMS" ]]; then
  echo 'Choose an output directory without a previous image or checksum.' >&2
  exit 1
fi
work=$(mktemp -d "$output/.build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
root=$work/root

cat >"$work/debian.list" <<APT
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] ${debian_mirror%/} trixie main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] ${debian_mirror%/} trixie-updates main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] ${security_mirror%/} trixie-security main
APT
mmdebstrap --mode=root --variant=minbase --format=directory \
  --aptopt='Acquire::Languages "none"' --include="$packages" \
  trixie "$root" "$work/debian.list"

if [[ $profile == abrun-full ]]; then
  rm -f "$root/etc/resolv.conf"
  cp -L /etc/resolv.conf "$root/etc/resolv.conf"
  install -d -m 0755 "$root/etc/apt/keyrings"
  if [[ -n ${ABRUN_IMAGE_DOCKER_KEY_FILE:-} ]]; then
    install -m 0644 "$ABRUN_IMAGE_DOCKER_KEY_FILE" "$root/etc/apt/keyrings/docker.asc"
  else
    curl -fsSL --retry 3 --max-time 60 https://download.docker.com/linux/debian/gpg \
      -o "$root/etc/apt/keyrings/docker.asc"
  fi
  chmod 0644 "$root/etc/apt/keyrings/docker.asc"
  cat >"$root/etc/apt/sources.list.d/docker.sources" <<APT
Types: deb
URIs: ${docker_mirror%/}
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
APT
  printf '#!/bin/sh\nexit 101\n' >"$root/usr/sbin/policy-rc.d"
  chmod 0755 "$root/usr/sbin/policy-rc.d"
  chroot "$root" apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 \
    -o Acquire::Languages=none update
  chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
    install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  chroot "$root" apt-get clean
  rm -f "$root/usr/sbin/policy-rc.d"
  rm -rf "$root/var/lib/apt/lists/"*
fi

chroot "$root" useradd --create-home --shell /bin/bash abrun
cat >"$root/etc/profile.d/99-abrun-welcome.sh" <<'WELCOME'
case $- in
  *i*)
    if [ "${USER:-}" = abrun ] && [ -n "${BASH_VERSION:-}" ] &&
      (umask 077; set -C; : >"$HOME/.abrun-welcomed") 2>/dev/null; then
      printf 'Welcome to Abrun. You are connected to %s.\n' "$(hostname)"
    fi
    ;;
esac
WELCOME

mkdir -p "$root/var/lib/cloud/seed/nocloud" "$root/etc/systemd/network" \
  "$root/etc/systemd/system/cloud-init-local.service.d"
cat >"$root/etc/cloud/cloud.cfg.d/99-abrund-image.cfg" <<'CLOUD'
datasource_list: [NoCloud]
manage_etc_hosts: localhost
system_info:
  default_user:
    name: abrun
    shell: /bin/bash
    lock_passwd: true
network: {config: disabled}
apt:
  preserve_sources_list: true
growpart:
  mode: 'off'
resize_rootfs: false
CLOUD
cat >"$root/etc/fstab" <<'FSTAB'
/dev/vda / ext4 defaults 0 1
LABEL=fcseed /var/lib/cloud/seed/nocloud ext4 ro,nofail,nodev,nosuid,noexec,x-systemd.device-timeout=10s 0 0
FSTAB
cat >"$root/etc/systemd/network/05-abrund.network" <<'NETWORK'
[Match]
Name=eth* en*

[Network]
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no
NETWORK
ln -sfn /var/lib/cloud/seed/nocloud/abrund.network "$root/etc/systemd/network/04-abrund-static.network"
cat >"$root/etc/systemd/system/cloud-init-local.service.d/10-abrund-seed.conf" <<'UNIT'
[Unit]
RequiresMountsFor=/var/lib/cloud/seed/nocloud
UNIT
printf 'localhost\n' >"$root/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' >"$root/etc/hosts"
ln -sfn /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
install -d -m 0755 "$root/etc/ssh/sshd_config.d"
cat >"$root/etc/ssh/sshd_config.d/00-abrun-image.conf" <<'SSH'
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
SSH
chmod 0644 "$root/etc/ssh/sshd_config.d/00-abrun-image.conf"
systemctl --root="$root" enable systemd-networkd.service systemd-resolved.service ssh.service
chroot "$root" cloud-init clean --logs --machine-id
rm -f "$root"/etc/ssh/ssh_host_* "$root/var/lib/systemd/random-seed" \
  "$root"/var/log/{dpkg.log,apt/history.log,apt/term.log}
find "$root/root" "$root/home" -type f \( -name authorized_keys -o -name authorized_keys2 \) -delete
test -z "$(find "$root/var/lib/cloud/seed/nocloud" -mindepth 1 -print -quit)"
if [[ $profile == abrun-full ]]; then
  node_version=26.13.1
  bun_version=1.4.4
  case "$architecture" in
    amd64)
      node_arch=x64
      bun_arch=x64
      node_sha=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864
      bun_sha=bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c
      ;;
    arm64)
      node_arch=arm64
      bun_arch=aarch64
      node_sha=89e1853138db51e8b82d3e98ba9c0d3f2956a28e5e55ea1b7e12d25aae92d5dd
      bun_sha=baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e
      ;;
    *) echo "Unsupported architecture for abrun-full: $architecture" >&2; exit 1 ;;
  esac

  node_archive=node-v$node_version-linux-$node_arch.tar.xz
  bun_archive=bun-linux-$bun_arch.zip
  curl -fsSL --retry 3 --max-time 180 "https://nodejs.org/dist/v$node_version/$node_archive" -o "$work/$node_archive"
  curl -fsSL --retry 3 --max-time 180 "https://github.com/oven-sh/bun/releases/download/bun-v$bun_version/$bun_archive" -o "$work/$bun_archive"
  (cd "$work" && printf '%s  %s\n' "$node_sha" "$node_archive" "$bun_sha" "$bun_archive" | sha256sum --check)
  install -d "$root/usr/local/bin"
  tar -xJf "$work/$node_archive" -C "$root/usr/local" --strip-components=1 --no-same-owner
  unzip -q "$work/$bun_archive" "bun-linux-$bun_arch/bun" -d "$work"
  install -m 0755 "$work/bun-linux-$bun_arch/bun" "$root/usr/local/bin/bun"

  [[ $(chroot "$root" /usr/local/bin/node --version) == "v$node_version" ]]
  chroot "$root" /usr/local/bin/npm --version
  [[ $(chroot "$root" /usr/local/bin/bun --version) == "$bun_version" ]]
  systemctl --root="$root" enable docker.service
  chroot "$root" docker --version
  chroot "$root" docker compose version
fi
chmod 0755 "$root"

truncate -s 4G "$work/root.ext4"
mkfs.ext4 -q -F -d "$root" "$work/root.ext4"
e2fsck -fn "$work/root.ext4"
zstd -q -T2 -6 "$work/root.ext4" -o "$work/$asset"
zstd -qt "$work/$asset"
(cd "$work" && sha256sum "$asset" >SHA256SUMS)
mv "$work/$asset" "$work/SHA256SUMS" "$output/"

#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID != 0 || $# < 1 || $# > 2 ]]; then
  echo 'Usage: sudo ./build.sh OUTPUT_DIRECTORY [abrun-base|abrun-full]' >&2
  exit 2
fi

profile=${2:-abrun-full}
packages=systemd-sysv,systemd-resolved,dbus,udev,iproute2,openssh-server,cloud-init,sudo,ca-certificates
case "$profile" in
  abrun-base) ;;
  abrun-full) packages+=,curl,git,jq,python3,docker.io,docker-cli,docker-compose,libatomic1 ;;
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

cat >"$work/debian.list" <<'APT'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie-updates main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian-security trixie-security main
APT
mmdebstrap --mode=root --variant=minbase --format=directory \
  --aptopt='Acquire::Languages "none"' --include="$packages" \
  trixie "$root" "$work/debian.list"

mkdir -p "$root/var/lib/cloud/seed/nocloud" "$root/etc/systemd/network" \
  "$root/etc/systemd/system/cloud-init-local.service.d"
cat >"$root/etc/cloud/cloud.cfg.d/99-abrund-image.cfg" <<'CLOUD'
datasource_list: [NoCloud]
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

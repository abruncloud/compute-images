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
  abrun-full) packages+=,curl,git,jq,python3,docker.io,docker-cli,docker-compose ;;
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

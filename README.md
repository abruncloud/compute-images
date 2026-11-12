# Abrun Compute Images

Minimal Debian 13 guest images for Abrun Compute. The ARM64 image includes systemd, OpenSSH, Docker Engine, Docker Compose, Git, curl, jq, Python and APT.

Download the compressed ext4 disk and its SHA-256 checksum from [Releases](https://github.com/abruncloud/compute-images/releases). The disk expands to 4 GiB. Boot it with a compatible ARM64 guest kernel and a read-only NoCloud seed containing the instance identity and authorized public keys. The guest generates its own SSH host keys on first boot. An Abrun seed can also supply the assigned static IP. The image supports DHCP for seeds that omit it.

Build on a same-architecture Debian 13 host with `mmdebstrap`, `debian-archive-keyring`, `ca-certificates`, `e2fsprogs`, `systemd`, and `zstd` installed.

```sh
sudo ./build.sh ./output
(cd output && sha256sum -c SHA256SUMS)
```

GitHub Actions builds a fresh candidate every week from Debian stable, updates, and security repositories. Boot the candidate, check SSH and Compose, then publish it under a new release tag. Running guests can install security updates through APT when they have repository access.

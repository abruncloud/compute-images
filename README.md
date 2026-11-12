# Abrun Compute Images

Minimal Debian 13 guest images for Abrun Compute. Both profiles build natively for AMD64 and ARM64.

- `abrun-base` includes systemd, OpenSSH, APT, sudo, and NoCloud provisioning.
- `abrun-full` adds Docker Engine, Docker Compose, Git, curl, jq, and Python tooling.

Download the compressed ext4 disk and its SHA-256 checksum from [Releases](https://github.com/abruncloud/compute-images/releases). The disk expands to 4 GiB. Boot it with a compatible guest kernel for your architecture and a read-only NoCloud seed containing the instance identity and authorized public keys. The guest generates its own SSH host keys on first boot. An Abrun seed can also supply the assigned static IP. The image supports DHCP for seeds that omit it.

Build on a same-architecture Debian 13 host with `mmdebstrap`, `debian-archive-keyring`, `ca-certificates`, `e2fsprogs`, `systemd`, and `zstd` installed.

```sh
sudo ./build.sh ./output abrun-full
(cd output && sha256sum -c SHA256SUMS)
```

GitHub Actions builds both profiles for each architecture every week from Debian stable, updates, and security repositories. Boot the candidate, check SSH and Compose, then publish it by supplying a new tag to the manual workflow. Running guests can install security updates through APT when they have repository access.

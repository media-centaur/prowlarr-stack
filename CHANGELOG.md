# Changelog

All notable changes to prowlarr-stack are documented here. Format follows
[keepachangelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
### Changed
### Fixed

## [0.2.0] - 2026-04-26

### Added
- `./backup` — captures `.env` + `config/` into a portable tarball (mode 600,
  default `$HOME/prowlarr-stack-backup-<host>-<UTC>.tar.gz`). Briefly stops the
  stack to flush SQLite WAL; `--no-stop` skips. Refuses to write into directories
  containing `.git/` or `.jj/` since the tarball contains your WireGuard private
  key.
- `./restore <tarball>` — restores `.env` + `config/` from a backup, snapshots
  existing state to `.env.pre-restore-<UTC>` / `config.pre-restore-<UTC>/` for
  rollback, scrubs `HOST_LAN_IP` and `LAN_SUBNET` (so the receiving machine's
  values are auto-detected and re-patched into Prowlarr's download-client row),
  re-runs `./setup --non-interactive`, re-verifies isolation.
- `./install --restore PATH` and `install.sh --restore PATH` — clean-install
  flow: `curl … | sh -s -- --restore /path/to/backup.tar.gz` reproduces a
  configured stack on a fresh machine in one shot, no interactive prompts.

## [0.1.1] - 2026-04-26

### Fixed
- `curl … | install.sh` no longer exits at the first prompt. The bootstrap
  reattaches stdin to the controlling terminal before handing off to the
  interactive installer, so VPN-provider and credential prompts work as
  documented in the README.

## [0.1.0] - 2026-04-23

Initial public release.

### Added
- VPN-isolated Prowlarr + qBittorrent stack with gluetun, supporting NordVPN,
  ProtonVPN, Mullvad, Surfshark, IVPN, AirVPN, Windscribe, and any other
  gluetun-supported WireGuard provider.
- Turn-key interactive installer (`./setup`) with provider-aware prompts and
  per-provider credential extraction guides.
- Release pipeline: GitHub Releases, bootstrap `install.sh` (curl-pipe), and
  release-aware `./update` with version pinning and rollback.
- Transparent `MANIFEST`-driven `./uninstall` with `--purge-images` and
  `--purge-data` flags.
- Pinned upstream container image versions for reproducible installs.

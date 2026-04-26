# Changelog

All notable changes to prowlarr-stack are documented here. Format follows
[keepachangelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
### Changed
### Fixed

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

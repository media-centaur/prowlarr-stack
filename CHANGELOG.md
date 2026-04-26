# Changelog

All notable changes to prowlarr-stack are documented here. Format follows
[keepachangelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
### Changed
### Fixed

## [0.3.0] - 2026-04-26

### Added
- Configurable storage paths. `DOWNLOADS_DIR` and `COMPLETED_DIR` in `.env`
  set the host paths bind-mounted into qBittorrent. Defaults preserve the
  prior `/mnt/videos/{downloads,Videos}` layout, so a returning user just
  hits Enter at the setup prompts.
- Mountpoint guard. Setup verifies each storage path is a real kernel
  mountpoint and refuses to start the stack if the OS mount didn't come
  up — preventing silent writes to the root filesystem. The generated
  systemd user unit also gets `RequiresMountsFor=` for both paths, so
  reboots wait for the underlying mounts.
- `ALLOW_NON_MOUNTPOINT=1` opt-out for single-disk hosts where storage is
  a plain directory rather than a dedicated mount. Setup offers this
  interactively when it detects a non-mountpoint, or you can set it
  upfront in `.env`.

### Changed
- Backup / restore now carries your chosen storage paths across machines.
  `DOWNLOADS_DIR` and `COMPLETED_DIR` live in `.env`, which is already
  captured in the backup tarball — restoring on a different host no
  longer requires hand-editing `docker-compose.yml`. If the destination
  doesn't have those paths mounted, restore hard-fails with a precise
  error rather than silently writing to the wrong location.
- `./uninstall --purge-data` removes the contents of whichever paths you
  configured, instead of the previously-hardcoded `/mnt/videos/...`.

## [0.2.2] - 2026-04-26

### Fixed
- Setup now force-recreates containers when starting the stack. A reinstall
  workflow (`rm -rf ~/prowlarr-stack && curl … | sh` while the old stack
  was still running) left the kernel holding the original — now-orphaned —
  bind-mount inode for `config/prowlarr/`. The fresh `docker compose up -d`
  was a no-op (same-named containers existed), so Prowlarr wrote its
  generated API key into a phantom directory that no longer existed on
  the host, and setup's post-install summary fell through to the "open the
  UI" fallback. `docker compose up -d --force-recreate` replaces the
  containers, re-resolving every bind mount against the current host
  inode.

## [0.2.1] - 2026-04-26

### Fixed
- The post-install summary now actually prints the Prowlarr API key. Previously,
  setup read `config/prowlarr/config.xml` immediately after gluetun became
  healthy, but Prowlarr hadn't finished initializing yet — so the seeded empty
  `<ApiKey>` was returned and you saw the "open the UI" fallback message.
  Setup now polls for up to 30s until Prowlarr persists the generated key.

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

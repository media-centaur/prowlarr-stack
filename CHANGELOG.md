# Changelog

All notable changes to prowlarr-stack are documented here. Format follows
[keepachangelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
### Changed
### Fixed

## [0.4.0] - 2026-04-26

### Added
- Optional VPN routing for qBittorrent. `./setup` now asks whether
  qBittorrent should go direct via your ISP (default, recommended) or
  share gluetun's tunnel. Direct mode keeps qBT at full ISP speed and
  preserves inbound peer connectivity for seeding — your indexer
  browsing in Prowlarr is hidden by the VPN regardless. Opt into
  tunneled mode if you specifically want qBT's IP hidden from peers
  and you accept the speed hit and (for most providers) loss of
  inbound peers. The choice persists in `.env` as
  `QBITTORRENT_USE_VPN`; flip any time with `./setup --reconfigure`.
- New compose overlay `docker-compose.qbt-vpn.yml` activated via
  `COMPOSE_FILE` in `.env` when tunneled mode is selected. In tunneled
  mode qBittorrent's host ports (8080, 6881) are published by gluetun
  rather than qBittorrent itself, since `network_mode: service:gluetun`
  is incompatible with the container publishing its own ports.
- Prerequisite checks for `findmnt` (used by storage path validation)
  and `systemctl --user` (the installer enables a user-scope unit for
  autostart on reboot). Both have been required since v0.3.0 / always,
  but were never gated — so a missing util-linux or a container env
  without user-scope systemd would fail mid-flow rather than up front.
  Now both fail fast in install.sh and in setup's prerequisites phase.

### Changed
- `./check` and the post-install verification now flip their
  assertion based on `QBITTORRENT_USE_VPN`. Direct mode requires
  prowlarr's external IP to differ from qBittorrent's (same IP
  means prowlarr is leaking past the VPN). Tunneled mode requires
  the two IPs to match (different IPs means qBT escaped the tunnel).
- In tunneled mode, Prowlarr's download-client row in `prowlarr.db`
  is patched to point at `127.0.0.1:8080` rather than
  `${HOST_LAN_IP}:8080`, since the two services now share gluetun's
  network namespace and the LAN bypass isn't needed.

## [0.3.4] - 2026-04-26

### Fixed
- The post-install summary now prints absolute paths (or `~/prowlarr-stack/`)
  for `check`, `update`, and `scripts/stop`, instead of bare `./check` etc.
  After the curl-bootstrap install, your shell is still in the directory
  you ran the bootstrap from — not the install dir — so the relative paths
  it used to print would have failed.

## [0.3.3] - 2026-04-26

### Added
- The bootstrap installer now announces the resolved version up front
  (`Installing prowlarr-stack vX.Y.Z`) before downloading, so you can see
  what you're about to install rather than only at the very end.
- `./setup`'s banner now shows the installed version next to the
  installer title (sourced from `.version`).
- A "Next step" hint at the end of setup points you straight at
  Prowlarr's Indexers page, since adding indexers is the only thing left
  to configure once the stack is up — qBittorrent is already wired in as
  the download client by setup.

## [0.3.2] - 2026-04-26

### Fixed
- Storage path mount check now accepts subdirectories of a mount. v0.3.0
  used `mountpoint -q`, which returns true only when the path is *itself*
  a mountpoint. With `/mnt/videos` as your mount and
  `/mnt/videos/downloads` as your chosen path, setup wrongly prompted you
  to opt into `ALLOW_NON_MOUNTPOINT=1` — defeating the very protection
  the check was added to provide. The check now uses `findmnt --target`
  to resolve the closest containing mount, which is the question we
  actually want to answer. `wait-for-mount` was fixed the same way.

### Changed
- Default `COMPLETED_DIR` is now `/mnt/videos/completed` (was
  `/mnt/videos/Videos`). Symmetric with `DOWNLOADS_DIR=/mnt/videos/downloads`,
  no brand-y capitalization. Existing installs with `/mnt/videos/Videos`
  in their `.env` are unaffected.

## [0.3.1] - 2026-04-26

### Fixed
- Re-tagged release of v0.3.0. The v0.3.0 tag was pushed but its release
  workflow failed before publishing artifacts, due to a shellcheck warning
  on a cross-source variable in the storage-paths code added in 0.3.0. The
  warning is suppressed; functionally identical to the intended v0.3.0.

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

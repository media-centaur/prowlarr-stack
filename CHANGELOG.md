# Changelog

All notable changes to prowlarr-stack are documented here. Format follows
[keepachangelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
### Changed
### Fixed

## [1.1.1] - 2026-07-20

### Fixed
- **SABnzbd categories now force Repair+Unpack+Delete (`pp = 3`).** The seeded
  `sabnzbd.ini` left category `pp` blank, which SABnzbd treats as its own
  default (download + verify only) — archives were never unpacked, so
  multi-part `.rar` releases landed in `completed/` unextracted.
  `set-sab-config` gained `--category-pp`, wired into `./setup` alongside
  `--category-script`, so existing installs converge on `./update` /
  `./setup` the same way the staging layout did.

## [1.1.0] - 2026-07-10

### Changed
- **SABnzbd assembles jobs in a hidden staging folder and moves only finished
  content into the completed tree.** Post-processing (par2 verify/repair,
  unpacking, renames) previously churned directly inside the completed
  folder, so an importer watching it could pick up half-extracted files
  under temporary names. Jobs now complete into `completed/.staging/` — a
  reserved folder importers ignore — and a post-processing script
  (`move-finished.sh`, stack-managed, refreshed on every `./setup`) moves
  each successful job into the completed tree in one atomic rename, dropping
  `.par2`/`.sfv`/`.nzb` recovery files on the way. Failed jobs stay in
  staging; delete them from SABnzbd's history with "delete files". Existing
  installs converge automatically on `./update`.

## [1.0.2] - 2026-07-10

### Fixed
- `setup` now stops the `sabnzbd` container before injecting the news-server
  credentials into `sabnzbd.ini`, so filling `USENET_SERVER_*` in `.env` and
  re-running `./setup` on a live stack reliably takes effect. Previously
  SABnzbd (which reads the ini only at startup and rewrites it on shutdown)
  could overwrite the freshly-injected creds when Phase 9 force-recreated it,
  making the documented "add creds later, re-run setup" path unreliable.

## [1.0.1] - 2026-07-10

### Fixed
- `tests/restore.test` stubs `systemctl` on PATH so the suite no longer targets
  the host's global `--user prowlarr-stack` unit. Previously, running
  `./scripts/test` on a machine with a live install would stop the running
  stack (the real `./restore` under test issued `systemctl --user stop`).
- `./backup` no longer depends on the `hostname` binary (absent on some minimal
  installs, which printed `hostname: command not found`); it derives the short
  host name from `uname -n`.

## [1.0.0] - 2026-07-10

### Added
- **Usenet support via SABnzbd.** A new `sabnzbd` service (WebUI on `8085`,
  running direct like qBittorrent — usenet has no peer exposure) is pre-wired
  into Prowlarr as a download client, mirroring the qBittorrent treatment:
  seeded `defaults/sabnzbd/sabnzbd.ini`, a seeded `Sabnzbd` `DownloadClients`
  row, and migration `0003-add-sabnzbd-download-client` for existing installs.
  `setup` generates a SABnzbd API key, injects it plus the news-server
  credentials (new `.env` block: `USENET_SERVER_*`, `SABNZBD_API_KEY`) into both
  SABnzbd and Prowlarr (`scripts/set-sab-config`, `scripts/patch-prowlarr-sab`).
  Provider account + Newznab indexer keys are user-supplied; the stack ships the
  plumbing ready. See [docs/indexers.md](docs/indexers.md#usenet-providers).

## [0.6.4] - 2026-07-10

### Changed
- Repo now uses plain **git** (dropped Jujutsu/jj). `update` dev-mode detection,
  `scripts/release`, and `scripts/bump-images` are git-only, and the docs no
  longer reference jj. (`./backup` still refuses to write a secrets-bearing
  tarball into a `.git/` *or* `.jj/` directory — that guard protects users on
  either VCS and is intentionally kept.)
- Docs: minor wording — "Cloudflare-protected" (not "FlareSolverr-protected")
  indexers; neutral version placeholder in the README rollback example.

## [0.6.3] - 2026-07-10

### Added
- `scripts/tag-cf-indexers`: tests each enabled indexer and tags the
  Cloudflare-blocked ones with `byparr` (creating the tag if needed), so Prowlarr
  routes them through the solver. Idempotent; leaves working indexers untouched.
  Replaces doing this by hand against the API.
- `scripts/release vX.Y.Z`: cuts a release from the source repo — verifies the
  CHANGELOG section, runs `release-checks`, pushes `main`, tags, pushes the tag,
  and waits for CI to publish. `--dry-run` / `--yes` / `--no-wait`.

## [0.6.2] - 2026-07-09

### Changed
- Documentation: rewrote the README `## Update` section to describe the actual
  transactional upgrade (pre-flight backup → migrate → verify → auto-rollback)
  and the `--enable-auto` unattended timer, and added `docs/upgrading.md`
  covering the full operator procedure, all `./update` flags, and the maintainer
  release flow.

## [0.6.1] - 2026-07-09

### Fixed
- Corrected the FlareSolverr proxy tag model. v0.5.0–v0.6.0 assumed a proxy with
  no tags applies to *all* indexers, and therefore *cleared* the proxy's tag. In
  fact Prowlarr applies an indexer proxy **only to indexers that share a tag with
  it**, so a no-tag proxy is used by nothing — the solver never ran. The seed now
  ships a `byparr` tag on the FlareSolverr proxy, and a new migration
  `0002-flaresolverr-ensure-proxy-tag` restores a valid tag on existing installs
  whose proxy has none (superseding `0001`, which is left in place but no longer
  the fix). **Tag your Cloudflare-protected indexers with `byparr`** to route
  them through the solver — and only those, since a tagged indexer sends all its
  searches through the slower browser solver. See `docs/indexers.md`.

## [0.6.0] - 2026-07-09

### Changed
- Replaced FlareSolverr with **byparr** (`ghcr.io/thephaseless/byparr:2.1.0`), a
  maintained, FlareSolverr-API-compatible Cloudflare solver (same `/v1` API on
  port 8191). The Prowlarr "FlareSolverr" indexer proxy works unchanged — byparr
  speaks that protocol. byparr drives a real browser (Camoufox), so the
  container gets `shm_size: 512mb` and uses noticeably more RAM than FlareSolverr.
  The solver container is renamed `flaresolverr` → `byparr`; the stack now starts
  with `docker compose up -d --remove-orphans` (safe: `COMPOSE_FILE` carries the
  full active set incl. the qbt-vpn overlay) so the old `flaresolverr` container
  is removed automatically on update.

  Caveat: the solver egresses through gluetun's commercial-VPN/datacenter IP,
  which 2026-era Cloudflare weights above browser fingerprint. byparr improves
  odds on easier sites but the hardest indexers (e.g. 1337x) can still time out —
  the real fix is a residential/mobile egress proxy (byparr `PROXY_SERVER`).

## [0.5.1] - 2026-07-09

### Fixed
- Migrations never ran on existing installs. `setup` baseline-stamped every
  migration as "applied" (without running it), and `setup` runs on every
  `./update` — so migration `0001` (and any future one) was skipped forever on
  already-deployed installs, defeating the framework's purpose. Removed the
  baseline mechanism entirely: migrations are idempotent and no-op on
  already-correct/freshly-seeded state, so they simply always run.

## [0.5.0] - 2026-07-09

### Added
- Stack migration framework (`migrations/`, `scripts/run-migrations`):
  idempotent, versioned fixups applied automatically during `./update` (both
  release and dev modes). Each migration detects actual state and no-ops when
  already correct, so fresh installs and existing installs both converge.
- Migration `0001-flaresolverr-orphan-tags`: clears orphaned FlareSolverr proxy
  tags so Prowlarr routes Cloudflare-gated indexers through the solver.
- Transactional release upgrades: pre-flight backup → migrate → verify (gluetun
  health + VPN isolation) → **auto-rollback** to the prior release on failure.
  `--no-rollback` to opt out; optional `UPDATE_NOTIFY_CMD` in `.env` for failure
  notification.
- Opt-in weekly unattended upgrades via a systemd user timer
  (`./update --enable-auto` / `--disable-auto`).

### Changed

### Fixed
- The default seed DB (`defaults/prowlarr/prowlarr.db`) shipped the FlareSolverr
  indexer proxy tagged `[1]` with an empty Tags table, so every fresh install
  started with the proxy scoped to a nonexistent tag — Prowlarr never used
  FlareSolverr and Cloudflare-gated indexer tests failed with "blocked by
  CloudFlare Protection". Cleared the orphan; migration `0001` repairs existing
  installs.
- Release-mode `update` cleanup: the `$tmp` temp dir is now global so the EXIT
  trap can remove it (previously a `local` left it unbound at script exit under
  `set -u`).

## [0.4.6] - 2026-06-26

### Changed
- Bumped all pinned upstream container images to current releases:
  gluetun `v3.40.0` → `v3.41.1`, Prowlarr `2.3.5.5327-ls142` →
  `2.4.0.5397-ls151`, FlareSolverr `v3.4.6` → `v3.5.0`, and qBittorrent
  `5.1.4-r3-ls451` → `5.2.2_v2.0.13-ls463`. qBittorrent stays on the
  libtorrent v2 line (matching the prior Alpine-packaged build) so
  existing `.fastresume` data remains compatible. Run `./update` to pull
  the new images.

## [0.4.5] - 2026-04-26

### Changed
- README and provider docs now make it explicit that a WireGuard VPN
  subscription is required and there is no no-VPN mode. The first
  paragraph points users without a VPN at `linuxserver/prowlarr` as a
  simpler one-container alternative, so they self-select before
  downloading. The provider table in `docs/providers.md` gains a
  port-forwarding column so users picking a VPN see that signal up
  front, and the stale "Mullvad forwards by default" / "AirVPN doesn't
  forward" claims in the README are corrected (Mullvad dropped PF in
  2023; AirVPN supports PF natively).

## [0.4.4] - 2026-04-26

### Fixed
- The bundled FlareSolverr indexer proxy now points at
  `http://localhost:8191/` instead of `http://flaresolverr:8191/`, so
  test-connect works out of the box. Because `prowlarr` and
  `flaresolverr` share gluetun's network namespace
  (`network_mode: "service:gluetun"`), Docker's service-name DNS does
  not resolve between them — `localhost` is the only reachable host.

## [0.4.3] - 2026-04-26

### Fixed
- Re-tagged release of v0.4.2. The v0.4.2 tag was pushed but its release
  workflow failed before publishing artifacts because two shellcheck
  warnings landed in `install.sh` (a dead variable from a refactor I
  forgot to remove, and a `'~/'` pattern that shellcheck flagged as a
  misused-tilde). The dead variable is removed; the case patterns now
  use backslash-escaped tildes (`\~`, `\~/*`), which are equivalent in
  POSIX sh and don't trip SC2088. Functionally identical to the
  intended v0.4.2.

## [0.4.2] - 2026-04-26

### Added
- The bootstrap installer now prompts for the install directory when run
  interactively (`curl … | sh`). Press Enter for the default
  `$HOME/prowlarr-stack`, or type any other absolute path. Tilde
  (`~/foo`) is expanded. The prompt appears AFTER the release version is
  shown and BEFORE the existence check, so picking a different path
  doesn't waste a download. The `--dir` flag and `PROWLARR_STACK_DIR`
  env var still work as non-interactive overrides; `--yes` skips the
  prompt.

### Changed
- The "$DIR already exists" error now suggests picking another path, in
  addition to the existing `--force` and `update` hints, since
  interactively choosing a different dir is now a first-class option.

## [0.4.1] - 2026-04-26

### Fixed
- The direnv prompt during setup now explains what direnv is, what
  saying yes does, and (more importantly) when you actually need it.
  Previously the bare `create .envrc to auto-load .env in this dir?`
  question gave you no way to make an informed choice. Default stays
  no — most users only run the wrapper scripts, which already pick up
  `.env` without direnv's help.

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

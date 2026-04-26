# prowlarr-stack

A self-hosted stack for discovering and downloading torrents on your home server. One command sets it up; another updates it; another tears it down.

## What's in the stack

| Tool | What it does |
| --- | --- |
| **Prowlarr** | Searches across your chosen indexers (tracker sites) from one place. Has a web UI and an API that other tools can hit. |
| **qBittorrent** | A BitTorrent client with a web UI. Handles the actual uploads and downloads. |
| **FlareSolverr** | A helper that solves Cloudflare challenge pages on behalf of Prowlarr, so Prowlarr can reach indexers that use them. |
| **gluetun** | A VPN gateway container. Routes Prowlarr + FlareSolverr through your VPN provider so your ISP doesn't see which indexers you're browsing. By default qBittorrent runs at full ISP speed outside the VPN — see [qBittorrent network routing](#qbittorrent-network-routing) for the opt-in tunneled mode. |

Good for building a library of freely-licensed material — Blender Foundation open movies, Internet Archive collections, Academic Torrents research datasets, Creative Commons music — or for curating your own library of content you already own.

## Requirements

- A Linux host with Docker + Docker Compose v2
- `sqlite3` installed (`pacman -S sqlite` / `apt install sqlite3`)
- A mounted storage location for downloads (default `/mnt/videos`; configurable via `DOWNLOADS_DIR` and `COMPLETED_DIR` — see [Storage paths](#storage-paths))
- A subscription with a [supported VPN provider](docs/providers.md)

## Install

**One-liner:**

```sh
curl -fsSL https://raw.githubusercontent.com/media-centarr/prowlarr-stack/main/install.sh | sh
```

Downloads the latest release, verifies its SHA256 checksum, extracts it to `~/prowlarr-stack`, and runs the interactive setup.

Want to read the script first? Same URL, just pipe to `less`:

```sh
curl -fsSL https://raw.githubusercontent.com/media-centarr/prowlarr-stack/main/install.sh | less
```

**Or: download + verify by hand:**

1. Grab the latest `prowlarr-stack-vX.Y.Z.tar.gz` and `SHA256SUMS` from the [Releases page](https://github.com/media-centarr/prowlarr-stack/releases).
2. `sha256sum -c SHA256SUMS`
3. `tar xf prowlarr-stack-vX.Y.Z.tar.gz && cd prowlarr-stack-vX.Y.Z`
4. `./install`

Either path runs the same interactive flow: prerequisite check, VPN provider selection, credential entry (with provider-specific hints), LAN auto-detection, stack startup, and VPN-isolation verification.

When it's done:

- **Prowlarr** → <http://localhost:9696> — add indexers, connect to qBittorrent.
- **qBittorrent** → <http://localhost:8080> — watch downloads progress.
- **What was installed where?** → `cat ~/prowlarr-stack/MANIFEST`

Full per-provider credential-extraction steps: [docs/providers.md](docs/providers.md).

## Update

```sh
~/prowlarr-stack/update
```

Downloads the latest release, verifies its SHA256, preserves your `.env` and `config/`, swaps in the new version, restarts, and re-verifies.

To pin to a specific version (including for rollback):

```sh
~/prowlarr-stack/update --version v0.1.0 --yes
```

## Backup & restore

Capture your VPN credentials, indexer setup, qBittorrent prefs, and
download-client wiring into a single tarball, then drop it on any clean
machine to reproduce the exact same configured stack — no UI re-setup.

**Take a backup:**

```sh
~/prowlarr-stack/backup
# → $HOME/prowlarr-stack-backup-<host>-<UTC>.tar.gz  (mode 600)
```

The script briefly stops the stack so SQLite is consistent, tars `.env` +
`config/` + a small `BACKUP-MANIFEST`, then restarts. Use `--output PATH`
to write somewhere other than `$HOME`, or `--no-stop` to snapshot live
(faster, accepts a small risk of SQLite WAL inconsistency).

**The tarball contains your WireGuard private key and qBittorrent
password.** Treat it like a credential file: store it in a password
manager, encrypted volume, or another safe location. As a guard rail,
`./backup` refuses to write into a directory containing `.git/` or
`.jj/`.

**Restore on the same install dir:**

```sh
~/prowlarr-stack/restore /path/to/prowlarr-stack-backup-*.tar.gz
```

This stops the stack, snapshots your existing `.env` and `config/` to
`.env.pre-restore-<UTC>` and `config.pre-restore-<UTC>/` (so you can
roll back), extracts the backup, scrubs the source machine's
`HOST_LAN_IP` / `LAN_SUBNET` so this machine's values are auto-detected,
re-runs `./setup --non-interactive` to re-patch the Prowlarr DB and
qBittorrent password against the new IP, and re-runs `./check`.

**Restore as part of a clean install (one shot):**

```sh
curl -fsSL https://raw.githubusercontent.com/media-centarr/prowlarr-stack/main/install.sh | sh -s -- --restore /path/to/backup.tar.gz
```

The bootstrap downloads the latest release, extracts it, and hands off
to `./install --restore`, which skips the interactive prompts and
applies the backup directly. Pass an absolute path; the script
validates the file is readable before downloading anything.

**Cross-machine LAN safety.** `HOST_LAN_IP` is baked into Prowlarr's
download-client row in `prowlarr.db`. Restore strips that key from the
restored `.env`, so the receiving machine's actual IP is detected and
re-patched into the DB — your restored stack points qBittorrent at the
right host, not the source machine's address.

## Uninstall

```sh
~/prowlarr-stack/uninstall
```

Reads `MANIFEST` and removes exactly what the installer put on your system: containers, networks, the systemd user unit, and the install dir (including `.env`). Your downloaded media under `DOWNLOADS_DIR` and `COMPLETED_DIR` is left alone by default.

Options:

- `--purge-images` — also `docker rmi` the pinned upstream images.
- `--purge-data --yes-really` — also remove the contents of `DOWNLOADS_DIR` and `COMPLETED_DIR`. The second flag is a deliberate guard.

## Daily use

```sh
./scripts/start     # start the stack
./scripts/stop      # stop it
./scripts/restart   # restart (e.g., after OS reboot)
./check             # verify the VPN is routing traffic correctly
```

## Reconfigure

To rotate a key, switch VPN provider, move to a new LAN, etc.:

```sh
./setup --reconfigure
./scripts/restart
./check
```

Your existing values appear as defaults at each prompt — hit Enter to keep, or type over to change.

## Storage paths

qBittorrent's host download paths are configured via two `.env` keys:

- `DOWNLOADS_DIR` — bind-mounted to `/downloads` inside qBittorrent. In-flight torrents and the `incomplete/` subdir live here.
- `COMPLETED_DIR` — bind-mounted to `/downloads/completed`. Completed downloads land here.

Defaults: `/mnt/videos/downloads` and `/mnt/videos/completed`. `./setup` prompts for both and verifies each path lives on a dedicated mount (using `findmnt --target`, so subdirectories of a mount count — your `/mnt/videos` mount covers `/mnt/videos/downloads` etc.). If the path is on the root filesystem, setup refuses to start the stack — that's the guard against silent writes to the root fs.

The generated systemd user unit also gets `RequiresMountsFor=…` for both paths, so a reboot won't start the stack until the underlying filesystems are mounted.

**Single-disk hosts.** If your storage is just a directory on the root filesystem (no dedicated mount), set `ALLOW_NON_MOUNTPOINT=1` in `.env`. Setup will skip the mountpoint check, `mkdir -p` the paths if needed, and emit the systemd unit without `RequiresMountsFor`. Setup also offers this as an interactive opt-in if it detects a non-mountpoint directory and you're not already opted in.

**Backup/restore portability.** Both keys live in `.env`, so `./backup` captures them and `./restore` reapplies them on the destination machine. If the destination doesn't have those mounts, restore (which calls `setup --non-interactive`) hard-fails with a precise error rather than silently writing to the wrong location.

## qBittorrent network routing

`./setup` asks whether qBittorrent should go direct via your ISP (default) or share gluetun's tunnel. Two `.env` keys drive this:

- `QBITTORRENT_USE_VPN=0` (default) — qBT runs on the docker bridge and gets full ISP speed.
- `QBITTORRENT_USE_VPN=1` — qBT joins gluetun's network namespace; its egress and inbound peer traffic both go through the VPN.

**Direct is recommended.** Three reasons:

1. **Speed.** VPN tunnels add latency and almost always cap bandwidth below your ISP line. qBT at full ISP speed is usually 5–10× faster than over a tunnel.
2. **Seeding.** Most VPN providers don't forward inbound ports (NordVPN, ProtonVPN free, Surfshark, IVPN, AirVPN, Windscribe). With qBT tunneled, you can still *connect* to peers but they can't connect back — seeding becomes outgoing-only and tracker stats stay near zero. Mullvad forwards by default; ProtonVPN paid does on opt-in.
3. **Indexer cover is independent.** Your Prowlarr indexer browsing is hidden by gluetun *regardless* of qBT's routing. The thing your ISP can fingerprint — what trackers you're searching — is already covered.

**Opt into tunneled mode** if you specifically need qBT's IP hidden from peers and you accept the speed/seeding hit. Setup writes the right `COMPOSE_FILE` overlay (`docker-compose.qbt-vpn.yml`) so docker compose picks it up automatically. Switch any time with `./setup --reconfigure`.

`./check` knows which mode you're in and inverts its assertion accordingly: in direct mode it requires the prowlarr and qbittorrent IPs to *differ*; in tunneled mode it requires them to *match*.

## Something broken?

- **Installer stopped with a precise error** — fix what it named, re-run `./setup`. It's safe to re-run.
- **`./check` says isolation failed** — `docker logs gluetun` will tell you why; usually a wrong credential.
- **Containers not responding** — `./scripts/restart`.

## Try it with freely-licensed content

If you want to test that everything works end-to-end without needing your own indexers first, public sources of openly-licensed torrents include:

- [Internet Archive](https://archive.org) — vast catalog of public-domain films, books, and music
- [Academic Torrents](https://academictorrents.com) — research datasets
- [Blender Open Movies](https://studio.blender.org/films/) — Big Buck Bunny, Sintel, Tears of Steel, and more

## Supported VPN providers

Built-in guidance for: NordVPN, ProtonVPN, Mullvad, Surfshark, IVPN, AirVPN, Windscribe.

Any other [gluetun-supported](https://github.com/qdm12/gluetun) WireGuard provider works too — the installer accepts the provider's slug and asks for whichever credentials that provider needs.

Details and per-provider extraction steps: [docs/providers.md](docs/providers.md).

## How it works under the hood

For the network topology, kill-switch semantics, file layout, and contributor docs: [docs/architecture.md](docs/architecture.md).


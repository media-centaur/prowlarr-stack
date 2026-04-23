# prowlarr-stack

A self-hosted stack for discovering and downloading torrents on your home server. One command sets it up; another updates it; another tears it down.

## What's in the stack

| Tool | What it does |
| --- | --- |
| **Prowlarr** | Searches across your chosen indexers (tracker sites) from one place. Has a web UI and an API that other tools can hit. |
| **qBittorrent** | A BitTorrent client with a web UI. Handles the actual uploads and downloads. |
| **FlareSolverr** | A helper that solves Cloudflare challenge pages on behalf of Prowlarr, so Prowlarr can reach indexers that use them. |
| **gluetun** | A VPN gateway container. Routes Prowlarr + FlareSolverr through your VPN provider so your ISP doesn't see which indexers you're browsing. qBittorrent downloads run at full ISP speed, outside the VPN. |

Good for building a library of freely-licensed material — Blender Foundation open movies, Internet Archive collections, Academic Torrents research datasets, Creative Commons music — or for curating your own library of content you already own.

## Requirements

- A Linux host with Docker + Docker Compose v2
- `sqlite3` installed (`pacman -S sqlite` / `apt install sqlite3`)
- A mounted storage location at `/mnt/videos` for downloads
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

## Uninstall

```sh
~/prowlarr-stack/uninstall
```

Reads `MANIFEST` and removes exactly what the installer put on your system: containers, networks, the systemd user unit, and the install dir (including `.env`). Your downloaded media under `/mnt/videos` is left alone by default.

Options:

- `--purge-images` — also `docker rmi` the pinned upstream images.
- `--purge-data --yes-really` — also remove your media under `/mnt/videos`. The second flag is a deliberate guard.

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


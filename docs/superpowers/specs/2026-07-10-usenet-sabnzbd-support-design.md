# Usenet (SABnzbd) support for prowlarr-stack

**Date:** 2026-07-10
**Status:** Approved design, pending implementation plan

## Goal

Make the stack usable with usenet alongside BitTorrent. Prowlarr already speaks
Newznab natively, so "usenet support" means adding a **usenet download client**
(SABnzbd) and wiring it into Prowlarr the same way qBittorrent is wired in today.

The user does **not** currently have a news-server account or Newznab indexer
accounts. So the deliverable is **plumbing that is ready to switch on** once
those accounts exist — not a migration of a live usenet setup. Everything the
stack can pre-wire, it pre-wires; the credentials it cannot invent are left as
empty `.env` placeholders and documented manual steps.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Downloader | **SABnzbd** | De facto *arr default; best Prowlarr support and docs. Its ~100 MB idle Python footprint is noise next to byparr's headless browser. Under load (par2 repair + unrar) it is equivalent to NZBGet — that cost is inherent to usenet, not the language. |
| VPN routing | **Direct, no toggle** | Usenet has no peers/swarm — only the paid provider sees your IP over TLS. No peer-level monitoring, so a VPN adds latency/bandwidth cap for no privacy gain. One less knob than `QBITTORRENT_USE_VPN`. |
| Storage | **Share the existing bind mounts** | Usenet completions land in the same `completed/` tree as torrents (own category subfolders). Downstream *arr importers see one uniform tree; no new path knobs. par2/unrar happen in the incomplete dir; only finished output lands in `completed/`. |
| Auto-wiring | **Full parity with qBittorrent** | Matches the whole stack's philosophy: `setup` wires everything, the user only supplies credentials. Usenet then inherits backup/restore/update/health for free. |

## Two networking facts that shape the design

1. **Port conflict.** SABnzbd's default WebUI port is `8080`, which qBittorrent
   already publishes. SAB is remapped to host port **`8085`** (`8085:8080`).
2. **Prowlarr → SAB reachability.** Prowlarr runs *inside* gluetun's network
   namespace; SAB runs direct on the host bridge. This is identical to the
   qBittorrent-direct case today: Prowlarr reaches SAB via the **host LAN IP**
   (`http://LAN_IP:8085`), which works because gluetun's
   `FIREWALL_OUTBOUND_SUBNETS=${LAN_SUBNET}` already permits LAN egress. The SAB
   `DownloadClient` row therefore gets `host = LAN_IP`, same as qBittorrent-direct.

## Components

### 1. New service — `sabnzbd` (docker-compose.yml)

Alongside qBittorrent, **not** in gluetun's netns (direct):

- Image: `linuxserver/sabnzbd`, pinned like the other images.
- Ports: `8085:8080` (WebUI).
- Volumes:
  - `./config/sabnzbd:/config`
  - `${DOWNLOADS_DIR:-/mnt/videos/downloads}:/downloads` (incomplete/working)
  - `${COMPLETED_DIR:-/mnt/videos/completed}:/downloads/completed` (finished)
- `PUID=1000`, `PGID=1000`, `TZ` mirror the other services.
- No VPN overlay, no healthcheck required — matches qBittorrent's
  `restart: "no"`, no-healthcheck posture.

### 2. Seeded config — `defaults/sabnzbd/sabnzbd.ini`

Shipped like `defaults/qbittorrent/qBittorrent.conf`:

- `[misc]`: complete/incomplete dirs pointing at the shared mounts;
  `host_whitelist` / `local_ranges` set so the WebUI + API accept connections
  from Prowlarr over the LAN.
- `[categories]`: `tv`, `movies` (etc.) mapped to `completed/` subfolders,
  mirroring `defaults/qbittorrent/categories.json` so the downstream *arr
  importers see a uniform tree.
- `[servers]`: one news-server template (`server1`) with TLS on, port 563, a
  `connections` value, and host/username/password left blank for `setup` to
  inject.
- `api_key`: blank — `setup` generates and injects it.

### 3. Credentials & `.env`

New placeholders in `.env.example` (empty by default → builds "plumbing-ready"):

```
# --- Usenet (SABnzbd) ---
# News-server (Usenet provider) account. Leave blank until you have one;
# SABnzbd starts either way but can't download until these are filled.
# Re-run ./setup after filling them in.
USENET_SERVER_HOST=
USENET_SERVER_PORT=563
USENET_SERVER_USERNAME=
USENET_SERVER_PASSWORD=
USENET_SERVER_CONNECTIONS=20
```

`setup` gains a phase mirroring the qBittorrent password phase (§5/§6 of setup):

- Generate a random **SAB API key** — or read the existing value from
  `.env`/current config for idempotency (do not churn the key on every run).
- New `scripts/set-sab-config`: writes the API key + news-server credentials
  into `sabnzbd.ini`. Operates on the stopped/seeded config, because SAB
  rewrites its `.ini` at runtime. Reads the password from stdin (`-`) like
  `set-qbt-password`, to avoid leaking it via argv.
- New `scripts/patch-prowlarr-sab` (sibling to `patch-prowlarr-db`): writes
  `host = LAN_IP`, `port = 8085`, `apiKey` into the Prowlarr `DownloadClients`
  row where `Implementation = 'Sabnzbd'`. Same IPv4/port validation, same
  idempotent `json_set`, same verify-it-landed check as the qBittorrent script.

### 4. Prowlarr DB

- `defaults/prowlarr/prowlarr.db` gains a pre-seeded **SABnzbd `DownloadClient`
  row** (enabled, matching qBittorrent) so fresh installs have it.
- **Migration `0003-add-sabnzbd-download-client`**: adds that row to existing
  installs' live DB, idempotently (no-op if the row already exists or the DB is
  absent), following the `0001`/`0002` pattern (`set -euo pipefail`, sources
  `scripts/lib/common`, takes `<install_dir>`, guards on DB presence).

### 5. Lifecycle & docs

- **MANIFEST**: add `config/sabnzbd/sabnzbd.ini` (mode 600 — it holds the API
  key + provider creds), the `linuxserver/sabnzbd` image line, and the `sabnzbd`
  container line.
- **backup / restore**: confirm `config/sabnzbd/` is captured. They operate over
  `config/`, so it should be included automatically — verify, and add an explicit
  entry only if the scripts enumerate config files by name.
- **check / tests**: extend to assert the SAB service is defined, the
  `Sabnzbd` DownloadClient row exists, and host port 8085 is used.
- **setup final summary**: print the SABnzbd URL + API key in the "record these"
  block, next to the qBittorrent entry.
- **README / docs**: document the usenet section — you supply a news-server
  account + Newznab indexer keys, fill the `.env` block, re-run `setup`. Update
  `docs/providers.md` / `docs/indexers.md` / `docs/architecture.md` as
  appropriate.

### 6. What stays manual (inherently user-supplied)

- News-server (Usenet provider) account signup.
- Newznab indexer accounts + API keys, added in Prowlarr's UI.

The stack makes everything *ready* for these; it cannot create the accounts.

## Out of scope

- NZBGet (rejected in favor of SABnzbd).
- A `SABNZBD_USE_VPN` overlay (usenet doesn't benefit from VPN routing).
- Separate storage paths / disks for usenet (shares the torrent mounts).
- Any change to the downstream media-centaur *arr apps — they consume the
  uniform `completed/` tree unchanged.

## Testing strategy

- `scripts/patch-prowlarr-sab` and `scripts/set-sab-config`: unit-style tests
  under `tests/`, following the existing `patch-prowlarr-db` / `set-qbt-password`
  test patterns (idempotency, field lands, bad input rejected).
- Migration `0003`: test that it adds the row to a DB without one, is a no-op on
  a DB that already has it, and no-ops on a missing DB.
- `check`: SAB service present, port 8085, DownloadClient row present.
- Manual end-to-end (documented, not automated — requires real accounts): fill
  `.env` usenet block + a Newznab indexer, re-run `setup`, confirm Prowlarr's
  SABnzbd download-client test passes and a manual grab reaches SAB.

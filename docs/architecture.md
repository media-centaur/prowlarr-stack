# Architecture

Technical details for curious users and contributors. If you just want to install and use the stack, the top-level [README](../README.md) is enough.

## Traffic routing

Egress is a property of the upstream, not of the stack. Torrent sites are widely
ISP-blocked and expose your address to peers, so torrent traffic goes through the
tunnel. Usenet does not: only your paid news server sees your address, over TLS.

| Upstream | Route | Mechanism |
|---|---|---|
| Usenet indexers | Direct | no tag |
| Torrent indexers | Tunnel | `vpn` tag → `Http` indexer proxy → `gluetun:8888` |
| Cloudflare-gated torrent indexers | Tunnel | `byparr` tag → FlareSolverr proxy → `gluetun:8191` |
| Prowlarr → SABnzbd / qBittorrent API | Compose bridge | service name |
| SABnzbd | Direct | — |
| qBittorrent | Direct, or tunnel | `QBITTORRENT_USE_VPN` |

Prowlarr runs on the compose bridge and publishes its own port. gluetun exposes
the tunnel as an HTTP proxy on 8888, reachable by sibling containers and never
published to the host. Prowlarr applies an indexer proxy only to indexers that
share a tag with it, which is what makes routing per-indexer rather than
per-container.

With no VPN configured, `COMPOSE_PROFILES` is empty: gluetun and byparr are
absent from the project, nothing backs the `vpn` tag, and torrent indexers are
unusable. Usenet is unaffected. `./setup` accepts a blank VPN provider for this.

**Kill-switch.** gluetun's firewall drops egress that is not through the tunnel.
Prowlarr itself no longer loses connectivity when the tunnel drops, since it is
not in the namespace — but `vpn`-tagged indexers do, because the proxy listens
only inside it. A dropped tunnel gives them connection-refused, never a
fallthrough to the ISP. qBittorrent is covered only when `QBITTORRENT_USE_VPN=1`.

**Leak surface.** Per-indexer routing is fail-open where namespace membership was
fail-closed: a torrent indexer added without the `vpn` tag would query over the
ISP path. `./setup` tags every torrent-protocol indexer through
`scripts/tag-vpn-indexers`, and `./check` fails when an enabled torrent indexer
lacks the tag — so drift fails the upgrade gate instead of leaking quietly. The
residual gap is an indexer added between runs of `setup` and `check`.

## Container topology

**Direct mode (default):**

```
┌──────────────────────────── host ────────────────────────────┐
│                                                              │
│   ┌── gluetun netns ────────────┐    ┌── docker bridge ──┐   │
│   │  gluetun  (WireGuard → VPN) │    │                   │   │
│   │  ├─ prowlarr    (no ports)  │    │   qbittorrent     │   │
│   │  └─ byparr (no ports)       │    │                   │   │
│   └─────────────────────────────┘    └───────────────────┘   │
│         │ published on host:                    │            │
│         │   9696 (prowlarr)                     │ 8080, 6881 │
│         │   8191 (byparr)                       ▼            │
│         ▼                                                    │
│       host :9696, :8191                     host :8080, :6881│
└──────────────────────────────────────────────────────────────┘
```

`prowlarr` and `byparr` share gluetun's network namespace (`network_mode: "service:gluetun"`). That means their ports are published by the `gluetun` service, not by themselves — and their egress traffic is routed through gluetun's tunnel.

`qbittorrent` is on the default Docker bridge, reachable at the host's LAN IP on ports 8080 (web UI) and 6881 (BitTorrent peers).

**Tunneled mode (`QBITTORRENT_USE_VPN=1`):**

```
┌──────────────────────────── host ────────────────────────────┐
│                                                              │
│   ┌── gluetun netns ─────────────────────────────────────┐   │
│   │  gluetun  (WireGuard → VPN)                          │   │
│   │  ├─ prowlarr    (no ports)                           │   │
│   │  ├─ byparr (no ports)                                │   │
│   │  └─ qbittorrent  (no ports)                          │   │
│   └──────────────────────────────────────────────────────┘   │
│         │ published on host (all by gluetun):                │
│         │   9696, 8191, 8080, 6881/tcp, 6881/udp             │
│         ▼                                                    │
│       host :9696 :8191 :8080 :6881 (tcp+udp)                 │
└──────────────────────────────────────────────────────────────┘
```

All three application containers share gluetun's namespace. qBittorrent's host ports (8080, 6881) are published by gluetun rather than qBittorrent itself, since `network_mode: "service:gluetun"` is incompatible with the container publishing its own ports. The `docker-compose.qbt-vpn.yml` overlay clears qBT's `ports:` list (`!reset []`) and adds them to gluetun.

## LAN bypass (direct mode only)

In direct mode, Prowlarr (inside gluetun's netns) needs to reach qBittorrent (on the docker bridge). It can't use Docker's service DNS to resolve `qbittorrent` because gluetun's firewall would drop any egress that isn't either through the tunnel or to the LAN subnet. Gluetun's `FIREWALL_OUTBOUND_SUBNETS=${LAN_SUBNET}` environment variable punches a hole in the kill-switch firewall for your LAN, and Prowlarr reaches qBittorrent at `http://${HOST_LAN_IP}:8080` over the LAN.

In tunneled mode there is no LAN hop — Prowlarr and qBittorrent share the same netns, and Prowlarr reaches qBittorrent at `http://127.0.0.1:8080`. `./setup` writes whichever host the chosen mode requires into Prowlarr's `DownloadClients` row.

`HOST_LAN_IP` and `LAN_SUBNET` are auto-detected by `./setup` but can be overridden at the prompt. They're still required in tunneled mode (gluetun uses `LAN_SUBNET` for its kill-switch carve-out, and the systemd unit and verification path use `HOST_LAN_IP`).

## File layout

```
prowlarr-stack/
├── README.md                # end-user overview
├── setup                    # interactive installer
├── check                    # standalone VPN-isolation verifier
├── update                   # one-command upgrade (source + images)
├── docker-compose.yml          # 4 services: gluetun, prowlarr, byparr, qbittorrent (direct mode default)
├── docker-compose.qbt-vpn.yml  # overlay: routes qBittorrent through gluetun (tunneled mode)
├── .env                     # generated by setup (gitignored, chmod 600)
├── .env.example             # template with blanks
├── scripts/
│   ├── lib/common           # shared bash library: validators, detection,
│   │                        #   logging, prereqs, env I/O, prompts, verification,
│   │                        #   provider registry
│   ├── start / stop / restart   # wrappers around the systemd user service
│   ├── wait-for-mount       # used as an ExecStartPre by the systemd unit
│   ├── patch-prowlarr-db    # idempotent sqlite3 UPDATE for the qBittorrent download-client row
│   └── test                 # pure-bash test runner
├── defaults/
│   ├── prowlarr/            # seed config copied into config/ on first install
│   ├── qbittorrent/         # seed config
│   └── prowlarr-stack.service # systemd user unit template
├── config/                  # runtime state (gitignored)
└── tests/                   # unit tests for lib/common + the DB patcher
```

## Install phases

`./setup` runs these in order. Any failure stops the script with a precise error message.

1. **Prerequisites** — docker, docker compose, sqlite3, python3, the `ip` command, `findmnt` (util-linux, used by storage path validation), `systemctl --user` (the installer enables a user-scope unit for autostart on reboot).
2. **Configuration** — VPN provider and WireGuard key, both **optional** (blank gives a usenet-only stack); with a provider, also the exit country and optional `WIREGUARD_ADDRESSES` / `WIREGUARD_PRESHARED_KEY`. Then host LAN IP, LAN subnet, `DOWNLOADS_DIR`, `COMPLETED_DIR`, and `QBITTORRENT_USE_VPN` (offered only when a VPN is configured — see [Traffic routing](#traffic-routing)). Auto-detects LAN values; validates each input before accepting.
3. **Write `.env`** — atomic (tmp file + rename), `chmod 600` before rename. Writes `COMPOSE_PROFILES=vpn` when a VPN is configured, which is what brings gluetun and byparr into the project at all, and `COMPOSE_FILE` for the qBT overlay (`docker-compose.yml` alone in direct mode, `docker-compose.yml:docker-compose.qbt-vpn.yml` in tunneled mode).
4. **Seed `config/`** — copy from `defaults/` if the destination doesn't exist (idempotent; re-runs don't clobber state).
5. **Patch `prowlarr.db`** — rewrites the download-client rows to compose service names, since Prowlarr reaches the clients over the bridge: `qbittorrent:8080` direct, `gluetun:8080` when tunneled (a tunneled client shares gluetun's namespace and has no name of its own), `sabnzbd:8080`. With a VPN configured, also seeds the `vpn` tag and the `Http` indexer proxy at `gluetun:8888`, and re-points byparr's FlareSolverr proxy to `gluetun:8191`. Uses SQLite's `json_set`, so it's idempotent.
6. **SABnzbd config** — stops SABnzbd (it rewrites `sabnzbd.ini` on shutdown, so a running instance would clobber the write), then injects the generated API key and the news-server account from `.env`, converges the staging layout, and adds `sabnzbd` to `host_whitelist`. SABnzbd's DNS-rebinding guard rejects any `Host` header that is not `localhost`, an IP literal, or whitelisted, and Prowlarr addresses it by service name; entries already in the list are kept. Idempotent.
7. **Storage paths** — `validate_storage_paths` checks each of `DOWNLOADS_DIR` / `COMPLETED_DIR` via `findmnt --target`: each must exist as a directory and (unless `ALLOW_NON_MOUNTPOINT=1`) must live on a mount that isn't `/`. Subdirectories of a mount count — `/mnt/videos/downloads` inside a `/mnt/videos` mount is fine. In interactive mode, offers to opt into `ALLOW_NON_MOUNTPOINT=1` if a path is on the root fs; in `--non-interactive` mode (used by `restore`), hard-fails. The systemd unit gets `RequiresMountsFor=` for these paths unless the opt-out is active.
8. **Systemd user service** — installs `~/.config/systemd/user/prowlarr-stack.service`, runs `daemon-reload + enable`.
9. **Start** — `docker compose up -d`.
10. **Wait for tunnel** — polls gluetun's healthcheck until green (60s timeout). Skipped entirely with no VPN configured.
11. **Tag torrent indexers** — `scripts/tag-vpn-indexers` puts the `vpn` tag on every enabled torrent-protocol indexer, so the proxy seeded in phase 5 actually applies to something. Runs before the check below, which would otherwise fail on an untagged indexer. Non-fatal.
12. **Verify isolation** — asserts every enabled torrent indexer carries the `vpn` tag, and that the tunnel's exit IP differs from the direct one. With no VPN, asserts instead that no enabled torrent indexer exists — one could not reach an ISP-blocked site, and would leak if it could. Dumps gluetun's recent log on failure.

`./setup --reconfigure` forces the configuration prompts to re-appear (existing values shown as defaults). `./setup --non-interactive` skips prompts and fails fast on any missing required variable — used by `./update`.

## Update phases

`./update` runs:

1. `git pull --ff-only`.
2. `./setup --non-interactive` — applies any config changes that arrived with the pull.
3. `docker compose pull` — fetch latest images.
4. `systemctl --user restart prowlarr-stack` — recreate containers.
5. `./check` — service health, Prowlarr's connection to each download client, VPN isolation.

Flags: `--code-only` (skips image pull), `--images-only` (skips git/setup), `--dry-run` (prints the plan without executing anything).

## Backup & restore

State surface (everything `./backup` captures):

- `.env` — VPN credentials, LAN config, qBittorrent password
- `config/prowlarr/` — `config.xml` + `prowlarr.db` (indexers, API key, app links, qBittorrent download-client row with host/port/password)
- `config/qbittorrent/qBittorrent/` — `qBittorrent.conf` (PBKDF2 password, all UI prefs) + `categories.json`

Excluded (regenerated by setup):

- `MANIFEST` — install inventory, refreshed after restore
- `.version` — pinned by the release on disk; restore keeps the receiving install's value

`./backup` flow: stop the stack → tar `.env` + `config/` + a small `BACKUP-MANIFEST` (schema/timestamp/source-host/stack-version) → restart. Output is `chmod 600`. Default location is `$HOME/prowlarr-stack-backup-<host>-<UTC>.tar.gz`; the script refuses to write into directories containing `.git/` or `.jj/` to prevent accidental commits to a public repo. The tarball contains your WireGuard private key — store it securely.

`./restore <tarball>` flow:

1. Validate the archive: no absolute paths, no parent-refs, only `.env` / `.envrc` / `config/` / `BACKUP-MANIFEST` entries (same safety walk as `install.sh` does on release tarballs).
2. Verify `BACKUP-MANIFEST` schema is `1`.
3. Stop the stack if running.
4. Snapshot existing state to `.env.pre-restore-<UTC>` and `config.pre-restore-<UTC>/` (rollback hatch).
5. Extract the backup over `.env` and `config/`.
6. **Scrub `HOST_LAN_IP` and `LAN_SUBNET` from the restored `.env`** — these are machine-specific and baked into Prowlarr's `DownloadClients` row in `prowlarr.db`. Setup's auto-detect branch fills them in for the receiving machine.
7. Run `./setup --non-interactive` — re-detects LAN, re-runs `scripts/patch-prowlarr-db` (rewrites the qBittorrent host in the JSON-encoded `Settings` blob to the new `HOST_LAN_IP`), re-runs `scripts/set-qbt-password` (regenerates the PBKDF2 hash with a fresh salt), refreshes the systemd unit, starts the stack, runs `./check`.
8. Refresh `MANIFEST` so it reflects the receiving install.

`./install --restore PATH` and `install.sh --restore PATH` are convenience wrappers: bootstrap a fresh extraction, then run the restore flow instead of interactive setup.

The reason a simple `cp .env config/` swap doesn't work cross-machine: the qBittorrent host in `DownloadClients.Settings` is JSON like `{"host":"192.168.1.10",...}`. If you restore on a machine whose LAN IP is `192.168.5.5`, Prowlarr will try to reach qBittorrent at `192.168.1.10:8080` and the API push will fail. Scrubbing the LAN keys forces re-detection and re-patching.

### Settings bundle

`./backup --settings-only` captures only **user-supplied** state — values you
decided or obtained from a third party, which no amount of re-running setup can
reproduce. `./restore --settings-only` merges them into an install that has
already been set up.

Three categories of state; only the third travels:

| Category | Examples | In a settings bundle |
|---|---|---|
| Stack-generated | Prowlarr `ApiKey`, `SABNZBD_API_KEY`, qBittorrent password, `COMPOSE_PROFILES`, download-client / indexer-proxy / tag rows | no |
| Machine-derived | `HOST_LAN_IP`, `LAN_SUBNET` | no — re-detected on the receiving host |
| User-supplied | storage paths, usenet account, Prowlarr `Indexers` rows, SABnzbd categories and tuning | yes |

Members:

| File | Contents |
|---|---|
| `SETTINGS-MANIFEST` | bundle format version, source stack version, indexer count |
| `env.subset` | `DOWNLOADS_DIR`, `COMPLETED_DIR`, `ALLOW_NON_MOUNTPOINT`, `USENET_SERVER_HOST`, `USENET_SERVER_USERNAME`, `USENET_SERVER_PASSWORD` |
| `indexers.json` | `Indexers` rows, carrying tag **labels** |
| `sabnzbd.subset.ini` | `[categories]` plus operator-tuned `[misc]` keys |

Indexer tags travel as labels, not ids. Tag ids are per-database, so an id
carried from the source install would point at a different tag — or at nothing —
in the target. Import resolves each label against the receiving database and
creates any tag that is missing.

Import merges rather than replaces. It lands on a stack setup has just
configured, so every write is a targeted key-set or an upsert keyed on the
indexer's `Name`; running it twice changes nothing. Export opens `prowlarr.db`
read-only and so does not stop the stack; import opens it read-write and does.
A full restore of a settings bundle, or a settings-only restore of a full
backup, is refused with a message naming the other flag.

The WireGuard private key is excluded. A full backup contains it and must be
stored accordingly; a settings bundle does not, which makes it the safer
artifact to keep around. `tests/settings_bundle_export.test` asserts its absence,
so the bundle cannot quietly widen into a full backup.

## Testing

`./scripts/test` runs a pure-bash test suite covering:

- Input validators (WireGuard key, IPv4, CIDR, VPN provider slug)
- LAN detection (parsing `ip route` and `ip addr` output via fixtures)
- Atomic `.env` read/write
- The Prowlarr DB patcher

No external dependencies — the test runner is bash and discovers `tests/*.test` files automatically.

## VCS

The project is tracked with plain **git**. Standard workflow:

- `git log --oneline` — history
- `git add -A && git commit -m "…"` — stage + commit
- `git push origin main` — publish (or use `./scripts/release vX.Y.Z`, which does this plus tagging)

## Release pipeline

The stack is distributed as versioned GitHub Releases. Workflow:

1. Maintainer edits `CHANGELOG.md` under `[Unreleased]` as they go.
2. At release time: rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`, open a new empty `[Unreleased]`, run `./scripts/bump-images` to update pinned upstream image versions, commit, tag `vX.Y.Z`, push the tag.
3. GitHub Actions' `release.yml` builds `prowlarr-stack-vX.Y.Z.tar.gz` from `git archive` (with `.version` injected), computes `SHA256SUMS`, parses the `[X.Y.Z]` block from `CHANGELOG.md`, and publishes a GitHub Release with all three.
4. End users install from the release via `install.sh` (curl-pipe) or by manually downloading the tarball. Both paths verify SHA256 before extraction and delegate to the tarball's `./install`.

CI (`ci.yml`) runs the same `./scripts/release-checks` (shellcheck + compose validate + bash tests) on every PR/push to `main`, and `release.yml` runs it again before building the tarball.

## MANIFEST

Every install writes `MANIFEST` at the install root — a plain-text inventory of everything the stack owns on your system:

- Files created under the install dir (with modes and roles).
- The systemd user unit path.
- The pinned upstream Docker images.
- Container names.
- Docker network name.
- External paths *referenced* by the stack but *not owned* (your `DOWNLOADS_DIR` and `COMPLETED_DIR`).

`./uninstall` reads MANIFEST and removes exactly what's listed. If MANIFEST is missing, it falls back to a best-effort removal based on hardcoded defaults and warns the user.

MANIFEST format (prefix-keyed plain text):

```
file:        <relative path>        mode:<octal>  role:<description>
dir:         <relative path>        mode:<octal>  role:<description>
systemd-unit: <absolute path>
image:       <image:tag>
container:   <name>
network:     <name>
external:    <absolute path>        role:<description>
```

## Update modes

`./update` detects mode from file markers:

- `.version` present → release mode (swap tarballs from GitHub Releases; preserves `.env`, `.envrc`, and `config/`).
- `.git/` present → git dev mode (`git pull --ff-only`).

Release mode also supports `--version vX.Y.Z` for pinning a specific release (any direction — newer or older) for upgrades and rollbacks.

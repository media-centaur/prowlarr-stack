# Per-indexer egress for prowlarr-stack

**Date:** 2026-09-17
**Status:** Approved design, pending implementation plan

## Glossary

| Term | Meaning in this document |
|------|--------------------------|
| **Indexer proxy** | Prowlarr's built-in per-indexer egress override. Four implementations exist: `FlareSolverr`, `Http`, `Socks4`, `Socks5`. |
| **Tag** | Prowlarr label joining indexers to an indexer proxy. A proxy applies to an indexer when their tag sets intersect; an untagged proxy applies to every indexer. |
| **Network namespace** | Docker's `network_mode: "service:gluetun"`. All-or-nothing membership — a container is wholly inside the tunnel or wholly outside it. |
| **Egress route** | Where a request leaves from: *direct* (the ISP connection) or *tunnel* (gluetun's WireGuard link). |
| **Profile** | Compose's `profiles:` key. A service carrying a profile is absent from the project unless that profile is active via `COMPOSE_PROFILES`. |
| **Kill-switch** | gluetun's firewall dropping any egress that is not through the tunnel, so a dropped tunnel means no traffic rather than leaked traffic. |
| **Protocol** | An indexer's `usenet` or `torrent` classification, exposed as `protocol` on `GET /api/v1/indexer`. |

## Goal

Make egress a property of the **upstream** rather than of the **stack**, so that
usenet indexers work without a VPN and torrent indexers still cannot reach the
ISP path.

Today Prowlarr shares gluetun's network namespace. That is all-or-nothing: every
indexer inherits the tunnel, and losing the tunnel takes every indexer with it.
A usenet-only install therefore cannot exist, and a lapsed VPN subscription
silently blinds a search stack that had no cryptographic reason to need one.

## Core idea

**Torrent traffic uses the tunnel; usenet traffic does not.** One rule, applied
consistently to both indexers and download clients.

The stack already holds this belief on the download-client side: SABnzbd runs
direct because "usenet has no peers/swarm — only the paid news-server sees your
IP over TLS", and qBittorrent's routing is a per-service choice
(`QBITTORRENT_USE_VPN`). The 2026-07-10 usenet spec made the same call
explicitly, rejecting a `SABNZBD_USE_VPN` overlay on the grounds that "usenet
doesn't benefit from VPN routing."

The rule was never applied to indexers, because the mechanism chosen for them —
namespace membership — cannot express "per upstream." The result is one rule
represented two different ways: an env toggle for clients, namespace membership
for indexers. This design collapses those into one.

## Four verified facts

These were checked against the running stack and Prowlarr's source, not assumed.

1. **Prowlarr proxies grabs, not only searches.** In `HttpIndexerBase`, the
   `Download` method — the `.torrent`/`.nzb` fetch — calls
   `_httpClient.ExecuteProxiedAsync(request, Definition)`, including inside its
   redirect-handling loop. `FetchReleases` uses the same call via its retry
   strategy. This is load-bearing: many torrent indexers are ISP-blocked, so an
   unproxied grab would fail outright, not merely deanonymise.
2. **Prowlarr 2.5.2 offers the proxy types needed.** `GET
   /api/v1/indexerproxy/schema` returns `FlareSolverr`, `Http` *(host, port,
   username, password)*, `Socks4`, and `Socks5`.
3. **gluetun ships an HTTP proxy.** Its startup settings tree lists "HTTP proxy
   settings: Enabled: no" and "Shadowsocks server settings: Enabled: no". Setting
   `HTTPPROXY=on` exposes a proxy on port 8888 inside the tunnel namespace.
4. **Compose profiles gate services from `.env`.** On Docker Compose 5.5.0, a
   service carrying `profiles: ["vpn"]` is absent from `docker compose config`
   unless `.env` sets `COMPOSE_PROFILES=vpn`, and `depends_on` between two
   services sharing a profile resolves normally. Applying the `qbt-vpn` overlay
   while the profile is inactive fails validation with `service "qbittorrent"
   depends on undefined service "gluetun": invalid compose project`.

## One unverified dependency

gluetun's HTTP proxy must accept inbound connections from sibling containers on
the compose bridge. gluetun's firewall governs its own INPUT chain, and while the
proxy exists to be consumed by other containers, this stack has never exercised
it. If bridge-inbound to 8888 is dropped by default, the fix is a
`FIREWALL_INPUT_PORTS=8888` entry on the gluetun service.

**This is the first thing the implementation plan verifies**, before any other
change lands — the whole torrent path depends on it. It could not be tested in
advance here because this machine's tunnel is down, so gluetun has no working
egress to prove a proxied request end to end.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| VPN presence | **Compose profile `vpn`** | Absence of VPN credentials is a configuration state, not a mode. Profiles express presence/absence natively while keeping the whole topology in one readable file. Rejected: a `VPN_ENABLED` flag threaded through existing structure (leaves two representations of routing); inverting base/overlay so the base file omits gluetun (achieves the same thing but splits the topology across files, and still needs overlays to *modify* services). |
| Indexer egress | **Per-indexer proxy, selected by tag** | The only mechanism that can express "this indexer needs the tunnel, that one doesn't". Already proven in this stack — byparr is wired exactly this way. |
| Prowlarr placement | **Direct, publishes its own 9696** | Usenet search must survive tunnel loss. Prowlarr's own egress becomes the ISP path; tunnel access comes from the proxy. |
| byparr placement | **Stays in gluetun's namespace, profile-gated** | Cloudflare solving serves torrent indexers only, so byparr is torrent-side by definition. Namespace membership remains the right mechanism for a headless browser — there is no per-request routing to express. |
| Proxy transport | **`Http` to `gluetun:8888`, no auth, not published to the host** | Reachable only across the compose bridge. `Socks5` is equivalent here; HTTP is the simpler of the two to seed and to debug. Credentials add a secret to rotate for no boundary gained. |
| Tagging | **`setup` auto-tags every torrent-protocol indexer, idempotently, via `scripts/tag-vpn-indexers`** | Matches the stack's philosophy — setup wires everything, the user supplies only credentials. A rule that is enforced beats a rule that is documented. Implemented as a script rather than a migration because protocol is only available from the API, not the database. |
| Isolation verification | **Per-indexer tag assertion replaces the exit-IP comparison** | Prowlarr's exit IP is now always the ISP, making the old comparison meaningless. Asserting each torrent indexer's tag checks the actual intent rather than inferring it from a container's exit IP. |
| Existing installs | **Automatic migration on `./update`** | The stack is a product with a migration mechanism; no manual step. |

## Routing model

| Upstream | Route | Mechanism |
|----------|-------|-----------|
| Usenet indexers | Direct | no tag |
| Torrent indexers | Tunnel | `vpn` tag → `Http` proxy → `gluetun:8888` |
| Cloudflare-gated torrent indexers | Tunnel | `byparr` tag → `FlareSolverr` proxy → `gluetun:8191` |
| Prowlarr → SABnzbd / qBittorrent API | Compose bridge | container DNS |
| SABnzbd | Direct | unchanged |
| qBittorrent | Direct, or tunnel | `QBITTORRENT_USE_VPN`, unchanged |

With no VPN configured, the `vpn` profile is inactive: gluetun and byparr are
absent, nothing backs the `vpn` tag, torrent indexers are unusable, and usenet is
unaffected. That is an ordinary supported configuration, not a degraded one.

## Components

### 1. `docker-compose.yml`

- `prowlarr`: drop `network_mode` and `depends_on`; add `ports: ["9696:9696"]`.
- `gluetun`: add `profiles: ["vpn"]` and `HTTPPROXY=on`. Its `ports` list keeps
  `8191:8191` (byparr, for human debugging) and drops `9696:9696`, which Prowlarr
  now publishes itself. Port 8888 is **not** published — bridge-only.
- `byparr`: add `profiles: ["vpn"]`. Namespace membership and `depends_on` are
  unchanged.
- `sabnzbd`, `qbittorrent`: unchanged.

`docker-compose.qbt-vpn.yml` is unchanged. It remains valid only alongside the
`vpn` profile, which Compose enforces at validation time (fact 4).

### 2. `.env` and `setup`

- `VPN_SERVICE_PROVIDER` and `WIREGUARD_PRIVATE_KEY` become **optional**. When
  absent, `setup` skips the VPN prompts, the tunnel wait, and the gluetun/byparr
  wiring entirely.
- `setup` writes `COMPOSE_PROFILES=vpn` when VPN credentials are present, and
  omits the variable otherwise.
- `QBITTORRENT_USE_VPN=1` requires VPN credentials; `setup` refuses the
  combination rather than writing a project Compose will reject.
- Prowlarr → SABnzbd/qBittorrent host resolution stops needing `HOST_LAN_IP`.
  Prowlarr now sits on the compose bridge with the clients, so the download-client
  rows use container DNS: `sabnzbd:8080` always, and for qBittorrent
  `qbittorrent:8080` when direct or `gluetun:8080` when tunneled — a tunneled
  client shares gluetun's namespace and so has no DNS name of its own. This
  removes the netns workaround documented in the 2026-07-10 spec. `LAN_SUBNET` is
  retained for gluetun's `FIREWALL_OUTBOUND_SUBNETS`, which still serves byparr
  and tunneled qBittorrent.

### 3. Prowlarr database seeding (`setup`)

Extends the existing `json_set`-based idempotent patching:

- Ensure a `vpn` tag exists.
- Ensure an `Http` indexer proxy named `VPN` exists, pointed at `gluetun:8888`,
  carrying the `vpn` tag. Present only when the profile is active.
- Re-point the existing `FlareSolverr` proxy from `http://localhost:8191/` — which
  worked only because Prowlarr shared byparr's namespace — to `http://gluetun:8191/`.
- Auto-tagging torrent indexers is **not** done here. The `Indexers` table stores
  no protocol column — `Implementation` is `Newznab`, `Torznab`, or `Cardigann`,
  and Cardigann is definition-driven and may be either protocol. Protocol is only
  reliably available from `GET /api/v1/indexer`, so tagging lives in a new
  `scripts/tag-vpn-indexers`, a sibling of the existing `scripts/tag-cf-indexers`,
  which `setup` invokes once the stack is up.

### 4. `check` and `scripts/lib/common`

- The fatal gluetun health gate becomes conditional on the `vpn` profile.
- `verify_services` probes Prowlarr **directly** rather than through the gluetun
  container (`wait_for_http gluetun "http://127.0.0.1:9696/ping"` → prowlarr).
  byparr's probe stays namespace-relative and runs only under the profile.
- `verify_isolation` is rewritten against the Prowlarr API, reading the API key
  from `config/prowlarr/config.xml` as the documented helpers already do:
  - **VPN configured:** every enabled `protocol = torrent` indexer carries the
    `vpn` tag; the tunnel's exit IP (via `fetch_container_external_ip gluetun`)
    differs from the direct exit IP (via `fetch_container_external_ip prowlarr`);
    and when `QBITTORRENT_USE_VPN=1`, qBittorrent's exit IP matches the tunnel's.
  - **No VPN configured:** no enabled `protocol = torrent` indexer exists. If one
    does, fail with a message naming it — it cannot reach an ISP-blocked site and
    would leak if it could.

  `fetch_container_external_ip` is reused as-is; only its subjects change.

### 5. `migrations/0004-per-indexer-egress`

For installs created before this change:

- Write `COMPOSE_PROFILES=vpn` into `.env` when VPN credentials are present, so
  existing VPN users keep gluetun and byparr.
- Re-point the `FlareSolverr` proxy host to `gluetun:8191`.
- Create the `vpn` tag and the `Http` proxy row. Indexer tagging is left to
  `scripts/tag-vpn-indexers`, which `setup` runs after start — so existing
  installs are tagged during the same `./update` that applies this migration.

The migration is idempotent and follows the numbered-directory convention of
`0001`–`0003`.

### 6. Documentation

- `README.md` line 5 currently reads "Indexer queries (and optionally torrent
  traffic) are routed through a WireGuard VPN tunnel — that's the point of this
  stack," and points VPN-less users at bare `linuxserver/prowlarr`. The product's
  identity changes to *torrent* traffic through the tunnel, and the redirection
  is removed: usenet-only is now supported here.
- `docs/architecture.md` §Traffic routing: both topology tables are restated per
  upstream rather than per container, and the kill-switch section is amended —
  Prowlarr no longer loses connectivity with the tunnel, but tagged indexers
  still do, because gluetun's proxy listens only inside the tunnel namespace.
- `docs/indexers.md`: adding a torrent indexer after install requires the `vpn`
  tag; `./check` verifies it.
- `CHANGELOG.md`.

## The fail-open regression

Namespace membership is fail-closed: a leak is structurally impossible, because
Prowlarr has no route except the tunnel. Per-indexer proxying is fail-open — a
torrent indexer added without the `vpn` tag queries over the ISP path and nothing
objects. This is a genuine property being traded away and is recorded here rather
than glossed.

Mitigation, using machinery the repo already has:

1. `setup` auto-tags torrent indexers, so the common path never depends on the
   user remembering.
2. `check` asserts the invariant, and `./update` gates on `check`, so drift fails
   the upgrade.
3. Tagged traffic still fails closed: gluetun's proxy listens only inside the
   tunnel namespace, so a dropped tunnel yields connection-refused, never a
   fallthrough to the ISP.

The residual gap is an indexer added **between** runs of `setup` and `check`.
Accepted and documented rather than closed with a reconciler: Prowlarr exposes no
"indexer added" hook, a polling reconciler is machinery this stack does not
otherwise need, and the failure is self-announcing for precisely the ISP-blocked
sites that motivate the tunnel.

## Testing

The repo's per-component `.test` convention is extended:

- `compose_profiles.test` — profile on/off yields the expected service set; the
  `qbt-vpn` overlay without the profile fails validation.
- `verify_isolation.test` — rewritten for the tag assertion, covering: VPN with a
  correctly tagged indexer, VPN with an untagged torrent indexer, and no-VPN with
  an enabled torrent indexer.
- `verify_services.test` — updated for the direct Prowlarr probe.
- `patch_prowlarr_db.test` — extended for the tag, proxy, and byparr re-point.
- `migration_0004.test` — new, mirroring `migration_0001`–`0003`.

## Out of scope

- A reconciler for indexers added between `setup`/`check` runs (see above).
- `Socks5` or Shadowsocks as the proxy transport — equivalent here, no gain.
- Download-client routing, which is unchanged.
- Per-indexer routing for anything other than the tunnel.

# Safe self-upgrading releases + opt-in downstream auto-update

**Date:** 2026-07-09
**Status:** Approved (design), pending implementation
**Scope:** prowlarr-stack source repo (`~/src/media-centaur/prowlarr-stack`)

## Problem

Pinned container images silently rot. FlareSolverr v3.5.0 sat stale until it
stopped defeating Cloudflare; nobody noticed until an indexer test failed. More
generally there is no automated path to keep the four images
(gluetun, prowlarr, flaresolverr, qbittorrent) current, and no way for a
downstream user to receive upgrades unattended without risking a broken stack.

Upgrading cannot be reduced to `docker compose pull`: images are pinned on
purpose for reproducible installs, qBittorrent must stay on the libtorrent-v2
tag line (`_v2`) or `.fastresume` data breaks, and the VPN-isolation invariant
(prowlarr egresses only through gluetun) must hold after every change.

## Goal

Make a release **safe to apply unattended**, so that any downstream user — not
just the maintainer's install — can opt into automatic upgrades and trust that a
bad release rolls itself back instead of leaving a broken stack.

## Design overview

Two halves. Build **Half A first**; Half B is worthless without it (auto-applying
an unsafe release is worse than manual upgrading).

- **Half A — the release becomes safe to auto-apply.** Turn `./update` from
  "apply and hope" into a transaction: snapshot → apply → migrate → verify →
  auto-rollback on failure. Plus an opt-in downstream systemd timer.
- **Half B — the release gets produced automatically.** A scheduled GitHub
  Action discovers newer upstream image tags and opens a bump PR. Outlined here,
  specced separately.

Existing primitives this composes (already in the repo):

| Primitive | Role |
|-----------|------|
| `backup` / `restore` | rollback snapshot + restore |
| `check` (gluetun healthy + `verify_isolation`) | the verification gate |
| `scripts/patch-prowlarr-db` | the pattern a migration follows (idempotent mutate → verify → fail loud) |
| `scripts/bump-images` (maintainer-editable `REPOS`) | bump primitive Half B automates |
| `update` release-mode | stop → preserve → swap → setup → pull → start → wait-healthy → check |

---

## Half A — safe transactional apply

### Current release-mode flow (`update` → `release_mode_update`)

```
stop → preserve(.env,.envrc,config) → swap(wipe+extract) → restore state
     → refresh MANIFEST → setup --non-interactive → compose pull → start
     → wait gluetun healthy (60s) → check
```

Gaps: no pre-upgrade snapshot, no migration step, and on any post-swap failure it
just `die`s — leaving the install on the new, broken version.

### New flow

```
record prev=$(cat .version)
pre-flight backup (stops stack)  →  swap_to_release(target)  →  restore state
    →  setup  →  compose pull  →  run_migrations(prev→target)  →  start
    →  wait gluetun healthy  →  check
    ──(any failure after backup)──►  ROLLBACK
```

#### A0. Pre-flight snapshot

Record `prev=$(cat .version)`, then run `./backup --yes --output <rollback-slot>`
(this stops the stack, replacing the separate stop step, so the SQLite snapshot
is consistent). The backup already captures `.env` + `config/` at mode 600. The
rollback slot is `$tmp/rollback.tar.gz` for the duration of the run — sufficient
for auto-rollback within the same invocation. (`./backup` also writes a durable
copy to `$HOME` by default, so a post-hoc manual recovery path exists without a
dedicated persistent slot.) Release tarballs on GitHub are immutable, so previous
*code* is always re-fetchable by version; only mutable state (`config/`, `.env`)
needs snapshotting.

#### A1. Migrations

New `migrations/` directory. Each migration is a versioned, **idempotent,
extensionless** executable (matches the no-`.sh` rule), named `NNNN-slug`
(monotonic integer + kebab slug), e.g. `0001-flaresolverr-orphan-tags`.

- **Runner:** `scripts/run-migrations <from> <to>` (also sourced by `update`).
  Iterates `migrations/*` in sorted order, runs each id not present in the
  applied-set, appends its id on success. Invoked in **both** release and dev
  (`jj`/`git`) update modes.
- **State:** applied ids live in `config/.migrations` (one id per line). Lives in
  `config/` so it is preserved across release swaps and captured by `backup`.
- **Idempotency:** migrations must be safe to re-run regardless of the state
  file (the state file is a record/optimization, not the sole guard) — same
  contract as `patch-prowlarr-db`.
- **No baseline (revised during implementation):** an earlier design stamped a
  "baseline" of applied ids during `setup` so fresh installs skipped history.
  That was wrong — `setup` runs on every `./update`, so it stamped migrations as
  applied *before* the migration step could run them, permanently skipping them
  on existing installs. Removed entirely: migrations are idempotent and no-op on
  already-correct/freshly-seeded state, so they simply always run and converge.
- **Scope:** general-purpose — a migration may touch anything under the install
  dir, receiving the install dir as `$1`. Convention: most operate on `config/`
  data. Env/compose *shape* changes ride in with the release tarball; migrations
  fix up *existing* state to match the new shape.
- **Failure:** a migration exiting non-zero triggers ROLLBACK.

**Migration `0001-flaresolverr-orphan-tags`** (retroactive, encodes the fix that
motivated this work): in `config/prowlarr/prowlarr.db`, strip from every
`IndexerProxies.Tags` array any tag id not present in the `Tags` table. Orphaned
tag references scope the FlareSolverr proxy to a nonexistent tag, so Prowlarr
never routes through it and Cloudflare-gated indexer tests fail. Emptying the
array (no tags = applies to all indexers) is the correct end state. Idempotent;
verifies no orphaned ids remain; no-op when `prowlarr.db` absent.

#### A2. Verify + auto-rollback

Wrap post-start verification. Any of {migration failed, gluetun not healthy
within timeout, `./check` failed} triggers ROLLBACK instead of `die`.

**ROLLBACK procedure:**
1. Restore `config/` + `.env` from the pre-flight backup (overwriting any
   partially-migrated state).
2. `swap_to_release(prev)` — re-fetch + extract the previous release tarball
   (refactor the existing swap logic into a function both forward-upgrade and
   rollback call).
3. `setup` → `compose pull` (prev images still cached) → `start` → wait healthy
   → `check`.
4. Report outcome: `rolled back <target> → <prev>, stack healthy` on success;
   **loud alarm** (non-zero exit, journal-visible) if rollback itself fails.

**Escape hatch:** `--no-rollback` flag for maintainers debugging a bad release
(leaves the failed state in place for inspection).

#### A3. Opt-in downstream auto-update timer

- `defaults/prowlarr-stack-update.service` (user unit): `ExecStart=<install>/update --yes`.
- `defaults/prowlarr-stack-update.timer`: weekly (e.g. `OnCalendar=Sun 04:00`,
  `RandomizedDelaySec=1h`, `Persistent=true`).
- **Opt-in.** Shipped, not enabled. Enabled via a `setup` prompt or
  `./update --enable-auto` / `--disable-auto` (installs/removes the units and
  toggles the timer).
- **Notification on failure.** The service exits non-zero on a failure that
  survives rollback (journal-visible via `systemctl --user status`). Optional:
  if `UPDATE_NOTIFY_CMD` is set in `.env`, the update invokes it with a one-line
  message on rollback-or-worse. Kept minimal (YAGNI) — no built-in mailer.

### Flags added to `update`

| Flag | Effect |
|------|--------|
| `--enable-auto` / `--disable-auto` | install+enable / disable the systemd timer |
| `--no-rollback` | on failure, leave broken state in place (debugging) |

---

## Half B — automated discovery (outline; separate spec)

Scheduled GitHub Action in the source repo (`.github/workflows/discover-image-updates.yml`),
weekly. A non-interactive mode of `bump-images` queries each image's registry
(Docker Hub API for `linuxserver/*` + `qmcgaw/*`, GHCR for flaresolverr) for the
newest tag matching a **per-image constraint regex** (qBittorrent constrained to
the `_v2` libtorrent line), bumps `docker-compose.yml`, updates
`CHANGELOG.md [Unreleased]`, and opens a PR. Maintainer merges + tags → existing
release pipeline cuts the release → downstream timers apply it safely via Half A.

Full pipeline once both halves exist:

```
upstream tag → [GH Action] discovery PR → maintainer merge+tag → release
            → [downstream timer] safe auto-apply (backup → migrate → verify → rollback-on-fail)
```

Out of scope for this spec: the discovery workflow's registry-query logic and
constraint config are detailed in a follow-on spec.

---

## Non-goals

- App-internal DB migrations (Prowlarr's own schema upgrades) — handled by the
  app on startup, not by stack migrations.
- Un-pinning images / floating tags — defeats reproducibility.
- Auto-applying without rollback safety — the entire point is safety-by-construction.
- Choosing FlareSolverr vs. a replacement (byparr) — a separate one-time decision;
  discovery can only flag a newer tag, not swap the component.

## Testing

Extend the existing `tests/` harness (run by `scripts/release-checks`):

1. **Migration runner:** applies pending, skips already-applied, is idempotent on
   re-run, fails loud on a non-zero migration, stamps baseline on fresh setup.
2. **Migration 0001:** seed a `prowlarr.db` with an orphaned FlareSolverr proxy
   tag → assert orphaned ids removed and proxy applies to all indexers → assert
   re-run is a no-op → assert no-op when `prowlarr.db` absent.
3. **Rollback:** simulate a post-swap verify failure → assert install restored to
   `prev` version with `config/` intact and stack healthy.
4. **Timer enable/disable:** `--enable-auto` installs+enables units; `--disable-auto`
   reverses it.

## Build order

1. Migration runner + state + `setup` baseline stamping.
2. Migration `0001-flaresolverr-orphan-tags`.
3. Refactor swap into `swap_to_release`; add pre-flight backup + auto-rollback.
4. Opt-in timer units + `--enable-auto` / `--disable-auto`.
5. Tests for all of the above; wire into `release-checks`.
6. (Follow-on) Half B discovery workflow — separate spec.

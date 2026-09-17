# Upgrading

Two audiences: **operators** running an installed stack, and the **maintainer**
cutting new releases. Both use `./update`; only the maintainer touches the
source repo + tags.

## Operator: upgrading an install

```sh
~/prowlarr-stack/update
```

This is a **transaction** — it either lands on the new version healthy, or rolls
itself back to the version you were on. Steps:

1. **Pre-flight backup** — stops the stack and snapshots `.env` + `config/` (so a
   failure is recoverable).
2. **Fetch + verify** — downloads the latest GitHub release, checks its SHA256,
   validates the archive, and swaps in the new code while preserving your
   `.env`/`config/`.
3. **Setup + images** — re-runs `setup --non-interactive`, pulls images.
4. **Migrations** — runs any pending idempotent DB fixups (`migrations/`, tracked
   in `config/.migrations`).
5. **Verify** — waits for gluetun to go healthy, then runs `./check`, which is
   the **upgrade gate**: the check whose exit status decides whether the new
   version stands or is rolled back. It asserts two things, both fatal:
   *service health* (Prowlarr's `/ping`, byparr's `/health`, and SABnzbd's
   version endpoint all answer, with a retry window that absorbs slow starts)
   and *VPN isolation* (Prowlarr via the tunnel, qBittorrent per its mode).
   Both run even when the first fails, so one invocation reports everything
   that is broken.
6. **Auto-rollback** — if a migration fails, gluetun never goes healthy, or
   either half of the upgrade gate fails, the install is restored to the previous
   release from the pre-flight backup and restarted. A rollback that itself fails
   exits loudly with the backup path so you can `./restore` by hand.

### Flags

| Flag | Effect |
|------|--------|
| `--version vX.Y.Z` | install a specific release — upgrade, downgrade, or **roll back** |
| `--yes` | skip the confirmation prompt |
| `--dry-run` | print the plan, execute nothing |
| `--no-rollback` | on failure, leave the broken state in place (debugging only) |
| `--code-only` | (dev mode) pull source + re-setup, no image pull/restart |
| `--images-only` | (dev mode) pull images + restart only |
| `--enable-auto` | install + enable a weekly unattended-upgrade systemd timer |
| `--disable-auto` | disable + remove that timer |

### Unattended upgrades

```sh
~/prowlarr-stack/update --enable-auto     # weekly, Sun ~04:00, auto-rollback on failure
~/prowlarr-stack/update --disable-auto
```

Safe to enable because the upgrade is transactional. Optional: set
`UPDATE_NOTIFY_CMD` in `.env` to a command that gets invoked on a failure that
survived rollback.

### Rolling back manually

```sh
~/prowlarr-stack/update --version vX.Y.Z --yes   # any earlier release
```

Release tarballs are immutable, so any past version is reinstallable. Your
`.env`/`config/` are preserved across the swap.

## Maintainer: bumping pinned images

Every image is pinned to an exact tag, so a bump is a deliberate, reviewable
change rather than something that drifts in. The hard part is not editing the
pin — it is deciding whether existing installs need a **migration**: an
idempotent fixup in `migrations/` that converges old on-disk state onto what
the new image expects.

`./setup` seeds `config/` from `defaults/` **only when a file is absent**, so an
upgrade never overwrites an operator's config. That is the whole reason
migrations exist: nothing else rewrites state that already exists on disk.

### What state each image owns

This is the input to the migration decision. A bump can only need a migration
if it changes how the new image reads state we wrote, or state a *previous*
version of that image wrote.

| service | state it owns | what a bump can break |
|---|---|---|
| prowlarr | `config/prowlarr/prowlarr.db`, `config.xml` | Prowlarr migrates its own schema on start. Our migrations write into `DownloadClients`, `Tags`, and `IndexerProxies` — if those change shape, migration SQL breaks, including on fresh installs (which run the whole set) |
| qbittorrent | `qBittorrent.conf`, `categories.json`, `.fastresume` files | switching libtorrent line (v1 ↔ v2) invalidates resume data; config keys can be renamed across majors |
| sabnzbd | `config/sabnzbd/sabnzbd.ini` | SAB rewrites the ini on shutdown and versions it via `__version__`. `scripts/set-sab-config` writes `[misc] api_key/complete_dir/script_dir`, `[[server1]]` news-server fields, and `pp`/`script` in every category — a rename in any of those silently stops taking effect |
| gluetun | none (environment only) | env-var renames or removals break `docker-compose.yml` directly |
| byparr | none | it is reached only through the FlareSolverr `/v1` protocol on port 8191 — a protocol change breaks Prowlarr's indexer proxy |

### Pre-bump checklist

Run this per service being bumped. Prefer evidence over release notes: booting
the candidate image against a copy of real state answers the question directly,
where notes only hint at it.

1. **Resolve the current stable tag.** For Docker Hub images, resolve the digest
   behind `latest` and take the sibling semver tag — sorting tags by date
   surfaces nightlies. For byparr, use its GitHub releases.
2. **Read the upstream release notes** between the pinned and candidate tag,
   looking only for the state in the table above.
3. **Prowlarr — diff the schema empirically.** Boot the candidate against a
   *copy* of `defaults/prowlarr/prowlarr.db` on `--network none`, let it migrate,
   then compare `.schema` for `DownloadClients`, `Tags`, and `IndexerProxies`
   against the old DB, and re-run all of `migrations/` against the result. They
   must all still be clean no-ops. Then **regenerate
   `tests/fixtures/prowlarr.db.seeded`** the same way, so the migration tests run
   against the schema installs will actually have.
4. **qBittorrent — confirm the libtorrent line is unchanged.** The tag encodes
   it (`5.2.3_v2.0.14` is libtorrent v2). Crossing v2 → v1 or back invalidates
   every operator's `.fastresume` data and needs an explicit migration plus a
   loud changelog note.
5. **SABnzbd — confirm the ini keys survive.** Boot the candidate against a copy
   of `defaults/sabnzbd/sabnzbd.ini`, stop it so it rewrites the file, and check
   that `__version__` and every key `set-sab-config` writes are still present in
   the same sections.
6. **gluetun — diff env vars** against the seven `docker-compose.yml` sets.
7. **byparr — verify the FlareSolverr contract.** `POST /v1` with
   `{"cmd":"request.get","url":"https://example.com","maxTimeout":60000}` must
   return `status: ok` and a `solution` object carrying `status`, `url`,
   `response`, `cookies`, `headers`, and `userAgent`. Also time `/health`: it
   drives a real browser and is slow (~7.5s on byparr 3.x through the tunnel).
   If a future version gets slower still, raise `HTTP_PROBE_TIMEOUT` in
   `verify_services` — a probe that outruns the endpoint reports a healthy
   solver as dead and rolls back a good upgrade.
8. **Record the verdict in `CHANGELOG.md` — including when it is "no migration
   needed", and how you established that.** This is the durable artifact. The
   next person bumping the same image needs to know the question was asked and
   answered, not just that a number changed.

Then edit the pins (`scripts/bump-images` walks each service interactively) and
cut the release as below.

### After the bump

`./update` will exercise the real thing on a live stack, and the upgrade gate
now covers all four application services — so a bump that breaks byparr or
SABnzbd rolls back instead of landing silently. That gate is a backstop, not a
substitute for the checklist: it proves a service answers, not that it still
does its job correctly.

## Maintainer: cutting a release

Durable changes (image bumps, scripts, migrations) live in the **source repo**
(`~/src/media-centaur/prowlarr-stack`), never in an install — `./update` in
release mode wipes and re-extracts the install dir, so edits there are transient.
Image bumps have their own checklist in *Bumping pinned images* above.

1. **Make the change** in the source repo. For image pins, `scripts/bump-images`
   walks each service interactively.
2. **Add a migration** if existing installs need a data fixup — a new
   `migrations/NNNN-slug` executable, idempotent and a no-op on already-correct
   state. Add a `tests/*.test` for it. For image bumps, work the checklist in
   *Bumping pinned images* above to decide whether one is needed at all.
3. **Commit** the change on `main`. Leave `CHANGELOG.md` alone: the release step
   writes the version section from the notes you give it.
4. **Cut it** with the `/ship` skill (`/ship patch`, `minor` or `major`), which
   drives `scripts/ship`:

   ```sh
   scripts/ship prepare patch                 # last tag, next version, notes path
   scripts/ship check                         # upgrade-path gate; FAILED: list on any problem
   scripts/ship release patch --notes <file>  # changelog section, commit, push main, tag, push tag
   scripts/ship verify                        # waits for release.yml to publish the tarball
   ```

   The notes file is the body of the `## [X.Y.Z]` section only — `### Fixed` /
   `### Changed` / `### Added` bullets — and `release` adds the header the
   release workflow parses. `check` flags edits to a shipped migration, changes
   to a seed file under `defaults/` that existing installs would never receive,
   and new `.env.example` variables; each names the `--allow-*` flag to pass once
   you have confirmed the criterion it states. It also runs
   `./scripts/release-checks` (same as CI) and checks the entry points in
   `git archive HEAD`. `.claude/ship-profile.md` holds the rest.

Operators then get it via `./update`.

## Relationship to backup/restore

`./update` takes its own pre-flight backup for rollback. `./backup` / `./restore`
are the separate, portable snapshot tools (see the README) — use them for
migrating to a new machine or keeping durable off-box copies.

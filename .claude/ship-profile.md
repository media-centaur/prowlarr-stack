# prowlarr-stack ship profile

Consumed by the user-level `ship` skill. Only what is local to prowlarr-stack lives here.

**Audience:** people running the stack on their own machine — operators, not
engineers. Notes land on the GitHub release page and in `CHANGELOG.md`.

**Changelog format:** keepachangelog, matching the existing entries. Group bullets
under `### Fixed` / `### Changed` / `### Added` — not New/Improved — and lead each
with a bold plain-language summary. `.github/workflows/release.yml` extracts the
`## [X.Y.Z]` block verbatim as the release body, so the notes file is the body only:
`scripts/ship release` writes the `## [X.Y.Z] - YYYY-MM-DD` header. Leave
`## [Unreleased]` alone; it stays at the top with its empty subheadings.

**Version source of truth:** the git tag. There is no version file in the repo;
`release.yml` injects the tag into the tarball as `.version`, which is what an
installed stack reads. Never tag by hand.

**Prerequisite:** `./scripts/release-checks` (shellcheck + compose validate + bash
tests). `scripts/ship check` runs it again unless `--fast`.

**`scripts/ship check` runs** the upgrade-path gate: what the previous release's
`./update` needs from the code it swaps in, and what existing installs will and
won't receive. It exports `git archive HEAD` and checks the entry points there, so
an uncommitted `chmod +x` cannot mask a broken tarball. Seconds, not minutes.

**`verify` expects:** `prowlarr-stack-vX.Y.Z.tar.gz` + `SHA256SUMS`.

## Judgment gates

- **A shipped migration edited** (a `migrations/NNNN-*` that existed at the last tag)
  → `--allow-migration-change`. An install records applied migrations in
  `config/.migrations` and never re-runs one, so an edit leaves upgraded installs on
  the old outcome while fresh installs get the new one. Overridable only for a
  comment or message change with no behavioural effect. New migrations are additive
  and never flagged; each needs a `tests/migration_NNNN.test`, which is a hard failure.
- **A seed file under `defaults/` changed** (except `move-finished.sh` and the systemd
  units, which `./setup` refreshes on every run) → `--allow-seed-change`. Seeds copy
  only when the destination is absent, so existing installs never receive the change.
  Overridable when `./setup` converges existing installs on the same change through
  `scripts/set-sab-config` or the DB patchers (as `--category-pp 3` and
  `--whitelist-host sabnzbd` do), or when the change is fresh-install-only by design.
- **A new variable in `.env.example`** → `--allow-env-change`. `./update` runs
  `./setup --non-interactive`, which fails fast on a missing required variable — a
  new required one fails every upgrade and rolls it back. Overridable when the
  variable is optional or `setup` supplies a default.

## Extra steps

None. To take the release on a local install, run `./update --yes` there; its
`./check` gate rolls the upgrade back on failure.

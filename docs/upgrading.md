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
5. **Verify** — waits for gluetun to go healthy, then runs `./check`
   (VPN-isolation: Prowlarr via VPN, qBittorrent per its mode).
6. **Auto-rollback** — if a migration fails, gluetun never goes healthy, or the
   isolation check fails, the install is restored to the previous release from
   the pre-flight backup and restarted. A rollback that itself fails exits loudly
   with the backup path so you can `./restore` by hand.

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

## Maintainer: cutting a release

Durable changes (image bumps, scripts, migrations) live in the **source repo**
(`~/src/media-centaur/prowlarr-stack`), never in an install — `./update` in
release mode wipes and re-extracts the install dir, so edits there are transient.

1. **Make the change** in the source repo. For image pins, `scripts/bump-images`
   walks each service interactively.
2. **Add a migration** if existing installs need a data fixup — a new
   `migrations/NNNN-slug` executable, idempotent and a no-op on already-correct
   state. Add a `tests/*.test` for it.
3. **Update `CHANGELOG.md`** — move items from `[Unreleased]` into a new
   `## [X.Y.Z] - YYYY-MM-DD` section (the release workflow parses this block for
   the GitHub Release notes).
4. **Commit** the change (and the CHANGELOG) on `main`.
5. **Cut it:**

   ```sh
   ./scripts/release vX.Y.Z
   ```

   `scripts/release` does the rest deterministically: verifies the CHANGELOG has a
   `## [X.Y.Z]` section, runs `./scripts/release-checks` (shellcheck +
   `docker compose config` + the bash test suite — same as CI), pushes `main`,
   tags `vX.Y.Z`, pushes the tag (triggering `.github/workflows/release.yml`,
   which rebuilds the checks and publishes `prowlarr-stack-vX.Y.Z.tar.gz` +
   `SHA256SUMS`), then waits for CI and confirms the release published. Use
   `--dry-run` to gate without pushing, `--yes` to skip the prompt.

Operators then get it via `./update`.

## Relationship to backup/restore

`./update` takes its own pre-flight backup for rollback. `./backup` / `./restore`
are the separate, portable snapshot tools (see the README) — use them for
migrating to a new machine or keeping durable off-box copies.

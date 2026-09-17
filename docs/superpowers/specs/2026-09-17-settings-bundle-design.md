# Settings bundle for prowlarr-stack

**Date:** 2026-09-17
**Status:** Approved design, pending implementation plan

## Glossary

| Term | Meaning in this document |
|------|--------------------------|
| **Stack-generated** | A value `setup` creates on its own: Prowlarr's `ApiKey`, `SABNZBD_API_KEY`, the qBittorrent password hash, `COMPOSE_FILE`, `COMPOSE_PROFILES`, the download-client / indexer-proxy / tag rows it wires. Reproducible by re-running `setup`. |
| **Machine-derived** | A value auto-detected per host: `HOST_LAN_IP`, `LAN_SUBNET`. Reproducible, and *must* be re-detected on a new host. |
| **User-supplied** | A value a human decided or obtained from a third party. Not reproducible by any amount of re-running `setup` — losing it means re-entering it by hand. |
| **Settings bundle** | A portable archive of the user-supplied set alone. Produced by `./backup --settings-only`, applied by `./restore --settings-only`. |
| **Merge** (vs **replace**) | A settings-only restore writes its values *into* an existing install, leaving everything else as `setup` created it. A full restore replaces `.env` and `config/` wholesale. |

## Goal

Let an operator rebuild their install from scratch — through the ordinary
installer, exactly as a new user would — without re-entering anything a human
had to decide or fetch from a third party.

Today the only granularity is all-or-nothing. `./backup` captures `.env` plus
the whole of `config/`, which carries stack-generated and machine-derived values
along with the user's own. Restoring it reproduces the *old install*, including
whatever drift it had accumulated. There is no way to say "keep my directories
and my indexers, regenerate everything else."

That gap has a second cost: it makes the **fresh-install path untestable in
practice**. `./install` is the path every new user takes, and nothing exercises
it, because exercising it means losing your configuration.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bundle contents | **User-supplied set + SABnzbd settings** | Owner's call. Storage paths, usenet account, Prowlarr indexer rows, and the SABnzbd keys that are the operator's rather than the stack's. |
| Mechanism | **`--settings-only` flag on `./backup` and `./restore`** | One backup concept with a scope flag, rather than a second parallel export/import mechanism covering overlapping data. Reuses the existing tarball validation, rollback snapshots, and refuse-to-write-into-a-git-directory guard. |
| Restore semantics | **Merge, never replace** | A settings-only restore lands on a freshly-installed stack. Replacing `.env` would destroy the API keys and profile `setup` just generated. |
| Indexer identity | **Tags exported by label, resolved to ids on import** | Tag ids are per-database. A fresh install's `byparr` tag may have a different id, so carrying raw ids would mis-tag indexers. |
| Secret handling | **Same guards as `./backup`** | The bundle holds a usenet password and indexer API keys. Mode 600, and refuse to write into a directory containing `.git/` or `.jj/`. |

## What is in the bundle

### From `.env`

| Key | Category |
|-----|----------|
| `DOWNLOADS_DIR`, `COMPLETED_DIR`, `ALLOW_NON_MOUNTPOINT` | storage decisions |
| `USENET_SERVER_HOST`, `USENET_SERVER_USERNAME`, `USENET_SERVER_PASSWORD` | paid account |

Deliberately excluded: `VPN_SERVICE_PROVIDER`, `WIREGUARD_*`, `SERVER_COUNTRIES`
(a VPN is re-entered at install time and its key is the most dangerous thing in
a full backup); `HOST_LAN_IP`, `LAN_SUBNET` (machine-derived, must re-detect);
`SABNZBD_API_KEY`, `QBITTORRENT_PASSWORD`, `COMPOSE_FILE`, `COMPOSE_PROFILES`
(stack-generated).

### From `config/prowlarr/prowlarr.db`

The `Indexers` table, exported as JSON, one object per row, carrying `Name`,
`Implementation`, `Settings`, `ConfigContract`, `Enable`, `Priority`,
`Redirect`, and **tag labels** rather than tag ids.

Deliberately excluded: `DownloadClients`, `IndexerProxies`, `Applications`, and
`Tags` as a table — all wired by `setup`. On import, each row's
`DownloadClientId` and `AppProfileId` are reset to the fresh install's defaults
rather than carried, because those ids are per-database.

### From `config/sabnzbd/sabnzbd.ini`

The `[categories]` section in full, plus these `[misc]` keys if present and
non-default: `pre_check`, `unwanted_extensions`, `action_on_unwanted_extensions`,
`dirscan_speed`, `top_only`, `pause_on_post_processing`.

Deliberately excluded: `api_key` (stack-generated), and the `[[server1]]`
subsection (setup re-injects it from the `.env` values above). Taking the whole
file would carry all three categories at once, which is the thing this design
exists to avoid.

> **Note for the current install:** its `[categories]` section is empty (`[[*]]`
> only), so this portion captures nothing today. It is included for the case
> where an operator has tuned SABnzbd.

## Components

### 1. `scripts/lib/settings-bundle`

New sourced library holding the manifest of what belongs in a bundle — the
`.env` key list, the Prowlarr export query, and the SABnzbd key list — plus
`export_settings_bundle <install_dir> <out_dir>` and
`import_settings_bundle <bundle_dir> <install_dir>`. One place defines the
subset, so `backup` and `restore` cannot disagree about it.

### 2. `./backup --settings-only`

Writes `prowlarr-stack-settings-<host>-<UTC>.tar.gz` containing:

```
SETTINGS-MANIFEST     bundle format version, source host, UTC timestamp, stack version
env.subset            KEY=VALUE lines, the listed keys only
indexers.json         Indexers rows, tags by label
sabnzbd.subset.ini    the captured [categories] section and [misc] keys
```

Reuses the existing output-path defaulting, mode 600, and git-directory refusal.
Unlike a full backup it does **not** need to stop the stack: it reads the
Prowlarr database through `sqlite3` in read-only mode (`file:…?mode=ro`), so
there is no WAL-consistency risk to guard against.

### 3. `./restore --settings-only`

Merges a bundle into an already-installed stack:

1. Validate the manifest and refuse a bundle whose format version is unknown.
2. Write each `env.subset` key via `write_env_value`, leaving every other key
   untouched.
3. For each indexer in `indexers.json`: resolve its tag labels to ids in the
   target database, creating any tag that does not exist; insert the row if no
   indexer of that `Name` exists, otherwise update it in place. Idempotent.
4. Merge the SABnzbd keys into the target `sabnzbd.ini`.
5. Re-run `setup --non-interactive` so the stack-generated values are recomputed
   against the merged settings (notably: SABnzbd's server credentials are
   re-injected from the restored `.env`).

It refuses to run against an install that has never been set up (no `.env`),
because there would be nothing to merge into.

### 4. Tests

- `tests/settings_bundle.test` — export produces every expected member; the
  excluded keys are genuinely absent (this is the test that stops a future
  change from quietly widening the bundle to include the WireGuard key).
- `tests/settings_bundle_import.test` — tag labels resolve to ids that differ
  between source and target; an indexer whose `Name` already exists is updated
  rather than duplicated; importing twice is a no-op.
- `tests/settings_bundle_roundtrip.test` — export from a fixture install, import
  into a differently-seeded one, assert the user-supplied values match and the
  stack-generated ones did **not** come across.

## Out of scope

- Migrating between stack versions with incompatible indexer schemas. The bundle
  records the stack version; a mismatch warns, it does not translate.
- qBittorrent settings. Its password is stack-generated and its categories come
  from `defaults/`.
- Any automatic export on upgrade. This is an operator-invoked action.

# Safe self-upgrading releases — Half A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a prowlarr-stack release safe to apply unattended — snapshot → migrate → verify → auto-rollback on failure — plus an opt-in downstream systemd timer.

**Architecture:** Add a migrations framework (idempotent, versioned, extensionless scripts under `migrations/`, applied-set tracked in `config/.migrations`) run by both update modes. Refactor `update`'s release path so the destructive *code swap* is separable from setup/start, letting a failed verify auto-roll-back by re-swapping the previous release and calling the existing `restore`. Ship opt-in systemd timer units toggled by `update --enable-auto`/`--disable-auto`.

**Tech Stack:** bash (POSIX-ish, `set -euo pipefail`), sqlite3 (JSON1 functions), systemd user units, docker compose, git. Tests are `tests/*.test` bash files run by `scripts/test`; shellcheck + `docker compose config` + tests gated by `scripts/release-checks`.

**Repo:** `~/src/media-centaur/prowlarr-stack` (the SOURCE repo — durable changes go here, never in the `~/prowlarr-stack` install). Spec: `docs/superpowers/specs/2026-07-09-safe-auto-upgrade-design.md`.

**Commit convention:** this repo uses plain git. Each "Commit" step runs `git add -A && git commit -m "..."`.

---

## File Structure

**Create:**
- `scripts/run-migrations` — migration runner + `--baseline` stamping. One responsibility: apply pending idempotent migrations, record applied ids.
- `migrations/0001-flaresolverr-orphan-tags` — strip orphaned tag ids from Prowlarr indexer proxies.
- `tests/run_migrations.test` — runner behavior (pending/skip/idempotent/fail-loud/baseline).
- `tests/migration_0001.test` — migration 0001 against constructed DBs.
- `defaults/prowlarr-stack-update.service` — user unit: `ExecStart=<install>/update --yes`.
- `defaults/prowlarr-stack-update.timer` — weekly schedule, opt-in.

**Modify:**
- `update` — split the code-swap out of `release_mode_update`; add pre-flight backup, migration run, auto-rollback, `--no-rollback`, `--enable-auto`/`--disable-auto`; call `run-migrations` in dev mode.
- `setup` — stamp the migration baseline on install so fresh installs don't replay history.
- `scripts/release-checks` — add `scripts/run-migrations` and `migrations/0001-flaresolverr-orphan-tags` to the shellcheck list.

---

## Task 1: Migration runner (`scripts/run-migrations`)

**Files:**
- Create: `scripts/run-migrations`
- Create: `tests/run_migrations.test`
- Modify: `scripts/release-checks` (add to shellcheck list)

- [ ] **Step 1: Write the failing test**

Create `tests/run_migrations.test`:

```bash
#!/usr/bin/env bash
set -u

RUNNER="${RUNNER:-scripts/run-migrations}"

# Build a throwaway install root with a migrations/ dir and config/.
_scaffold() {
  local root; root=$(mktemp -d)
  mkdir -p "$root/config" "$root/migrations"
  echo "$root"
}

test_runs_pending_migration() {
  local root; root=$(_scaffold)
  cat > "$root/migrations/0001-touch" <<'EOF'
#!/usr/bin/env bash
echo ran > "$1/config/ran-0001"
EOF
  chmod +x "$root/migrations/0001-touch"
  "$RUNNER" "$root"
  [[ -f "$root/config/ran-0001" ]]
  grep -qxF "0001-touch" "$root/config/.migrations"
  rm -rf "$root"
}

test_skips_already_applied() {
  local root; root=$(_scaffold)
  cat > "$root/migrations/0001-count" <<'EOF'
#!/usr/bin/env bash
echo x >> "$1/config/count"
EOF
  chmod +x "$root/migrations/0001-count"
  "$RUNNER" "$root"
  "$RUNNER" "$root"   # second run must skip
  local n; n=$(wc -l < "$root/config/count")
  [[ "$n" -eq 1 ]]
  rm -rf "$root"
}

test_applies_in_numeric_order() {
  local root; root=$(_scaffold)
  for id in 0002-b 0001-a 0010-c; do
    cat > "$root/migrations/$id" <<EOF
#!/usr/bin/env bash
echo $id >> "\$1/config/order"
EOF
    chmod +x "$root/migrations/$id"
  done
  "$RUNNER" "$root"
  [[ "$(cat "$root/config/order")" == $'0001-a\n0002-b\n0010-c' ]]
  rm -rf "$root"
}

test_fails_loud_and_does_not_advance_state() {
  local root; root=$(_scaffold)
  cat > "$root/migrations/0001-boom" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$root/migrations/0001-boom"
  ! "$RUNNER" "$root" 2>/dev/null
  ! grep -qxF "0001-boom" "$root/config/.migrations" 2>/dev/null
  rm -rf "$root"
}

test_baseline_stamps_without_running() {
  local root; root=$(_scaffold)
  cat > "$root/migrations/0001-should-not-run" <<'EOF'
#!/usr/bin/env bash
touch "$1/config/SHOULD_NOT_EXIST"
EOF
  chmod +x "$root/migrations/0001-should-not-run"
  "$RUNNER" --baseline "$root"
  [[ ! -f "$root/config/SHOULD_NOT_EXIST" ]]
  grep -qxF "0001-should-not-run" "$root/config/.migrations"
  rm -rf "$root"
}

test_no_migrations_dir_is_noop() {
  local root; root=$(mktemp -d); mkdir -p "$root/config"
  "$RUNNER" "$root"
  rm -rf "$root"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `RUNNER=scripts/run-migrations bash -c 'source tests/run_migrations.test; test_runs_pending_migration'`
Expected: FAIL (`scripts/run-migrations` does not exist).

- [ ] **Step 3: Write the runner**

Create `scripts/run-migrations` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# scripts/run-migrations — apply pending, idempotent stack migrations.
#
# A migration is an executable in migrations/ named NNNN-slug (zero-padded
# sequence + kebab slug). Each receives the install dir as $1 and MUST be
# idempotent. Applied ids are recorded one-per-line in config/.migrations.
#
# Usage:
#   run-migrations [install_dir]        apply all pending migrations
#   run-migrations --baseline [dir]     mark all current migrations applied
#                                       WITHOUT running them (fresh install)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common
source "$here/lib/common"

baseline=0
if [[ "${1:-}" == "--baseline" ]]; then
  baseline=1
  shift
fi

root="${1:-$(cd "$here/.." && pwd)}"
migrations_dir="$root/migrations"
state="$root/config/.migrations"

mkdir -p "$root/config"
touch "$state"

if [[ ! -d "$migrations_dir" ]]; then
  log_info "no migrations directory — nothing to do"
  exit 0
fi

applied() { grep -qxF "$1" "$state"; }

# Glob expands in lexical order; zero-padded numeric prefixes == numeric order.
shopt -s nullglob
ran=0
total=0
for m in "$migrations_dir"/[0-9]*; do
  total=$((total + 1))
  id="$(basename "$m")"
  applied "$id" && continue
  if [[ $baseline -eq 1 ]]; then
    echo "$id" >> "$state"
    continue
  fi
  [[ -x "$m" ]] || die "migration not executable: $id"
  log_phase "migration $id"
  if "$m" "$root"; then
    echo "$id" >> "$state"
    log_ok "migration" "$id"
    ran=$((ran + 1))
  else
    die "migration failed: $id (state not advanced)"
  fi
done

if [[ $baseline -eq 1 ]]; then
  log_ok "migrations" "baselined $total as applied"
elif [[ $ran -eq 0 ]]; then
  log_info "migrations up to date"
else
  log_ok "migrations" "applied $ran"
fi
```

Then: `chmod +x scripts/run-migrations`

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test 2>&1 | grep run_migrations`
Expected: all `run_migrations.test::*` lines say PASS.

- [ ] **Step 5: Add to release-checks shellcheck list**

In `scripts/release-checks`, add `scripts/run-migrations` to the `bash_scripts=( ... )` array (append after `scripts/bump-images`).

Run: `./scripts/release-checks 2>&1 | tail -5`
Expected: `all release checks passed` (or, if shellcheck absent locally, no new failures).

- [ ] **Step 6: Commit**

```bash
chmod +x scripts/run-migrations tests/run_migrations.test
git commit -am "feat: idempotent stack migration runner (scripts/run-migrations)"
```

---

## Task 2: Migration `0001-flaresolverr-orphan-tags`

**Files:**
- Create: `migrations/0001-flaresolverr-orphan-tags`
- Create: `tests/migration_0001.test`
- Modify: `scripts/release-checks` (add to shellcheck list)

- [ ] **Step 1: Write the failing test**

Create `tests/migration_0001.test`:

```bash
#!/usr/bin/env bash
set -u

MIGRATION="${MIGRATION:-migrations/0001-flaresolverr-orphan-tags}"

# Build an install root with a minimal prowlarr.db (only the tables the
# migration touches). $1 = Tags rows as "id:label;..." ('' for none),
# $2 = IndexerProxies Tags JSON.
_make_db() {
  local root; root=$(mktemp -d)
  mkdir -p "$root/config/prowlarr"
  local db="$root/config/prowlarr/prowlarr.db"
  sqlite3 "$db" "CREATE TABLE Tags (Id INTEGER PRIMARY KEY, Label TEXT);"
  sqlite3 "$db" "CREATE TABLE IndexerProxies (Id INTEGER PRIMARY KEY, Name TEXT, Implementation TEXT, Settings TEXT, ConfigContract TEXT, Tags TEXT);"
  local IFS=';'
  for pair in $1; do
    [[ -z "$pair" ]] && continue
    sqlite3 "$db" "INSERT INTO Tags (Id, Label) VALUES (${pair%%:*}, '${pair##*:}');"
  done
  sqlite3 "$db" "INSERT INTO IndexerProxies (Id, Name, Implementation, Tags) VALUES (1, 'FlareSolverr', 'FlareSolverr', '$2');"
  echo "$root"
}

# Membership: does the proxy's Tags array contain id $2?
_has_tag() {
  local db="$1/config/prowlarr/prowlarr.db"
  local n
  n=$(sqlite3 "$db" "SELECT COUNT(*) FROM json_each((SELECT Tags FROM IndexerProxies WHERE Id=1)) WHERE value=$2;")
  [[ "$n" -ge 1 ]]
}
_tag_count() {
  local db="$1/config/prowlarr/prowlarr.db"
  sqlite3 "$db" "SELECT json_array_length(Tags) FROM IndexerProxies WHERE Id=1;"
}

test_removes_orphan_tag() {
  local root; root=$(_make_db "" "[1]")   # no Tags rows; proxy references id 1
  "$MIGRATION" "$root"
  [[ "$(_tag_count "$root")" -eq 0 ]]
  rm -rf "$root"
}

test_keeps_valid_tag() {
  local root; root=$(_make_db "1:vip" "[1]")   # tag 1 exists
  "$MIGRATION" "$root"
  _has_tag "$root" 1
  [[ "$(_tag_count "$root")" -eq 1 ]]
  rm -rf "$root"
}

test_mixed_keeps_valid_drops_orphan() {
  local root; root=$(_make_db "2:keep" "[1,2]")   # 2 valid, 1 orphan
  "$MIGRATION" "$root"
  _has_tag "$root" 2
  ! _has_tag "$root" 1
  [[ "$(_tag_count "$root")" -eq 1 ]]
  rm -rf "$root"
}

test_idempotent() {
  local root; root=$(_make_db "" "[1]")
  "$MIGRATION" "$root"
  "$MIGRATION" "$root"
  [[ "$(_tag_count "$root")" -eq 0 ]]
  rm -rf "$root"
}

test_noop_when_db_absent() {
  local root; root=$(mktemp -d); mkdir -p "$root/config"
  "$MIGRATION" "$root"   # must exit 0
  rm -rf "$root"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIGRATION=migrations/0001-flaresolverr-orphan-tags bash -c 'source tests/migration_0001.test; test_removes_orphan_tag'`
Expected: FAIL (migration does not exist).

- [ ] **Step 3: Write the migration**

Create `migrations/0001-flaresolverr-orphan-tags` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# 0001-flaresolverr-orphan-tags — strip orphaned tag ids from Prowlarr indexer
# proxies. An IndexerProxies.Tags entry referencing a tag id absent from the
# Tags table scopes the proxy (e.g. FlareSolverr) to a nonexistent tag, so
# Prowlarr never routes through it and Cloudflare-gated indexer tests fail.
# Removing orphaned ids restores "no tags = applies to all indexers".
# Idempotent. No-op when the DB is absent.
#
# Usage: 0001-flaresolverr-orphan-tags <install_dir>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/common
source "$here/../scripts/lib/common"

root="${1:?usage: 0001-flaresolverr-orphan-tags <install_dir>}"
db="$root/config/prowlarr/prowlarr.db"

if [[ ! -f "$db" ]]; then
  log_info "no prowlarr.db — skipping (fresh or non-prowlarr install)"
  exit 0
fi

# Rebuild each proxy's Tags as the subset of ids still present in Tags.
# Only rewrite rows that actually contain an orphan (keeps clean rows untouched
# and the operation idempotent).
sqlite3 "$db" <<'SQL'
UPDATE IndexerProxies
SET Tags = (
  SELECT COALESCE(json_group_array(je.value), json('[]'))
  FROM json_each(IndexerProxies.Tags) AS je
  WHERE je.value IN (SELECT Id FROM Tags)
)
WHERE EXISTS (
  SELECT 1 FROM json_each(IndexerProxies.Tags) AS je
  WHERE je.value NOT IN (SELECT Id FROM Tags)
);
SQL

orphans=$(sqlite3 "$db" "
  SELECT COUNT(*) FROM IndexerProxies ip
  JOIN json_each(ip.Tags) je
  WHERE je.value NOT IN (SELECT Id FROM Tags);
")
if [[ "$orphans" != "0" ]]; then
  die "orphaned proxy tags remain after migration ($orphans)"
fi

log_ok "0001" "flaresolverr orphan tags cleared"
```

Then: `chmod +x migrations/0001-flaresolverr-orphan-tags`

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test 2>&1 | grep migration_0001`
Expected: all `migration_0001.test::*` lines PASS.

- [ ] **Step 5: Add to release-checks shellcheck list**

In `scripts/release-checks`, add `migrations/0001-flaresolverr-orphan-tags` to the `bash_scripts=( ... )` array.

Run: `./scripts/release-checks 2>&1 | tail -5`
Expected: `all release checks passed`.

- [ ] **Step 6: Commit**

```bash
chmod +x migrations/0001-flaresolverr-orphan-tags tests/migration_0001.test
git commit -am "feat: migration 0001 — clear orphaned FlareSolverr proxy tags"
```

---

## Task 3: ~~Baseline stamp on fresh install (`setup`)~~ — REVERTED in v0.5.1

**Superseded:** this task added a `run-migrations --baseline` call to `setup`.
It was wrong: `setup` runs on every `./update`, so it stamped migrations as
applied before they could run, skipping them forever on existing installs. The
baseline mechanism was removed entirely (migrations are idempotent no-ops on
correct state). The original task text is kept below for history.

---

## Task 3 (original): Baseline stamp on fresh install (`setup`)

**Files:**
- Modify: `setup` (add a migrations-baseline phase near the end, after the prowlarr.db patch)

**Rationale:** A fresh install's seeded config is already correct, so historical migrations must be marked applied (not run). Existing installs upgrading for the first time have no `config/.migrations`, so all migrations run then (correct — they fix existing state).

- [ ] **Step 1: Add the baseline phase**

In `setup`, after the `log_phase "patching prowlarr.db → ..."` block (around line 312–320) and before `log_phase "storage paths"`, insert:

```bash
log_phase "migration baseline"
./scripts/run-migrations --baseline "$(pwd)"
```

- [ ] **Step 2: Verify setup still validates under shellcheck**

Run: `shellcheck -x --severity=warning setup && echo OK`
Expected: `OK` (no new warnings).

- [ ] **Step 3: Manually verify baseline behavior on a throwaway root**

Run:
```bash
tmp=$(mktemp -d); mkdir -p "$tmp/config" "$tmp/migrations"
cp scripts/run-migrations "$tmp/scripts_run" 2>/dev/null || true
printf '#!/usr/bin/env bash\ntouch "$1/config/RAN"\n' > "$tmp/migrations/0001-x"; chmod +x "$tmp/migrations/0001-x"
# emulate: scripts/run-migrations --baseline "$tmp"  (run from repo so lib/common resolves)
./scripts/run-migrations --baseline "$tmp"
[[ ! -f "$tmp/config/RAN" ]] && grep -qxF 0001-x "$tmp/config/.migrations" && echo BASELINE_OK
rm -rf "$tmp"
```
Expected: `BASELINE_OK`.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat: stamp migration baseline during setup so fresh installs skip history"
```

---

## Task 4: Run migrations in dev-mode update

**Files:**
- Modify: `update` (`dev_mode_update` — call `run-migrations` after setup, before restart)

**Rationale:** Dev installs (git) must apply migrations too. Dev mode has no rollback (source-controlled, maintainer-operated); a failed migration should just `die` and stop, which `run-migrations` already does.

- [ ] **Step 1: Add the call**

In `update`, inside `dev_mode_update`, in the `if [[ "$MODE" != "code" ]]; then` block, immediately after `log_phase "pulling images"` / `run docker compose pull` and before `log_phase "restarting stack"`, insert:

```bash
    log_phase "migrations"
    run ./scripts/run-migrations "$(pwd)"
```

- [ ] **Step 2: Verify with dry-run**

Run: `./update --dry-run --code-only 2>&1 | head -20` then `./update --dry-run 2>&1 | grep -i migration`
Expected: dev-mode dry-run prints a `migrations` phase and `(dry-run) ./scripts/run-migrations ...` for the non-code path.

- [ ] **Step 3: shellcheck**

Run: `shellcheck -x --severity=warning update && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat: run stack migrations during dev-mode update"
```

---

## Task 5: Refactor release swap into a separable code-swap

**Files:**
- Modify: `update` (extract `fetch_and_swap_code` from `release_mode_update`)

**Rationale:** Auto-rollback needs to put the *previous* release's code back without triggering setup/start (the existing `restore` handles state + setup + start). Extracting the download→verify→swap block into a function lets both forward-upgrade and rollback reuse it.

- [ ] **Step 1: Add the function**

In `update`, above `release_mode_update`, add:

```bash
# Download release <version> to <tmp>, verify checksum + archive safety, and
# swap its code into the install dir, preserving .env/.envrc/config and MANIFEST.
# Does NOT run setup, pull images, or start the stack — callers do that.
fetch_and_swap_code() {
  local version="$1" tmp="$2"
  local tarball="prowlarr-stack-${version}.tar.gz"
  local url_tar="https://github.com/$REPO_SLUG/releases/download/${version}/${tarball}"
  local url_sum="https://github.com/$REPO_SLUG/releases/download/${version}/SHA256SUMS"

  log_phase "downloading $version"
  run curl -fsSL --max-time 60 -o "$tmp/$tarball" "$url_tar"
  run curl -fsSL --max-time 30 -o "$tmp/SHA256SUMS" "$url_sum"

  log_phase "verifying checksum"
  if [[ $DRY_RUN -eq 0 ]]; then
    (cd "$tmp" && sha256sum -c SHA256SUMS) || die "checksum mismatch — aborting"
  fi

  log_phase "validating archive safety"
  if [[ $DRY_RUN -eq 0 ]]; then
    local bad
    bad=$(tar tzf "$tmp/$tarball" | awk -v p="prowlarr-stack-${version}/" '
      /^\// { print "absolute path: "$0; exit }
      /\.\./ { print "parent-ref:    "$0; exit }
      $0 !~ "^"p { print "bad prefix:    "$0; exit }
      { next }
    ')
    [[ -z "$bad" ]] || die "tarball rejected: $bad"
  fi

  log_phase "preserving state"
  run mkdir -p "$tmp/preserve"
  if [[ -f .env ]]; then run mv .env "$tmp/preserve/"; fi
  if [[ -f .envrc ]]; then run mv .envrc "$tmp/preserve/"; fi
  if [[ -d config ]]; then run mv config "$tmp/preserve/"; fi

  log_phase "swapping in $version"
  run tar xzf "$tmp/$tarball" -C "$tmp"
  if [[ $DRY_RUN -eq 0 ]]; then
    find . -maxdepth 1 -mindepth 1 ! -name MANIFEST -exec rm -rf {} +
    cp -a "$tmp/prowlarr-stack-$version/." ./
  fi

  log_phase "restoring state"
  if [[ -f "$tmp/preserve/.env" ]]; then run mv "$tmp/preserve/.env" ./; fi
  if [[ -f "$tmp/preserve/.envrc" ]]; then run mv "$tmp/preserve/.envrc" ./; fi
  if [[ -d "$tmp/preserve/config" ]]; then run mv "$tmp/preserve/config" ./; fi

  log_phase "refreshing MANIFEST"
  if [[ $DRY_RUN -eq 0 ]]; then
    write_manifest "$(pwd)" "$version"
  fi
}
```

- [ ] **Step 2: Replace the inline block in `release_mode_update`**

In `release_mode_update`, delete the inline block that spans from `local tarball="prowlarr-stack-${target}.tar.gz"` through the `log_phase "refreshing MANIFEST"` / `write_manifest` block (everything now living in `fetch_and_swap_code`), and the `log_phase "stopping stack"` + `run systemctl --user stop prowlarr-stack` line that preceded it. Replace with a single call (the stop now happens via the pre-flight backup added in Task 6, so it is intentionally removed here):

```bash
  fetch_and_swap_code "$target" "$tmp"
```

Keep the subsequent lines (`re-running setup`, `pulling images`, `restarting stack`, gluetun wait, `./check`) for now — Task 6 rewires them.

- [ ] **Step 3: Verify dry-run still plans a full upgrade**

Run: `cd /tmp && rm -rf ptest && cp -a ~/src/media-centaur/prowlarr-stack ptest && cd ptest && echo v0.0.1 > .version && ./update --dry-run --yes 2>&1 | head -40; cd ~/src/media-centaur/prowlarr-stack`
Expected: dry-run prints downloading → verifying → validating → preserving → swapping → restoring → refreshing MANIFEST → setup → pull → start phases, no execution.

- [ ] **Step 4: shellcheck**

Run: `shellcheck -x --severity=warning update && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git commit -am "refactor: extract fetch_and_swap_code from release_mode_update"
```

---

## Task 6: Pre-flight backup, migrations, and auto-rollback in release mode

**Files:**
- Modify: `update` (`release_mode_update` body; add `rollback_to`; add `--no-rollback` flag parsing)

- [ ] **Step 1: Add `--no-rollback` flag parsing**

In `update`'s arg-parse loop, add a case:

```bash
    --no-rollback) NO_ROLLBACK=1; shift ;;
```

And initialize near the other defaults (`YES=0`, `DRY_RUN=0`):

```bash
NO_ROLLBACK=0
```

Add `--no-rollback` to the `--help` heredoc under the flags list:

```
  --no-rollback    on post-swap failure, leave the broken state in place (debug)
```

- [ ] **Step 2: Add the `rollback_to` function**

Above `release_mode_update`, add:

```bash
# Roll the install back to <prev> using the pre-flight backup <backup>.
# Re-swaps the previous release code, then reuses ./restore to put back the
# pre-upgrade config/.env and re-run setup + start + verify.
rollback_to() {
  local prev="$1" backup="$2"
  log_warn "verification failed — rolling back to $prev"
  local rtmp; rtmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$rtmp'" RETURN
  fetch_and_swap_code "$prev" "$rtmp"
  log_phase "restoring pre-upgrade state"
  if ! ./restore "$backup" --yes; then
    die "ROLLBACK FAILED — install left on $prev code with pre-upgrade backup at $backup; restore manually with: ./restore '$backup' --yes"
  fi
  log_ok "rolled back" "$prev"
  notify_update_failure "upgrade failed; rolled back to $prev"
  die "upgrade aborted and rolled back to $prev"
}
```

- [ ] **Step 3: Add the notify hook**

Above `release_mode_update`, add:

```bash
# Optional failure notification. If UPDATE_NOTIFY_CMD is set in .env, invoke it
# with a one-line message. No-op otherwise. Never fails the caller.
notify_update_failure() {
  local msg="$1" cmd=""
  [[ -f .env ]] && cmd=$(read_env_value .env UPDATE_NOTIFY_CMD 2>/dev/null || true)
  [[ -n "$cmd" ]] || return 0
  log_info "notifying: $cmd"
  bash -c "$cmd" "notify" "$msg" || log_warn "notify command failed"
}
```

- [ ] **Step 4: Rewire the tail of `release_mode_update`**

Replace the block from `fetch_and_swap_code "$target" "$tmp"` (added in Task 5) through the final `./check` with:

```bash
  # Pre-flight: snapshot mutable state so we can roll back. ./backup stops the
  # stack (consistent SQLite), replacing a separate stop step.
  log_phase "pre-flight backup"
  run ./backup --yes --output "$tmp/rollback.tar.gz"

  fetch_and_swap_code "$target" "$tmp"

  log_phase "re-running setup (non-interactive)"
  run ./setup --non-interactive

  log_phase "pulling images"
  run docker compose pull

  # Migrations run while the stack is stopped, against the restored config.
  # setup may have started the stack; stop it before mutating the DB.
  log_phase "migrations"
  if [[ $DRY_RUN -eq 0 ]]; then
    systemctl --user stop prowlarr-stack 2>/dev/null || true
  fi
  if ! run ./scripts/run-migrations "$(pwd)"; then
    if [[ $NO_ROLLBACK -eq 1 ]]; then die "migration failed (--no-rollback: leaving broken state)"; fi
    rollback_to "$current" "$tmp/rollback.tar.gz"
  fi

  log_phase "restarting stack"
  run systemctl --user restart prowlarr-stack

  if [[ $DRY_RUN -eq 0 ]]; then
    log_phase "verifying (gluetun health + isolation)"
    local ok=1
    if ! wait_for_gluetun_healthy 60; then ok=0; fi
    if [[ $ok -eq 1 ]] && ! ./check; then ok=0; fi
    if [[ $ok -eq 0 ]]; then
      if [[ $NO_ROLLBACK -eq 1 ]]; then die "verification failed (--no-rollback: leaving broken state)"; fi
      rollback_to "$current" "$tmp/rollback.tar.gz"
    fi
    log_ok "upgrade" "$target verified healthy"
  fi
```

Note: `$current` is the pre-upgrade version already captured at the top of `release_mode_update`.

- [ ] **Step 5: Verify dry-run plan**

Run: `cd /tmp/ptest && ./update --dry-run --yes 2>&1 | sed -n '1,50p'; cd ~/src/media-centaur/prowlarr-stack`
Expected: plan now shows `pre-flight backup` before the swap, a `migrations` phase, and a `verifying` phase; no rollback path executes (dry-run).

- [ ] **Step 6: shellcheck**

Run: `shellcheck -x --severity=warning update && echo OK`
Expected: `OK`.

- [ ] **Step 7: Commit**

```bash
git commit -am "feat: transactional release upgrade — pre-flight backup, migrations, auto-rollback"
```

---

## Task 7: Opt-in downstream auto-update timer

**Files:**
- Create: `defaults/prowlarr-stack-update.service`
- Create: `defaults/prowlarr-stack-update.timer`
- Modify: `update` (add `--enable-auto` / `--disable-auto`)

- [ ] **Step 1: Create the systemd units**

Create `defaults/prowlarr-stack-update.service`:

```ini
[Unit]
Description=prowlarr-stack unattended safe upgrade
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# %h expands to the user home; INSTALL_DIR is substituted by --enable-auto.
ExecStart=INSTALL_DIR/update --yes
```

Create `defaults/prowlarr-stack-update.timer`:

```ini
[Unit]
Description=Weekly prowlarr-stack safe auto-upgrade

[Timer]
OnCalendar=Sun 04:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 2: Add `--enable-auto` / `--disable-auto` handling**

In `update`, add to the arg-parse loop:

```bash
    --enable-auto) MODE="enable-auto"; shift ;;
    --disable-auto) MODE="disable-auto"; shift ;;
```

Add to the `--help` heredoc:

```
  --enable-auto    install + enable the weekly unattended-upgrade timer
  --disable-auto   disable + remove the unattended-upgrade timer
```

Before mode detection (before the `if [[ -f .version ]]` block), add:

```bash
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

enable_auto() {
  local install_dir; install_dir="$(pwd)"
  run mkdir -p "$UNIT_DIR"
  if [[ $DRY_RUN -eq 0 ]]; then
    sed "s|INSTALL_DIR|$install_dir|g" defaults/prowlarr-stack-update.service \
      > "$UNIT_DIR/prowlarr-stack-update.service"
    cp defaults/prowlarr-stack-update.timer "$UNIT_DIR/prowlarr-stack-update.timer"
  fi
  run systemctl --user daemon-reload
  run systemctl --user enable --now prowlarr-stack-update.timer
  log_ok "auto-update" "enabled (weekly)"
  log_info "next run: $(systemctl --user list-timers prowlarr-stack-update.timer --no-pager 2>/dev/null | sed -n 2p)"
}

disable_auto() {
  run systemctl --user disable --now prowlarr-stack-update.timer 2>/dev/null || true
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -f "$UNIT_DIR/prowlarr-stack-update.timer" "$UNIT_DIR/prowlarr-stack-update.service"
  fi
  run systemctl --user daemon-reload
  log_ok "auto-update" "disabled"
}
```

And dispatch these modes right after mode detection, before the release/dev branch:

```bash
case "$MODE" in
  enable-auto) enable_auto; exit 0 ;;
  disable-auto) disable_auto; exit 0 ;;
esac
```

- [ ] **Step 3: Validate the units**

Run:
```bash
if command -v systemd-analyze >/dev/null; then
  sed 's|INSTALL_DIR|/home/test/prowlarr-stack|g' defaults/prowlarr-stack-update.service > /tmp/u.service
  systemd-analyze verify --user /tmp/u.service 2>&1 | grep -v '^$' || echo "service OK"
  systemd-analyze verify --user defaults/prowlarr-stack-update.timer 2>&1 | grep -v '^$' || echo "timer OK"
fi
```
Expected: no errors (ignore warnings about the ExecStart binary not existing at the test path).

- [ ] **Step 4: Dry-run the flags**

Run: `./update --dry-run --enable-auto 2>&1 | head; ./update --dry-run --disable-auto 2>&1 | head`
Expected: enable prints daemon-reload + `enable --now` under `(dry-run)`; disable prints `disable --now` + daemon-reload.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -x --severity=warning update && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git commit -am "feat: opt-in weekly auto-update systemd timer (--enable-auto/--disable-auto)"
```

---

## Task 8: CHANGELOG + full release-checks

**Files:**
- Modify: `CHANGELOG.md` (add an `[Unreleased]` section)

- [ ] **Step 1: Add CHANGELOG entry**

Under the top `[Unreleased]` heading (create it if absent), add:

```markdown
### Added
- Stack migration framework (`migrations/`, `scripts/run-migrations`): idempotent,
  versioned fixups applied automatically during `./update`.
- Migration `0001-flaresolverr-orphan-tags`: clears orphaned FlareSolverr proxy
  tags so Prowlarr routes Cloudflare-gated indexers through the solver.
- Transactional release upgrades: pre-flight backup → migrate → verify
  (gluetun health + VPN isolation) → **auto-rollback** to the prior release on
  failure. `--no-rollback` to opt out.
- Opt-in weekly unattended upgrades via systemd timer
  (`./update --enable-auto` / `--disable-auto`); optional `UPDATE_NOTIFY_CMD`
  in `.env` for failure notification.
```

- [ ] **Step 2: Run the full release-checks gate**

Run: `./scripts/release-checks`
Expected: `all release checks passed`.

- [ ] **Step 3: Commit**

```bash
git commit -am "docs: CHANGELOG for safe self-upgrading releases"
```

---

## Self-Review

**Spec coverage:**
- A0 pre-flight snapshot → Task 6 Step 4 (`./backup --yes --output`). ✅
- A1 migrations framework + runner + state + baseline → Tasks 1, 3; dev mode Task 4; release Task 6. ✅
- Migration 0001 → Task 2. ✅
- A2 verify + auto-rollback + `--no-rollback` → Task 6. ✅
- A3 opt-in timer + `--enable-auto`/`--disable-auto` + notify → Task 7 (+ notify hook Task 6 Step 3). ✅
- Testing (runner, migration 0001, timer validate) → Tasks 1, 2, 7. Rollback is exercised via dry-run + manual (a full live-stack rollback test is impractical in CI; noted). ⚠ documented limitation.
- release-checks wiring → Tasks 1, 2, 8. ✅

**Placeholder scan:** none — all steps carry real code/commands.

**Type/name consistency:** `fetch_and_swap_code` (Tasks 5, 6), `rollback_to` (Task 6), `run-migrations` (Tasks 1,3,4,6), `notify_update_failure` (Task 6), `config/.migrations` state path (Tasks 1,2,3), `$current`/`$prev` pre-upgrade version (Task 6) — consistent across tasks.

**Known limitation:** rollback orchestration (Task 6) cannot be unit-tested without a live stack; it is verified by dry-run plan inspection + shellcheck, and its building blocks (`fetch_and_swap_code`, `restore`, migrations) are independently tested. The `config/.rollback/last.tar.gz` persistent copy from the spec was dropped as YAGNI — the in-run `$tmp/rollback.tar.gz` covers auto-rollback; `./backup` already writes a durable copy to `$HOME` by default.

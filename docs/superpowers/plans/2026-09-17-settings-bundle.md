# Settings Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--settings-only` to `./backup` and `./restore` so an install can be rebuilt through the ordinary installer without re-entering storage paths, usenet credentials, indexer definitions, or SABnzbd settings.

**Architecture:** A single Python executable, `scripts/settings-bundle`, owns the manifest of what belongs in a bundle and both directions of the transfer (`export`, `import`). `./backup` and `./restore` gain a flag that delegates to it and handles tarballing. Import **merges** into an already-installed stack rather than replacing it, because it lands on a stack `setup` has just configured.

**Tech Stack:** Python 3 (stdlib only — `json`, `sqlite3`, `argparse`, `pathlib`), Bash, SQLite.

**Spec:** `docs/superpowers/specs/2026-09-17-settings-bundle-design.md`

---

## Why import must merge

A settings-only restore runs against a fresh install. `setup` has already
generated Prowlarr's `ApiKey`, `SABNZBD_API_KEY`, the qBittorrent password, and
`COMPOSE_PROFILES`, and has already detected `HOST_LAN_IP`/`LAN_SUBNET` for
*this* host. Replacing `.env` or `prowlarr.db` wholesale would destroy all of
that. Every write in the import path is therefore a targeted key-set or upsert.

## Schema facts (verified — do not re-derive)

`Indexers` has no protocol column and this exact shape:

```sql
CREATE TABLE "Indexers" (
  "Id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  "Name" TEXT NOT NULL, "Implementation" TEXT NOT NULL,
  "Settings" TEXT, "ConfigContract" TEXT, "Enable" INTEGER,
  "Priority" INTEGER NOT NULL, "Added" DATETIME NOT NULL,
  "Redirect" INTEGER NOT NULL, "AppProfileId" INTEGER NOT NULL,
  "Tags" TEXT, "DownloadClientId" INTEGER NOT NULL);
CREATE UNIQUE INDEX "IX_Indexers_Name" ON "Indexers" ("Name" ASC);
```

- `Name` is UNIQUE — that is the upsert key.
- `Priority`, `Added`, `Redirect`, `AppProfileId`, `DownloadClientId` are NOT NULL, so an INSERT must supply all of them.
- `Tags` is a JSON array of tag **ids**, and ids are per-database. `Tags` may be NULL or `[]`.
- `Settings` is TEXT containing JSON. Keep it as an opaque string end to end — do not parse and re-serialise it, or key order and escaping will drift.

`Tags` table is `(Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL)`.

## File structure

| File | Responsibility |
|------|----------------|
| `scripts/settings-bundle` | **New.** Manifest + `export`/`import`. The only place that knows what a bundle contains. |
| `backup` | Gains `--settings-only`; delegates, then tars |
| `restore` | Gains `--settings-only`; untars, delegates, then re-runs setup |
| `tests/settings_bundle_export.test` | Export contents, and that excluded keys are absent |
| `tests/settings_bundle_import.test` | Tag remapping, upsert-by-name, idempotence |
| `tests/settings_bundle_roundtrip.test` | Export → import across differently-seeded installs |

Run the suite with `scripts/test`. Baseline is **150 passed, 0 failed**.

**Assertion idiom:** never write `! cmd` — bash exempts it from `set -e`, so it
asserts nothing unless it is a function's final statement, and `scripts/test`
now refuses to run when it finds one. Use `refute <cmd>` or `refute_grep
<pattern> <file>` (both provided by `tests/lib/assert`, sourced by the runner),
or `if <compound>; then return 1; fi` for subshells and pipelines.

---

## Task S1: `scripts/settings-bundle export`

**Files:**
- Create: `scripts/settings-bundle`
- Test: `tests/settings_bundle_export.test`

- [ ] **Step 1: Write the failing test**

Create `tests/settings_bundle_export.test`:

```bash
#!/usr/bin/env bash
set -u

# Build a throwaway install with known settings, generated AND user-supplied.
_make_install() {
  local root; root=$(mktemp -d)
  mkdir -p "$root/config/prowlarr" "$root/config/sabnzbd"
  cat > "$root/.env" <<'ENV'
DOWNLOADS_DIR=/mnt/videos/downloads
COMPLETED_DIR=/mnt/videos/completed
ALLOW_NON_MOUNTPOINT=0
USENET_SERVER_HOST=news.example.net
USENET_SERVER_USERNAME=someuser
USENET_SERVER_PASSWORD=somepass
VPN_SERVICE_PROVIDER=nordvpn
WIREGUARD_PRIVATE_KEY=SECRETKEYSECRETKEYSECRETKEYSECRETKEYSECRET=
HOST_LAN_IP=192.168.1.10
LAN_SUBNET=192.168.1.0/24
SABNZBD_API_KEY=generated0000
QBITTORRENT_PASSWORD=adminadmin
COMPOSE_PROFILES=vpn
ENV
  local db="$root/config/prowlarr/prowlarr.db"
  sqlite3 "$db" 'CREATE TABLE Tags (Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL);'
  sqlite3 "$db" 'CREATE TABLE Indexers ("Id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "Name" TEXT NOT NULL, "Implementation" TEXT NOT NULL, "Settings" TEXT, "ConfigContract" TEXT, "Enable" INTEGER, "Priority" INTEGER NOT NULL, "Added" DATETIME NOT NULL, "Redirect" INTEGER NOT NULL, "AppProfileId" INTEGER NOT NULL, "Tags" TEXT, "DownloadClientId" INTEGER NOT NULL);'
  sqlite3 "$db" "INSERT INTO Tags (Id,Label) VALUES (7,'byparr');"
  sqlite3 "$db" "INSERT INTO Indexers (Name,Implementation,Settings,ConfigContract,Enable,Priority,Added,Redirect,AppProfileId,Tags,DownloadClientId) VALUES ('NZBgeek','Newznab','{\"apiKey\":\"indexerkey\"}','NewznabSettings',1,25,'2026-01-01',0,1,'[]',0);"
  sqlite3 "$db" "INSERT INTO Indexers (Name,Implementation,Settings,ConfigContract,Enable,Priority,Added,Redirect,AppProfileId,Tags,DownloadClientId) VALUES ('Sample Tracker','Cardigann','{\"definitionFile\":\"sample\"}','CardigannSettings',1,25,'2026-01-01',0,1,'[7]',0);"
  cat > "$root/config/sabnzbd/sabnzbd.ini" <<'INI'
[misc]
api_key = generated0000
complete_dir = /downloads/completed
pre_check = 1
[categories]
[[*]]
priority = 0
[[movies]]
priority = -100
script = move-finished.sh
[servers]
[[server1]]
host = news.example.net
username = someuser
password = somepass
INI
  echo "$root"
}

_export() {  # _export <install> -> bundle dir
  local out; out=$(mktemp -d)
  scripts/settings-bundle export "$1" "$out" >/dev/null
  echo "$out"
}

test_export_writes_all_four_members() {
  local inst; inst=$(_make_install)
  local b; b=$(_export "$inst")
  [[ -f "$b/SETTINGS-MANIFEST" ]]
  [[ -f "$b/env.subset" ]]
  [[ -f "$b/indexers.json" ]]
  [[ -f "$b/sabnzbd.subset.ini" ]]
  rm -rf "$inst" "$b"
}

test_export_captures_user_supplied_env() {
  local inst; inst=$(_make_install)
  local b; b=$(_export "$inst")
  grep -q '^DOWNLOADS_DIR=/mnt/videos/downloads$' "$b/env.subset"
  grep -q '^USENET_SERVER_PASSWORD=somepass$' "$b/env.subset"
  rm -rf "$inst" "$b"
}

test_export_excludes_secrets_and_generated_values() {
  # The test that stops a future change quietly widening the bundle.
  local inst; inst=$(_make_install)
  local b; b=$(_export "$inst")
  refute_grep 'WIREGUARD_PRIVATE_KEY' \"$b/env.subset\"
  refute_grep 'VPN_SERVICE_PROVIDER' \"$b/env.subset\"
  refute_grep 'HOST_LAN_IP' \"$b/env.subset\"
  refute_grep 'LAN_SUBNET' \"$b/env.subset\"
  refute_grep 'SABNZBD_API_KEY' \"$b/env.subset\"
  refute_grep 'QBITTORRENT_PASSWORD' \"$b/env.subset\"
  refute_grep 'COMPOSE_PROFILES' \"$b/env.subset\"
  rm -rf "$inst" "$b"
}

test_export_carries_tag_labels_not_ids() {
  local inst; inst=$(_make_install)
  local b; b=$(_export "$inst")
  # Sample Tracker carries tag id 7 = label "byparr"; the bundle must say byparr.
  python3 -c "
import json,sys
rows=json.load(open('$b/indexers.json'))
st=[r for r in rows if r['Name']=='Sample Tracker'][0]
assert st['TagLabels']==['byparr'], st
assert 'Tags' not in st, st
nz=[r for r in rows if r['Name']=='NZBgeek'][0]
assert nz['TagLabels']==[], nz
assert json.loads(nz['Settings'])['apiKey']=='indexerkey'
"
  rm -rf "$inst" "$b"
}

test_export_sab_subset_keeps_categories_drops_api_key_and_server() {
  local inst; inst=$(_make_install)
  local b; b=$(_export "$inst")
  grep -q '^\[categories\]' "$b/sabnzbd.subset.ini"
  grep -q '^\[\[movies\]\]' "$b/sabnzbd.subset.ini"
  grep -q 'pre_check' "$b/sabnzbd.subset.ini"
  refute_grep 'api_key' \"$b/sabnzbd.subset.ini\"
  refute_grep 'server1' \"$b/sabnzbd.subset.ini\"
  refute_grep 'somepass' \"$b/sabnzbd.subset.ini\"
  rm -rf "$inst" "$b"
}

test_export_refuses_an_install_without_env() {
  local root; root=$(mktemp -d)
  local out; out=$(mktemp -d)
  refute scripts/settings-bundle export "$root" "$out" >/dev/null 2>&1
  rm -rf "$root" "$out"
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `scripts/test 2>&1 | grep settings_bundle_export`
Expected: all FAIL — `scripts/settings-bundle` does not exist.

- [ ] **Step 3: Write the exporter**

Create `scripts/settings-bundle` (then `chmod +x`):

```python
#!/usr/bin/env python3
"""Export and import the user-supplied subset of a prowlarr-stack install.

A "settings bundle" carries only what a human decided or obtained from a third
party — storage paths, the usenet account, Prowlarr indexer definitions, and
SABnzbd's own settings. Everything else (API keys, passwords, LAN detection,
compose profile, download-client and proxy wiring) is regenerated by ./setup,
so carrying it would reproduce an old install rather than rebuild a clean one.

  settings-bundle export <install_dir> <out_dir>
  settings-bundle import <bundle_dir> <install_dir>

Import MERGES: it lands on a stack ./setup has already configured, so every
write is a targeted key-set or upsert, never a wholesale replace.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

BUNDLE_FORMAT = 1

# --- the manifest: the single definition of what a bundle contains ---

ENV_KEYS = [
    "DOWNLOADS_DIR",
    "COMPLETED_DIR",
    "ALLOW_NON_MOUNTPOINT",
    "USENET_SERVER_HOST",
    "USENET_SERVER_USERNAME",
    "USENET_SERVER_PASSWORD",
]

# [misc] keys that are the operator's tuning rather than stack-generated.
SAB_MISC_KEYS = [
    "pre_check",
    "unwanted_extensions",
    "action_on_unwanted_extensions",
    "dirscan_speed",
    "top_only",
    "pause_on_post_processing",
]

INDEXER_COLUMNS = [
    "Name", "Implementation", "Settings", "ConfigContract",
    "Enable", "Priority", "Redirect",
]


def die(msg: str) -> None:
    print(f"settings-bundle: {msg}", file=sys.stderr)
    sys.exit(1)


# --- .env ---

def read_env(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines, stripping the quoting write_env_value applies."""
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1].replace('\\"', '"')
        out[key.strip()] = value
    return out


# --- Prowlarr ---

def export_indexers(db: Path) -> list[dict]:
    """Indexer rows with tag LABELS; ids are per-database and never travel."""
    if not db.is_file():
        return []
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        con.row_factory = sqlite3.Row
        labels = {r["Id"]: r["Label"] for r in con.execute("SELECT Id, Label FROM Tags")}
        rows = []
        for r in con.execute(f"SELECT {', '.join(INDEXER_COLUMNS)}, Tags FROM Indexers"):
            row = {c: r[c] for c in INDEXER_COLUMNS}
            tag_ids = json.loads(r["Tags"] or "[]")
            row["TagLabels"] = [labels[t] for t in tag_ids if t in labels]
            rows.append(row)
        return rows
    finally:
        con.close()


# --- SABnzbd ---

def _sab_sections(text: str):
    """Yield (top_section, line) for a SABnzbd ini.

    configparser cannot parse the double-bracketed subsections, so track the
    top-level section by hand and pass every line through with its owner.
    """
    top = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[[") and stripped.endswith("]]"):
            pass  # a subsection; belongs to the current top-level section
        elif stripped.startswith("[") and stripped.endswith("]"):
            top = stripped[1:-1]
        yield top, line


def export_sab(ini: Path) -> str:
    """The [categories] section verbatim, plus the operator-tuned [misc] keys."""
    if not ini.is_file():
        return ""
    misc, cats = [], []
    for top, line in _sab_sections(ini.read_text()):
        stripped = line.strip()
        if top == "misc":
            key = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
            if key in SAB_MISC_KEYS:
                misc.append(line)
        elif top == "categories":
            cats.append(line)
    out = []
    if misc:
        out.append("[misc]")
        out.extend(misc)
    out.extend(cats)
    return "\n".join(out) + ("\n" if out else "")


# --- commands ---

def cmd_export(install: Path, out: Path) -> None:
    env_path = install / ".env"
    if not env_path.is_file():
        die(f"no .env in {install} — is this a prowlarr-stack install?")
    out.mkdir(parents=True, exist_ok=True)

    env = read_env(env_path)
    lines = [f"{k}={env[k]}" for k in ENV_KEYS if k in env]
    (out / "env.subset").write_text("\n".join(lines) + "\n")

    indexers = export_indexers(install / "config/prowlarr/prowlarr.db")
    (out / "indexers.json").write_text(json.dumps(indexers, indent=2) + "\n")

    (out / "sabnzbd.subset.ini").write_text(export_sab(install / "config/sabnzbd/sabnzbd.ini"))

    version = ""
    vf = install / ".version"
    if vf.is_file():
        version = vf.read_text().strip()
    manifest = {
        "format": BUNDLE_FORMAT,
        "stack_version": version,
        "indexer_count": len(indexers),
    }
    (out / "SETTINGS-MANIFEST").write_text(json.dumps(manifest, indent=2) + "\n")
    for p in out.iterdir():
        p.chmod(0o600)
    print(f"exported {len(indexers)} indexer(s) and {len(lines)} setting(s)")


def main() -> None:
    ap = argparse.ArgumentParser(prog="settings-bundle")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("install")
    e.add_argument("out")
    args = ap.parse_args()
    if args.cmd == "export":
        cmd_export(Path(args.install), Path(args.out))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep settings_bundle_export`
Expected: six PASS lines.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/settings-bundle
git add scripts/settings-bundle tests/settings_bundle_export.test
git commit -m "feat: export the user-supplied settings subset"
```

---

## Task S2: `scripts/settings-bundle import`

**Files:**
- Modify: `scripts/settings-bundle`
- Test: `tests/settings_bundle_import.test`

- [ ] **Step 1: Write the failing test**

Create `tests/settings_bundle_import.test`:

```bash
#!/usr/bin/env bash
set -u

# A FRESH install: different tag ids, no indexers, setup-generated values present.
_fresh_install() {
  local root; root=$(mktemp -d)
  mkdir -p "$root/config/prowlarr" "$root/config/sabnzbd"
  cat > "$root/.env" <<'ENV'
DOWNLOADS_DIR=/tmp/wrong
COMPLETED_DIR=/tmp/wrong
SABNZBD_API_KEY=freshkey1234
HOST_LAN_IP=10.0.0.5
COMPOSE_PROFILES=
ENV
  local db="$root/config/prowlarr/prowlarr.db"
  sqlite3 "$db" 'CREATE TABLE Tags (Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL);'
  sqlite3 "$db" 'CREATE TABLE Indexers ("Id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "Name" TEXT NOT NULL, "Implementation" TEXT NOT NULL, "Settings" TEXT, "ConfigContract" TEXT, "Enable" INTEGER, "Priority" INTEGER NOT NULL, "Added" DATETIME NOT NULL, "Redirect" INTEGER NOT NULL, "AppProfileId" INTEGER NOT NULL, "Tags" TEXT, "DownloadClientId" INTEGER NOT NULL);'
  # Deliberately a DIFFERENT id than the source install's byparr=7.
  sqlite3 "$db" "INSERT INTO Tags (Id,Label) VALUES (2,'byparr');"
  printf '[misc]\napi_key = freshkey1234\n[categories]\n[[*]]\n' > "$root/config/sabnzbd/sabnzbd.ini"
  echo "$root"
}

_bundle() {  # a bundle referencing tag label "byparr" and a new label "vpn"
  local b; b=$(mktemp -d)
  printf 'DOWNLOADS_DIR=/mnt/videos/downloads\nUSENET_SERVER_HOST=news.example.net\n' > "$b/env.subset"
  cat > "$b/indexers.json" <<'JSON'
[{"Name":"NZBgeek","Implementation":"Newznab","Settings":"{\"apiKey\":\"indexerkey\"}","ConfigContract":"NewznabSettings","Enable":1,"Priority":25,"Redirect":0,"TagLabels":[]},
 {"Name":"Sample Tracker","Implementation":"Cardigann","Settings":"{\"definitionFile\":\"sample\"}","ConfigContract":"CardigannSettings","Enable":1,"Priority":25,"Redirect":0,"TagLabels":["byparr","vpn"]}]
JSON
  printf '[misc]\npre_check = 1\n[categories]\n[[movies]]\npriority = -100\n' > "$b/sabnzbd.subset.ini"
  printf '{"format":1,"stack_version":"v1.2.1","indexer_count":2}\n' > "$b/SETTINGS-MANIFEST"
  echo "$b"
}

_q() { sqlite3 "$1/config/prowlarr/prowlarr.db" "$2"; }

test_import_sets_user_env_and_leaves_generated_alone() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  grep -q '^DOWNLOADS_DIR=/mnt/videos/downloads$' "$inst/.env"
  grep -q '^USENET_SERVER_HOST=news.example.net$' "$inst/.env"
  # setup-generated values must survive untouched
  grep -q '^SABNZBD_API_KEY=freshkey1234$' "$inst/.env"
  grep -q '^HOST_LAN_IP=10.0.0.5$' "$inst/.env"
  rm -rf "$inst" "$b"
}

test_import_remaps_tag_labels_to_target_ids() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  # byparr is id 2 here, not 7 as in the source install.
  local tags; tags=$(_q "$inst" "SELECT Tags FROM Indexers WHERE Name='Sample Tracker';")
  python3 -c "
import json,sys
ids=json.loads('''$tags''')
assert 2 in ids, ids            # existing byparr id, remapped
assert len(ids)==2, ids         # plus the newly-created vpn tag
"
  rm -rf "$inst" "$b"
}

test_import_creates_missing_tags() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  [[ "$(_q "$inst" "SELECT COUNT(*) FROM Tags WHERE Label='vpn';")" -eq 1 ]]
  rm -rf "$inst" "$b"
}

test_import_upserts_by_name_rather_than_duplicating() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  _q "$inst" "INSERT INTO Indexers (Name,Implementation,Settings,ConfigContract,Enable,Priority,Added,Redirect,AppProfileId,Tags,DownloadClientId) VALUES ('NZBgeek','Newznab','{\"apiKey\":\"stale\"}','NewznabSettings',0,25,'2026-01-01',0,1,'[]',0);"
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  [[ "$(_q "$inst" "SELECT COUNT(*) FROM Indexers WHERE Name='NZBgeek';")" -eq 1 ]]
  # and it was updated, not left stale
  [[ "$(_q "$inst" "SELECT Settings FROM Indexers WHERE Name='NZBgeek';")" == *indexerkey* ]]
  rm -rf "$inst" "$b"
}

test_import_is_idempotent() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  [[ "$(_q "$inst" "SELECT COUNT(*) FROM Indexers;")" -eq 2 ]]
  [[ "$(_q "$inst" "SELECT COUNT(*) FROM Tags WHERE Label='vpn';")" -eq 1 ]]
  rm -rf "$inst" "$b"
}

test_import_merges_sab_categories() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  scripts/settings-bundle import "$b" "$inst" >/dev/null
  grep -q 'movies' "$inst/config/sabnzbd/sabnzbd.ini"
  # the generated api_key must survive the merge
  grep -q 'freshkey1234' "$inst/config/sabnzbd/sabnzbd.ini"
  rm -rf "$inst" "$b"
}

test_import_rejects_an_unknown_bundle_format() {
  local inst; inst=$(_fresh_install); local b; b=$(_bundle)
  printf '{"format":99}\n' > "$b/SETTINGS-MANIFEST"
  refute scripts/settings-bundle import "$b" "$inst" >/dev/null 2>&1
  rm -rf "$inst" "$b"
}

test_import_refuses_an_install_that_was_never_set_up() {
  local root; root=$(mktemp -d); local b; b=$(_bundle)
  refute scripts/settings-bundle import "$b" "$root" >/dev/null 2>&1
  rm -rf "$root" "$b"
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep settings_bundle_import`
Expected: FAIL — `import` is not a subcommand yet.

- [ ] **Step 3: Implement the importer**

Add to `scripts/settings-bundle`:

```python
def set_env_value(path: Path, key: str, value: str) -> None:
    """Set one key, preserving every other line. Mirrors write_env_value."""
    quoted = value
    if value == "" or any(c in value for c in ' \t"\'$\\'):
        quoted = '"' + value.replace('"', '\\"') + '"'
    lines = path.read_text().splitlines() if path.is_file() else []
    for i, line in enumerate(lines):
        if line.split("=", 1)[0].strip() == key:
            lines[i] = f"{key}={quoted}"
            break
    else:
        lines.append(f"{key}={quoted}")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)


def resolve_tag_ids(con: sqlite3.Connection, labels: list[str]) -> list[int]:
    """Map labels to ids in THIS database, creating any that are missing."""
    ids = []
    for label in labels:
        row = con.execute("SELECT Id FROM Tags WHERE Label = ?", (label,)).fetchone()
        if row is None:
            cur = con.execute("INSERT INTO Tags (Label) VALUES (?)", (label,))
            ids.append(cur.lastrowid)
        else:
            ids.append(row[0])
    return ids


def import_indexers(db: Path, rows: list[dict]) -> int:
    """Upsert by Name. Ids, AppProfileId and DownloadClientId stay the target's."""
    if not db.is_file() or not rows:
        return 0
    con = sqlite3.connect(db)
    try:
        n = 0
        for row in rows:
            tags = json.dumps(resolve_tag_ids(con, row.get("TagLabels", [])))
            existing = con.execute(
                "SELECT Id FROM Indexers WHERE Name = ?", (row["Name"],)
            ).fetchone()
            if existing:
                con.execute(
                    "UPDATE Indexers SET Implementation=?, Settings=?, ConfigContract=?,"
                    " Enable=?, Priority=?, Redirect=?, Tags=? WHERE Id=?",
                    (row["Implementation"], row["Settings"], row["ConfigContract"],
                     row["Enable"], row["Priority"], row["Redirect"], tags, existing[0]),
                )
            else:
                con.execute(
                    "INSERT INTO Indexers (Name, Implementation, Settings, ConfigContract,"
                    " Enable, Priority, Added, Redirect, AppProfileId, Tags, DownloadClientId)"
                    " VALUES (?,?,?,?,?,?,datetime('now'),?,1,?,0)",
                    (row["Name"], row["Implementation"], row["Settings"],
                     row["ConfigContract"], row["Enable"], row["Priority"],
                     row["Redirect"], tags),
                )
            n += 1
        con.commit()
        return n
    finally:
        con.close()


def import_sab(ini: Path, subset: str) -> None:
    """Replace [categories] wholesale and set the listed [misc] keys in place."""
    if not ini.is_file() or not subset.strip():
        return
    new_misc, new_cats = {}, []
    for top, line in _sab_sections(subset):
        stripped = line.strip()
        if top == "misc" and "=" in stripped:
            k, _, v = stripped.partition("=")
            new_misc[k.strip()] = v.strip()
        elif top == "categories" and not stripped.startswith("[categories]"):
            new_cats.append(line)

    out, in_cats, seen = [], False, set()
    for top, line in _sab_sections(ini.read_text()):
        stripped = line.strip()
        if stripped == "[categories]":
            in_cats = True
            out.append(line)
            out.extend(new_cats)
            continue
        if in_cats:
            # Skip the old categories body; stop at the next top-level section.
            if stripped.startswith("[") and not stripped.startswith("[["):
                in_cats = False
            else:
                continue
        if top == "misc" and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in new_misc:
                out.append(f"{key} = {new_misc[key]}")
                seen.add(key)
                continue
        out.append(line)
    # Any tuned key the target did not already have.
    for k, v in new_misc.items():
        if k not in seen:
            for i, line in enumerate(out):
                if line.strip() == "[misc]":
                    out.insert(i + 1, f"{k} = {v}")
                    break
    ini.write_text("\n".join(out) + "\n")


def cmd_import(bundle: Path, install: Path) -> None:
    manifest_path = bundle / "SETTINGS-MANIFEST"
    if not manifest_path.is_file():
        die(f"no SETTINGS-MANIFEST in {bundle} — not a settings bundle")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("format") != BUNDLE_FORMAT:
        die(f"bundle format {manifest.get('format')} is not supported "
            f"(this build understands {BUNDLE_FORMAT})")

    env_path = install / ".env"
    if not env_path.is_file():
        die(f"no .env in {install} — run ./setup before importing settings")

    for key, value in read_env(bundle / "env.subset").items():
        if key in ENV_KEYS:
            set_env_value(env_path, key, value)

    rows = json.loads((bundle / "indexers.json").read_text()) if (bundle / "indexers.json").is_file() else []
    n = import_indexers(install / "config/prowlarr/prowlarr.db", rows)

    sab = bundle / "sabnzbd.subset.ini"
    if sab.is_file():
        import_sab(install / "config/sabnzbd/sabnzbd.ini", sab.read_text())

    print(f"imported {n} indexer(s); run ./setup --non-interactive to rewire")
```

and register the subcommand in `main()`:

```python
    i = sub.add_parser("import")
    i.add_argument("bundle")
    i.add_argument("install")
```
```python
    elif args.cmd == "import":
        cmd_import(Path(args.bundle), Path(args.install))
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep settings_bundle_import`
Expected: eight PASS lines.

- [ ] **Step 5: Commit**

```bash
git add scripts/settings-bundle tests/settings_bundle_import.test
git commit -m "feat: merge a settings bundle into an installed stack"
```

---

## Task S3: Wire the flags into `backup` and `restore`

**Files:**
- Modify: `backup`
- Modify: `restore`
- Test: `tests/settings_bundle_roundtrip.test`

- [ ] **Step 1: Write the failing round-trip test**

Create `tests/settings_bundle_roundtrip.test`. Reuse the install builders by
copying them in (the runner sources each file standalone, so they cannot import
from another test file):

```bash
#!/usr/bin/env bash
set -u

# Source install: user-supplied values plus secrets that must NOT travel.
_source_install() {
  local root; root=$(mktemp -d)
  mkdir -p "$root/config/prowlarr" "$root/config/sabnzbd"
  cat > "$root/.env" <<'ENV'
DOWNLOADS_DIR=/mnt/videos/downloads
COMPLETED_DIR=/mnt/videos/completed
USENET_SERVER_HOST=news.example.net
USENET_SERVER_PASSWORD=somepass
WIREGUARD_PRIVATE_KEY=SECRETKEY=
SABNZBD_API_KEY=sourcekey
ENV
  local db="$root/config/prowlarr/prowlarr.db"
  sqlite3 "$db" 'CREATE TABLE Tags (Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL);'
  sqlite3 "$db" 'CREATE TABLE Indexers ("Id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "Name" TEXT NOT NULL, "Implementation" TEXT NOT NULL, "Settings" TEXT, "ConfigContract" TEXT, "Enable" INTEGER, "Priority" INTEGER NOT NULL, "Added" DATETIME NOT NULL, "Redirect" INTEGER NOT NULL, "AppProfileId" INTEGER NOT NULL, "Tags" TEXT, "DownloadClientId" INTEGER NOT NULL);'
  sqlite3 "$db" "INSERT INTO Tags (Id,Label) VALUES (7,'byparr');"
  sqlite3 "$db" "INSERT INTO Indexers (Name,Implementation,Settings,ConfigContract,Enable,Priority,Added,Redirect,AppProfileId,Tags,DownloadClientId) VALUES ('NZBgeek','Newznab','{\"apiKey\":\"indexerkey\"}','NewznabSettings',1,25,'2026-01-01',0,1,'[7]',0);"
  printf '[misc]\napi_key = sourcekey\n[categories]\n[[movies]]\npriority = -100\n' > "$root/config/sabnzbd/sabnzbd.ini"
  echo "$root"
}

_target_install() {
  local root; root=$(mktemp -d)
  mkdir -p "$root/config/prowlarr" "$root/config/sabnzbd"
  printf 'DOWNLOADS_DIR=/tmp/wrong\nSABNZBD_API_KEY=targetkey\n' > "$root/.env"
  local db="$root/config/prowlarr/prowlarr.db"
  sqlite3 "$db" 'CREATE TABLE Tags (Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL);'
  sqlite3 "$db" 'CREATE TABLE Indexers ("Id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "Name" TEXT NOT NULL, "Implementation" TEXT NOT NULL, "Settings" TEXT, "ConfigContract" TEXT, "Enable" INTEGER, "Priority" INTEGER NOT NULL, "Added" DATETIME NOT NULL, "Redirect" INTEGER NOT NULL, "AppProfileId" INTEGER NOT NULL, "Tags" TEXT, "DownloadClientId" INTEGER NOT NULL);'
  sqlite3 "$db" "INSERT INTO Tags (Id,Label) VALUES (3,'byparr');"
  printf '[misc]\napi_key = targetkey\n[categories]\n[[*]]\n' > "$root/config/sabnzbd/sabnzbd.ini"
  echo "$root"
}

test_roundtrip_carries_user_settings_and_not_secrets() {
  local src; src=$(_source_install)
  local dst; dst=$(_target_install)
  local b; b=$(mktemp -d)

  scripts/settings-bundle export "$src" "$b" >/dev/null
  scripts/settings-bundle import "$b" "$dst" >/dev/null

  # user-supplied values travelled
  grep -q '^DOWNLOADS_DIR=/mnt/videos/downloads$' "$dst/.env"
  grep -q 'somepass' "$dst/.env"
  [[ "$(sqlite3 "$dst/config/prowlarr/prowlarr.db" "SELECT COUNT(*) FROM Indexers WHERE Name='NZBgeek';")" -eq 1 ]]
  # the tag was remapped from source id 7 to target id 3
  [[ "$(sqlite3 "$dst/config/prowlarr/prowlarr.db" "SELECT Tags FROM Indexers WHERE Name='NZBgeek';")" == *3* ]]
  # secrets and generated values did NOT travel
  refute_grep 'WIREGUARD_PRIVATE_KEY' \"$dst/.env\"
  refute_grep 'sourcekey' \"$dst/.env\"
  grep -q '^SABNZBD_API_KEY=targetkey$' "$dst/.env"

  rm -rf "$src" "$dst" "$b"
}

test_backup_settings_only_produces_a_tarball_with_the_four_members() {
  local src; src=$(_source_install)
  local out; out="$(mktemp -d)/bundle.tar.gz"
  ( cd "$src" && cp -r "$OLDPWD/scripts" . 2>/dev/null || true )
  ./backup --settings-only --install-dir "$src" --output "$out" --yes >/dev/null 2>&1
  tar tzf "$out" | grep -q 'SETTINGS-MANIFEST'
  tar tzf "$out" | grep -q 'env.subset'
  tar tzf "$out" | grep -q 'indexers.json'
  refute sh -c \"tar tzf "$out" | grep -q 'prowlarr.db'\"
  rm -rf "$src" "$(dirname "$out")"
}
```

NOTE: `backup` currently operates on its own directory. If `--install-dir` does
not exist as a flag, add it, or restructure the test to run `./backup` with the
CWD set appropriately. Use whichever fits the existing script — but the
assertion that `prowlarr.db` is **absent** from a settings-only tarball must
survive, because that is what proves the bundle is a subset and not a full
backup under a new name.

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep settings_bundle_roundtrip`
Expected: FAIL.

- [ ] **Step 3: Add `--settings-only` to `backup`**

In `backup`'s flag loop add `--settings-only) SETTINGS_ONLY=1; shift ;;` (default
`SETTINGS_ONLY=0`), extend the `--help` text, and branch before the existing
tar: when set, export into a temp dir via `scripts/settings-bundle export`, tar
those four members, name the output
`prowlarr-stack-settings-<host>-<UTC>.tar.gz`, and skip the stop-the-stack step
entirely — the exporter opens SQLite read-only, so there is no WAL risk.

Keep the existing mode-600 and refuse-to-write-into-a-git-directory guards. They
matter more here, not less: the bundle still holds a usenet password and
indexer API keys.

- [ ] **Step 4: Add `--settings-only` to `restore`**

In `restore`'s flag loop add `--settings-only) SETTINGS_ONLY=1; shift ;;`. When
set: extract the tarball to a temp dir, run `scripts/settings-bundle import
<tmp> .`, then `./setup --non-interactive`. Skip the full-replace path, the
LAN-key scrubbing, and the pre-restore snapshot of `config/` — a merge does not
replace anything that would need rolling back.

Refuse `--settings-only` together with a tarball that has no `SETTINGS-MANIFEST`,
and refuse a full restore of a settings bundle, with a message naming the other
flag.

- [ ] **Step 5: Run the full suite**

Run: `scripts/test`
Expected: `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add backup restore tests/settings_bundle_roundtrip.test
git commit -m "feat: --settings-only on backup and restore"
```

---

## Task S4: Documentation

**Files:**
- Modify: `docs/architecture.md`, `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Document the two scopes**

Add a "Settings bundle" subsection to `docs/architecture.md` near the
backup/restore material, stating plainly: a full backup reproduces *this
install*; a settings bundle carries only what a human supplied, so the stack can
be rebuilt through the ordinary installer. Include the three-category glossary
(stack-generated / machine-derived / user-supplied) and the explicit list of
what is excluded.

- [ ] **Step 2: Add the rebuild recipe**

```bash
./backup --settings-only                 # keep the bundle somewhere safe
# reinstall via the ordinary installer
./restore --settings-only <bundle.tar.gz>
./check
```

- [ ] **Step 3: CHANGELOG**

```markdown
### Added
- `./backup --settings-only` and `./restore --settings-only`: carry just the
  settings you supplied — storage paths, usenet account, indexer definitions,
  SABnzbd settings — so you can rebuild through the ordinary installer without
  re-entering them. Excludes everything the stack regenerates, including your
  WireGuard key.
```

- [ ] **Step 4: Commit**

```bash
git add docs/architecture.md README.md CHANGELOG.md
git commit -m "docs: settings bundle"
```

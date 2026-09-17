# Per-Indexer Egress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make VPN egress a property of the indexer rather than of the stack, so a usenet-only install works with no VPN while torrent indexers still cannot reach the ISP path.

**Architecture:** Prowlarr leaves gluetun's network namespace and publishes its own port. gluetun and byparr move behind a Compose profile (`COMPOSE_PROFILES=vpn`) so they are absent when no VPN is configured. Torrent indexers reach the tunnel through a Prowlarr **indexer proxy** (`Http` → `gluetun:8888`) scoped by a `vpn` tag, which `setup` applies automatically. `check` replaces its exit-IP comparison with a per-indexer tag assertion.

**Tech Stack:** Bash, Docker Compose 5.5.0, SQLite (`sqlite3` against `prowlarr.db`), Prowlarr v1 REST API, gluetun (WireGuard + built-in HTTP proxy).

**Spec:** `docs/superpowers/specs/2026-09-17-per-indexer-egress-design.md`

---

## Working against the live install

The source repo is `~/src/media-centaur/prowlarr-stack`; the running install is
`~/prowlarr-stack`. To exercise a change live, copy the specific changed files
into the install and run its `./check`:

```bash
cp docker-compose.yml scripts/lib/common check ~/prowlarr-stack/
cd ~/prowlarr-stack && ./scripts/restart && ./check
```

Never run `./setup` against `~/prowlarr-stack` with a partially-applied change —
it rewrites `.env` and patches `prowlarr.db`.

**Current machine state:** the VPN subscription is cancelled, so gluetun's tunnel
is dead and Prowlarr has no egress. Phase 1 is fully verifiable and *fixes* that.
Phase 2 is verifiable by substitution (Task 8) without a working tunnel; only the
final live-tunnel integration stays unproven, which is called out in Task 12.

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `docker-compose.yml` | Service topology | Prowlarr direct; `profiles: ["vpn"]` on gluetun + byparr; `HTTPPROXY=on` |
| `setup` | Config prompts, `.env`, DB patching, start, verify | VPN creds optional; writes `COMPOSE_PROFILES`; invokes tagging |
| `check` | Health + topology gate for `./update` | gluetun gate conditional on profile |
| `scripts/lib/common` | Shared helpers | `verify_services` probes Prowlarr directly; `verify_isolation` rewritten |
| `scripts/tag-vpn-indexers` | **New.** Tag torrent indexers with `vpn` | Sibling of `scripts/tag-cf-indexers` |
| `scripts/patch-prowlarr-db` | Seed Prowlarr rows | Seed `vpn` tag + `Http` proxy; re-point byparr host |
| `migrations/0004-per-indexer-egress` | **New.** Upgrade existing installs | `.env` profile, proxy rows, byparr host |
| `tests/*.test` | Pure-bash tests, run by `scripts/test` | New + updated |

Run the whole suite with `scripts/test`. It sources each `tests/*.test` and runs
every `test_*` function in its own subshell.

---

# Phase 0 — Resolve the spec's open dependency

## Task 1: Determine whether gluetun accepts bridge-inbound on 8888

The spec flags this as unverified and gating: gluetun's HTTP proxy must accept
connections from sibling containers on the compose bridge. This is answerable
**now**, with the tunnel dead — a refused connection and a connected-but-failing
proxy are distinguishable.

**Files:**
- Modify: `docker-compose.yml` (temporary, reverted at the end of this task)

- [ ] **Step 1: Turn the proxy on temporarily**

In `~/prowlarr-stack/docker-compose.yml`, add to the `gluetun` service's
`environment:` list:

```yaml
      - HTTPPROXY=on
```

- [ ] **Step 2: Recreate gluetun and confirm the proxy started**

```bash
cd ~/prowlarr-stack && docker compose up -d gluetun
sleep 5
docker logs gluetun 2>&1 | grep -i "http proxy" | tail -5
```

Expected: a line showing the HTTP proxy listening (e.g. `http proxy: listening on :8888`).

- [ ] **Step 3: Probe from a sibling container on the bridge**

```bash
NET=$(docker inspect gluetun -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
echo "network: $NET"
docker run --rm --network "$NET" alpine sh -c 'nc -z -w3 gluetun 8888; echo "exit=$?"'
```

Expected one of:
- `exit=0` — the firewall accepts bridge-inbound. No compose change needed; record this in the task notes.
- `exit=1` — refused or filtered. Proceed to Step 4.

- [ ] **Step 4: If refused, add the firewall allowance and re-probe**

Add to gluetun's `environment:`:

```yaml
      - FIREWALL_INPUT_PORTS=8888
```

Then:

```bash
cd ~/prowlarr-stack && docker compose up -d gluetun && sleep 5
NET=$(docker inspect gluetun -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
docker run --rm --network "$NET" alpine sh -c 'nc -z -w3 gluetun 8888; echo "exit=$?"'
```

Expected: `exit=0`.

- [ ] **Step 5: Revert the live install and record the finding**

```bash
cd ~/prowlarr-stack && git diff --stat 2>/dev/null || true
# restore docker-compose.yml from the source repo
cp ~/src/media-centaur/prowlarr-stack/docker-compose.yml ~/prowlarr-stack/docker-compose.yml
cd ~/prowlarr-stack && docker compose up -d gluetun
```

Write the answer into the spec's "One unverified dependency" section: whether
`FIREWALL_INPUT_PORTS=8888` is required. Task 9 depends on this answer.

- [ ] **Step 6: Commit the spec update**

```bash
cd ~/src/media-centaur/prowlarr-stack
git add docs/superpowers/specs/2026-09-17-per-indexer-egress-design.md
git commit -m "docs: record gluetun bridge-inbound finding for 8888"
```

---

# Phase 1 — The no-VPN stack

At the end of this phase a usenet-only install works and the live machine's
indexers are reachable again.

## Task 2: Compose profiles and direct Prowlarr

**Files:**
- Modify: `docker-compose.yml`
- Test: `tests/compose_profiles.test`

- [ ] **Step 1: Write the failing test**

Create `tests/compose_profiles.test`:

```bash
#!/usr/bin/env bash
set -u

# Resolve the compose project with a given .env, echoing the service list.
_services() {  # _services <env-contents>
  local root; root=$(mktemp -d)
  cp docker-compose.yml docker-compose.qbt-vpn.yml "$root/"
  printf '%s\n' "$1" > "$root/.env"
  (cd "$root" && docker compose config --services 2>&1 | sort | tr '\n' ' ')
  rm -rf "$root"
}

test_vpn_services_absent_without_profile() {
  local out; out=$(_services "DOWNLOADS_DIR=/tmp/d
COMPLETED_DIR=/tmp/c")
  [[ "$out" != *gluetun* ]]
  [[ "$out" != *byparr* ]]
  [[ "$out" == *prowlarr* ]]
  [[ "$out" == *sabnzbd* ]]
  [[ "$out" == *qbittorrent* ]]
}

test_vpn_services_present_with_profile() {
  local out; out=$(_services "COMPOSE_PROFILES=vpn
DOWNLOADS_DIR=/tmp/d
COMPLETED_DIR=/tmp/c")
  [[ "$out" == *gluetun* ]]
  [[ "$out" == *byparr* ]]
  [[ "$out" == *prowlarr* ]]
}

test_qbt_vpn_overlay_without_profile_is_rejected() {
  local out; out=$(_services "COMPOSE_FILE=docker-compose.yml:docker-compose.qbt-vpn.yml
DOWNLOADS_DIR=/tmp/d
COMPLETED_DIR=/tmp/c")
  [[ "$out" == *"depends on undefined service"* ]]
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `scripts/test 2>&1 | grep compose_profiles`
Expected: `FAIL tests/compose_profiles.test::test_vpn_services_absent_without_profile` — gluetun is currently unconditional.

- [ ] **Step 3: Apply the compose change**

In `docker-compose.yml`:

`gluetun` — add a profile, and drop the Prowlarr port it no longer fronts:

```yaml
  gluetun:
    image: qmcgaw/gluetun:v3.41.3
    container_name: gluetun
    profiles: ["vpn"]
    cap_add: [NET_ADMIN]
```

and in its `ports:` list remove `- "9696:9696"   # prowlarr (netns-shared)`,
keeping `- "8191:8191"   # byparr solver (netns-shared)`.

`prowlarr` — leave the namespace, publish its own port:

```yaml
  prowlarr:
    image: linuxserver/prowlarr:2.5.2.5491-ls158
    container_name: prowlarr
    ports:
      - "9696:9696"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Amsterdam
    volumes:
      - ./config/prowlarr:/config
    restart: "no"
```

(The `network_mode` and `depends_on` keys are deleted.)

`byparr` — add the profile, keep everything else:

```yaml
  byparr:
    image: ghcr.io/thephaseless/byparr:3.0.4
    container_name: byparr
    profiles: ["vpn"]
    network_mode: "service:gluetun"
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `scripts/test 2>&1 | grep compose_profiles`
Expected: three `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml tests/compose_profiles.test
git commit -m "feat: gate gluetun and byparr behind the vpn compose profile"
```

## Task 3: `setup` makes VPN credentials optional

**Files:**
- Modify: `setup:54-113` (VPN prompt block), `setup:213-231` (`.env` write)
- Test: `tests/setup_vpn_optional.test`

- [ ] **Step 1: Write the failing test**

Create `tests/setup_vpn_optional.test`:

```bash
#!/usr/bin/env bash
set -u
source scripts/lib/common

test_compose_profiles_written_when_vpn_configured() {
  local f; f=$(mktemp)
  write_env_value "$f" VPN_SERVICE_PROVIDER "nordvpn"
  write_env_value "$f" COMPOSE_PROFILES "vpn"
  [[ "$(read_env_value "$f" COMPOSE_PROFILES)" == "vpn" ]]
  rm -f "$f"
}

test_compose_profiles_absent_when_no_vpn() {
  local f; f=$(mktemp)
  write_env_value "$f" DOWNLOADS_DIR "/tmp/d"
  [[ -z "$(read_env_value "$f" COMPOSE_PROFILES)" ]]
  rm -f "$f"
}

test_qbt_vpn_requires_vpn_credentials() {
  # setup must refuse QBITTORRENT_USE_VPN=1 with no provider configured.
  ! validate_vpn_combination "" 1 >/dev/null 2>&1
}

test_qbt_vpn_allowed_with_a_provider() {
  validate_vpn_combination "nordvpn" 1 >/dev/null 2>&1
}

test_qbt_direct_allowed_without_a_provider() {
  validate_vpn_combination "" 0 >/dev/null 2>&1
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `scripts/test 2>&1 | grep setup_vpn_optional`
Expected: `FAIL ...::test_qbt_vpn_requires_vpn_credentials` — `validate_vpn_combination` does not exist.

- [ ] **Step 3: Add the validator to `scripts/lib/common`**

Append to `scripts/lib/common`:

```bash
# validate_vpn_combination <provider> <qbt_use_vpn>
# Tunneling qBittorrent requires a VPN to tunnel through. Compose rejects the
# combination at validation time too, but failing here gives a better message.
validate_vpn_combination() {
  local provider="$1" qbt="$2"
  if [[ "$qbt" == "1" && -z "$provider" ]]; then
    log_fail "config" "QBITTORRENT_USE_VPN=1 requires a VPN provider"
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Make the VPN prompts optional in `setup`**

Replace the mandatory provider block (around `setup:66-74`) with:

```bash
provider=$(read_env_value "$ENV_FILE" VPN_SERVICE_PROVIDER)
if [[ -z "$provider" && $NONINTERACTIVE -eq 0 ]]; then
  echo ""
  log_info "VPN routing (optional)"
  log_info "  A VPN is used ONLY for torrent indexers: most are ISP-blocked, and"
  log_info "  peers see your address. Usenet indexers never need one."
  log_info "  Leave blank for a usenet-only stack."
  log_info "Supported providers: ${!VPN_PROVIDERS[*]}"
  provider=$(prompt_with_default "VPN provider (blank for none)" "${provider:-}")
fi

if [[ -n "$provider" ]]; then
  validate_vpn_provider "$provider" >/dev/null 2>&1 || die "invalid VPN_SERVICE_PROVIDER: $provider"
else
  log_info "no VPN configured — torrent indexers will be unavailable"
fi
```

Then guard the key/address/preshared prompts that follow with `if [[ -n "$provider" ]]; then ... fi`, and guard the tunnel wait (`setup:460-471`) the same way.

- [ ] **Step 5: Write `COMPOSE_PROFILES` in the `.env` phase**

After the existing `write_env_value "$ENV_FILE" QBITTORRENT_USE_VPN "$qbt_use_vpn"` line, add:

```bash
validate_vpn_combination "$provider" "$qbt_use_vpn" || die "invalid VPN configuration"

if [[ -n "$provider" ]]; then
  write_env_value "$ENV_FILE" COMPOSE_PROFILES "vpn"
else
  write_env_value "$ENV_FILE" COMPOSE_PROFILES ""
fi
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test 2>&1 | grep setup_vpn_optional`
Expected: three `PASS` lines.

- [ ] **Step 7: Commit**

```bash
git add setup scripts/lib/common tests/setup_vpn_optional.test
git commit -m "feat: make VPN credentials optional in setup"
```

## Task 4: `verify_services` probes Prowlarr directly

**Files:**
- Modify: `scripts/lib/common:706-742` (`verify_services`)
- Test: `tests/verify_services.test` (existing — update)

- [ ] **Step 1: Update the test**

Add behavioural tests to `tests/verify_services.test`. These assert what
`verify_services` *does*, not what its source text says — never grep the
implementation to test it.

The file already stubs `http_probe_in_container` with a URL-keyed `RESPONSES`
table. Extend that idea: make the stub refuse the Prowlarr probe unless it is
addressed to the `prowlarr` container, so a probe still routed through gluetun
shows up as "prowlarr is down".

```bash
test_prowlarr_probe_targets_the_prowlarr_container() {
  _all_healthy
  # Answer :9696 ONLY when probed in the prowlarr container. If verify_services
  # still probes through gluetun, prowlarr reads as down and this fails.
  http_probe_in_container() {
    local container="$1" url="$2"
    if [[ "$url" == *"9696/ping"* ]]; then
      [[ "$container" == "prowlarr" ]] || return 1
      echo '{"status": "OK"}'
      return 0
    fi
    local key
    for key in "${!RESPONSES[@]}"; do
      [[ "$url" == *"$key"* ]] && { echo "${RESPONSES[$key]}"; return 0; }
    done
    return 1
  }
  verify_services 5 >/dev/null 2>&1
}

test_byparr_is_not_probed_without_the_vpn_profile() {
  # byparr is absent from the project entirely when the profile is off, so a
  # non-answering solver must not be a failure.
  _all_healthy
  unset 'RESPONSES[8191/health]'
  vpn_profile_active() { return 1; }
  verify_services 2 >/dev/null 2>&1
}

test_byparr_is_probed_under_the_vpn_profile() {
  _all_healthy
  unset 'RESPONSES[8191/health]'
  vpn_profile_active() { return 0; }
  ! verify_services 2 >/dev/null 2>&1
}
```

If `wait_for_http` invokes the probe in a subshell in a way that defeats the
function override, report that rather than falling back to a source grep.

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep verify_services`
Expected: `FAIL` on both new functions.

- [ ] **Step 3: Add a profile helper and rewrite the probes**

Append to `scripts/lib/common`:

```bash
# vpn_profile_active [env_file]
# True when the vpn compose profile is active, i.e. gluetun/byparr exist.
vpn_profile_active() {
  local f="${1:-.env}"
  [[ "$(read_env_value "$f" COMPOSE_PROFILES 2>/dev/null)" == *vpn* ]]
}
```

In `verify_services`, change the Prowlarr probe subject from `gluetun` to
`prowlarr`:

```bash
  if wait_for_http prowlarr "http://127.0.0.1:9696/ping" "OK" "$timeout"; then
```

and wrap the byparr probe:

```bash
  if vpn_profile_active; then
    if wait_for_http gluetun "http://127.0.0.1:8191/health" "Byparr" "$timeout"; then
      log_ok "byparr" "solver responding (:8191/health)"
    else
      log_fail "byparr" "solver did not respond within ${timeout}s"
      log_info "check: docker logs byparr"
      failed=1
    fi
  fi
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep verify_services`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common tests/verify_services.test
git commit -m "fix: probe prowlarr directly and gate byparr on the vpn profile"
```

## Task 5: `check`'s gluetun gate becomes conditional

**Files:**
- Modify: `check:18-27`
- Test: `tests/check_gluetun_gate.test`

- [ ] **Step 1: Write the failing test**

The gate currently sits inline in `check`, where it can only be tested by
grepping the script — which this repo does not do. Extract it into
`scripts/lib/common` as a function first, then test the function's behaviour.

Create `tests/check_gluetun_gate.test`:

```bash
#!/usr/bin/env bash
set -u
source "./scripts/lib/common"

# Stub the health lookup; the real one shells out to docker inspect.
_with_health() { gluetun_health_status() { echo "$1"; }; }

test_tunnel_gate_passes_when_gluetun_healthy() {
  vpn_profile_active() { return 0; }
  _with_health healthy
  assert_tunnel_healthy >/dev/null 2>&1
}

test_tunnel_gate_fails_when_gluetun_unhealthy() {
  vpn_profile_active() { return 0; }
  _with_health unhealthy
  ! assert_tunnel_healthy >/dev/null 2>&1
}

test_tunnel_gate_fails_when_gluetun_missing() {
  vpn_profile_active() { return 0; }
  _with_health missing
  ! assert_tunnel_healthy >/dev/null 2>&1
}

test_tunnel_gate_is_skipped_without_the_vpn_profile() {
  # No VPN configured: gluetun is absent by design, so its absence is not a fault.
  vpn_profile_active() { return 1; }
  _with_health missing
  assert_tunnel_healthy >/dev/null 2>&1
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep check_gluetun_gate`
Expected: `FAIL ...::test_gluetun_gate_is_guarded_by_profile`.

- [ ] **Step 3: Guard the gate**

Move the gate into `scripts/lib/common` as two functions — one that reads the
status (stubbable), one that decides:

```bash
# gluetun_health_status — the container's health, or "missing" if absent.
gluetun_health_status() {
  docker inspect --format '{{.State.Health.Status}}' gluetun 2>/dev/null || echo "missing"
}

# assert_tunnel_healthy — fatal gate, but only when a VPN is configured.
# With no VPN the gluetun container is absent by design, not broken.
assert_tunnel_healthy() {
  if ! vpn_profile_active; then
    log_info "no VPN configured — skipping tunnel checks"
    return 0
  fi
  log_phase "gluetun health"
  local status; status=$(gluetun_health_status)
  case "$status" in
    healthy) log_ok "gluetun" "$status"; return 0 ;;
    missing) log_fail "gluetun" "container is not running — start the stack first"; return 1 ;;
    *) log_fail "gluetun" "$status — check: docker logs gluetun"; return 1 ;;
  esac
}
```

Then `check`'s inline block collapses to:

```bash
assert_tunnel_healthy || die "gluetun is not healthy — check: docker logs gluetun"
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep check_gluetun_gate`
Expected: two `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add check tests/check_gluetun_gate.test
git commit -m "fix: make the gluetun health gate conditional on the vpn profile"
```

## Task 6: `verify_isolation` — the no-VPN branch

**Files:**
- Modify: `scripts/lib/common:615-653`
- Test: `tests/verify_isolation.test`

- [ ] **Step 1: Write the failing test**

Create `tests/verify_isolation.test`:

```bash
#!/usr/bin/env bash
set -u
source scripts/lib/common

# Fake the API surface: $1 = JSON array as /api/v1/indexer would return it.
_fake_indexers() { printf '%s' "$1" > "$FAKE_INDEXERS"; }

setup_fake() {
  FAKE_INDEXERS=$(mktemp)
  export FAKE_INDEXERS
  fetch_indexers() { cat "$FAKE_INDEXERS"; }
}

test_no_vpn_with_only_usenet_indexers_passes() {
  setup_fake
  _fake_indexers '[{"id":15,"name":"NZBgeek","protocol":"usenet","enable":true,"tags":[]}]'
  assert_torrent_indexers_tagged "" ""
}

test_no_vpn_with_enabled_torrent_indexer_fails() {
  setup_fake
  _fake_indexers '[{"id":9,"name":"Sample Tracker","protocol":"torrent","enable":true,"tags":[]}]'
  ! assert_torrent_indexers_tagged "" ""
}

test_vpn_with_untagged_torrent_indexer_fails() {
  setup_fake
  _fake_indexers '[{"id":9,"name":"Sample Tracker","protocol":"torrent","enable":true,"tags":[]}]'
  ! assert_torrent_indexers_tagged "vpn" "3"
}

test_vpn_with_tagged_torrent_indexer_passes() {
  setup_fake
  _fake_indexers '[{"id":9,"name":"Sample Tracker","protocol":"torrent","enable":true,"tags":[3]}]'
  assert_torrent_indexers_tagged "vpn" "3"
}

test_disabled_torrent_indexer_is_ignored() {
  setup_fake
  _fake_indexers '[{"id":9,"name":"Sample Tracker","protocol":"torrent","enable":false,"tags":[]}]'
  assert_torrent_indexers_tagged "" ""
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep verify_isolation`
Expected: `FAIL` on all five — `assert_torrent_indexers_tagged` does not exist.

- [ ] **Step 3: Implement the assertion**

Append to `scripts/lib/common`:

```bash
# fetch_indexers — Prowlarr's indexer list as JSON. Overridable in tests.
fetch_indexers() {
  local key; key=$(fetch_prowlarr_api_key) || return 1
  curl -fsS --max-time 30 -H "X-Api-Key: $key" "http://127.0.0.1:9696/api/v1/indexer"
}

# assert_torrent_indexers_tagged <profile> <vpn_tag_id>
# With no VPN (<profile> empty): no enabled torrent indexer may exist — it could
# not reach an ISP-blocked site, and would leak if it could.
# With a VPN: every enabled torrent indexer must carry the vpn tag.
assert_torrent_indexers_tagged() {
  local profile="$1" tagid="$2" json bad
  json=$(fetch_indexers) || { log_fail "indexers" "could not read Prowlarr's indexer list"; return 1; }

  if [[ -z "$profile" ]]; then
    bad=$(jexpr "$json" "(SELECT group_concat(json_extract(value,'\$.name'),', ')
      FROM json_each(j)
      WHERE json_extract(value,'\$.protocol')='torrent'
        AND json_extract(value,'\$.enable') IN (1,'true'))")
    if [[ -n "$bad" ]]; then
      log_fail "indexers" "torrent indexers enabled with no VPN configured: $bad"
      log_info "configure a VPN (./setup --reconfigure) or disable them in Prowlarr"
      return 1
    fi
    log_ok "indexers" "usenet-only; no VPN needed"
    return 0
  fi

  bad=$(jexpr "$json" "(SELECT group_concat(json_extract(value,'\$.name'),', ')
    FROM json_each(j)
    WHERE json_extract(value,'\$.protocol')='torrent'
      AND json_extract(value,'\$.enable') IN (1,'true')
      AND NOT EXISTS (SELECT 1 FROM json_each(json_extract(value,'\$.tags')) t WHERE t.value=$tagid))")
  if [[ -n "$bad" ]]; then
    log_fail "indexers" "torrent indexers missing the vpn tag: $bad"
    log_info "fix: scripts/tag-vpn-indexers"
    return 1
  fi
  log_ok "indexers" "every enabled torrent indexer carries the vpn tag"
  return 0
}
```

`jexpr` is currently local to `scripts/tag-cf-indexers`. Move it verbatim into
`scripts/lib/common` and delete the copy in `tag-cf-indexers`, which sources
common already.

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep verify_isolation`
Expected: five `PASS` lines.

- [ ] **Step 5: Rewrite `verify_isolation` to use it**

Replace the body of `verify_isolation` with:

```bash
verify_isolation() {
  log_phase "verification"

  if ! vpn_profile_active; then
    assert_torrent_indexers_tagged "" "" || return 1
    return 0
  fi

  local tagid json
  json=$(fetch_prowlarr_tags) || { log_fail "tags" "could not read Prowlarr tags"; return 1; }
  tagid=$(jexpr "$json" "(SELECT json_extract(value,'\$.id') FROM json_each(j) WHERE json_extract(value,'\$.label')='vpn' LIMIT 1)")
  [[ -n "$tagid" ]] || { log_fail "tags" "no 'vpn' tag in Prowlarr — run scripts/tag-vpn-indexers"; return 1; }

  assert_torrent_indexers_tagged "vpn" "$tagid" || return 1

  local tunnel_ip direct_ip
  tunnel_ip=$(fetch_container_external_ip gluetun) || { log_fail "tunnel exit IP" "unreachable"; return 1; }
  direct_ip=$(fetch_container_external_ip prowlarr) || { log_fail "direct exit IP" "unreachable"; return 1; }
  log_ok "tunnel exit IP" "$tunnel_ip"
  log_ok "direct exit IP" "$direct_ip"
  if [[ "$tunnel_ip" == "$direct_ip" ]]; then
    log_fail "isolation" "FAIL — tunnel and direct exit IPs match; the tunnel is not isolating"
    docker logs --tail 20 gluetun 2>&1 | sed 's/^/      /' >&2
    return 1
  fi

  if [[ "$(read_env_value .env QBITTORRENT_USE_VPN 2>/dev/null)" == "1" ]]; then
    local qbt_ip; qbt_ip=$(fetch_container_external_ip qbittorrent) || { log_fail "qbittorrent exit IP" "unreachable"; return 1; }
    [[ "$qbt_ip" == "$tunnel_ip" ]] || { log_fail "isolation" "qBT tunneled but its IP ($qbt_ip) differs from the tunnel ($tunnel_ip)"; return 1; }
    log_ok "isolation" "qBittorrent tunneled ($qbt_ip)"
  fi
  return 0
}

# fetch_prowlarr_tags — Prowlarr's tag list as JSON. Overridable in tests.
fetch_prowlarr_tags() {
  local key; key=$(fetch_prowlarr_api_key) || return 1
  curl -fsS --max-time 30 -H "X-Api-Key: $key" "http://127.0.0.1:9696/api/v1/tag"
}
```

- [ ] **Step 6: Run the full suite**

Run: `scripts/test`
Expected: `N passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/common scripts/tag-cf-indexers tests/verify_isolation.test
git commit -m "feat: assert per-indexer vpn tagging instead of comparing exit IPs"
```

## Task 7: Download-client host resolution over the bridge

**Files:**
- Modify: `setup:308-322`, `scripts/patch-prowlarr-db`, `scripts/patch-prowlarr-sab`
- Test: `tests/patch_prowlarr_db.test` (existing — extend)

- [ ] **Step 1: Extend the test**

Add to `tests/patch_prowlarr_db.test`:

```bash
test_qbt_host_is_container_dns_when_direct() {
  local root; root=$(_make_db)
  QBITTORRENT_USE_VPN=0 scripts/patch-prowlarr-db "$root"
  [[ "$(_qbt_host "$root")" == "qbittorrent" ]]
  rm -rf "$root"
}

test_qbt_host_is_gluetun_when_tunneled() {
  local root; root=$(_make_db)
  QBITTORRENT_USE_VPN=1 scripts/patch-prowlarr-db "$root"
  [[ "$(_qbt_host "$root")" == "gluetun" ]]
  rm -rf "$root"
}
```

Add the helper alongside the file's existing ones:

```bash
_qbt_host() {
  sqlite3 "$1/config/prowlarr/prowlarr.db" \
    "SELECT json_extract(Settings,'\$.host') FROM DownloadClients WHERE Implementation='QBittorrent' LIMIT 1;"
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep patch_prowlarr_db`
Expected: `FAIL` — the host is currently the LAN IP.

- [ ] **Step 3: Replace the LAN-IP logic**

In `setup`, delete the `qbt_host="127.0.0.1"`/LAN-IP branch and pass the mode
through instead. In `scripts/patch-prowlarr-db`, resolve the host as:

```bash
if [[ "${QBITTORRENT_USE_VPN:-0}" == "1" ]]; then
  qbt_host="gluetun"   # shares gluetun's namespace, so it has no DNS name of its own
else
  qbt_host="qbittorrent"
fi
```

and in `scripts/patch-prowlarr-sab`, set the SABnzbd host to `sabnzbd`
unconditionally — Prowlarr now sits on the same bridge.

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep -E "patch_prowlarr_(db|sab)"`
Expected: all `PASS`.

- [ ] **Step 5: Verify against the live install**

```bash
cp docker-compose.yml scripts/lib/common check ~/prowlarr-stack/
cp scripts/patch-prowlarr-db scripts/patch-prowlarr-sab ~/prowlarr-stack/scripts/
cd ~/prowlarr-stack
printf 'COMPOSE_PROFILES=\n' >> .env
./scripts/restart && ./check
```

Expected: `check` passes, reporting "no VPN configured — skipping tunnel checks"
and "usenet-only; no VPN needed".

- [ ] **Step 6: Confirm indexers actually work again**

```bash
K=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' ~/prowlarr-stack/config/prowlarr/config.xml | head -1)
curl -s -X POST -H "X-Api-Key: $K" "http://127.0.0.1:9696/api/v1/indexer/testall" | head -c 400
```

Expected: NZBgeek reports success. If it is still inside its 24h back-off,
clear it in the Prowlarr UI (Indexers → NZBgeek → Test) or wait for
`disabledTill` to lapse.

- [ ] **Step 7: Commit**

```bash
git add setup scripts/patch-prowlarr-db scripts/patch-prowlarr-sab tests/patch_prowlarr_db.test
git commit -m "feat: resolve download clients over the compose bridge"
```

---

## Task 7R: Download-client hosts over the bridge (RESTORED)

The original Task 7 bundled a code change with live-install verification steps.
The verification was superseded by the clean-install pass; **the code change was
not**, and dropping it left a live regression.

`setup:349-350` currently reads:

```bash
qbt_host="$lan_ip"
[[ "$qbt_use_vpn" == "1" ]] && qbt_host="127.0.0.1"
```

`127.0.0.1` was correct only while Prowlarr shared gluetun's network namespace
with a tunneled qBittorrent. Task 2 moved Prowlarr onto the bridge, so that
address now resolves to Prowlarr itself: a VPN user with `QBITTORRENT_USE_VPN=1`
gets a download client Prowlarr cannot reach. The `lan_ip` path still happens to
work (the published port is reachable from the bridge), so only the tunneled
case is broken — but it is broken now, by work already committed.

**Files:**
- Modify: `setup` (~349-351, ~439)
- Modify: `scripts/patch-prowlarr-db`, `scripts/patch-prowlarr-sab` (host validation)
- Modify: `scripts/lib/common` (new validator)
- Test: `tests/patch_prowlarr_db.test`, `tests/patch_prowlarr_sab.test`

- [ ] **Step 1: Write failing tests**

Both patchers currently `die "host must be a valid IPv4 address"` on anything
that is not an IPv4 address, so they reject container DNS names. Add to each
patcher's test file:

```bash
test_accepts_a_container_dns_host() {
  local d; d=$(mktemp -d); _seed_db "$d/prowlarr.db"
  printf '%s' "pw" | "$SCRIPT" "$d/prowlarr.db" qbittorrent 8080 -
  [[ "$(sqlite3 "$d/prowlarr.db" "SELECT json_extract(Settings,'\$.host') FROM DownloadClients LIMIT 1;")" == "qbittorrent" ]]
  rm -rf "$d"
}

test_still_accepts_an_ipv4_host() {
  local d; d=$(mktemp -d); _seed_db "$d/prowlarr.db"
  printf '%s' "pw" | "$SCRIPT" "$d/prowlarr.db" 192.168.1.10 8080 -
  [[ "$(sqlite3 "$d/prowlarr.db" "SELECT json_extract(Settings,'\$.host') FROM DownloadClients LIMIT 1;")" == "192.168.1.10" ]]
  rm -rf "$d"
}

test_rejects_a_host_that_is_neither() {
  local d; d=$(mktemp -d); _seed_db "$d/prowlarr.db"
  refute sh -c "printf pw | '$SCRIPT' '$d/prowlarr.db' 'not a host!' 8080 -"
  rm -rf "$d"
}
```

Use each file's existing seeding idiom rather than inventing `_seed_db` if one
already exists.

- [ ] **Step 2: Add a host validator to `scripts/lib/common`**

```bash
# validate_host <value>
# Accepts an IPv4 address or a DNS label (a compose service name such as
# `qbittorrent`, or a dotted hostname). Prowlarr reaches the download clients
# over the compose bridge now, so a bare service name is the normal case; an
# IPv4 address remains valid for a client reached over the LAN.
validate_host() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  validate_ipv4 "$host" 2>/dev/null && return 0
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]
}
```

- [ ] **Step 3: Use it in both patchers**

In `scripts/patch-prowlarr-db:38` and `scripts/patch-prowlarr-sab:35`, replace
the `validate_ipv4` guard with `validate_host`, and update the message to
`host must be an IPv4 address or a hostname (got: $host)`.

- [ ] **Step 4: Point setup at container DNS**

Replace `setup:349-350` with:

```bash
# Prowlarr is on the compose bridge, so it reaches the clients by service name.
# A tunneled qBittorrent shares gluetun's namespace and has no name of its own,
# so it is addressed as gluetun.
qbt_host="qbittorrent"
[[ "$qbt_use_vpn" == "1" ]] && qbt_host="gluetun"
```

and at `setup:439` pass `sabnzbd` instead of `$lan_ip`.

- [ ] **Step 5: Run the suite and commit**

```bash
git add setup scripts/patch-prowlarr-db scripts/patch-prowlarr-sab scripts/lib/common tests/
git commit -m "fix: address download clients by service name over the bridge"
```

---

# Phase 2 — The VPN path

## Task 8: Prove tag-scoped proxy routing with a stand-in proxy

Prowlarr's source says both search and grab call `ExecuteProxiedAsync`. This task
proves it empirically without needing a working tunnel, by substituting a logging
HTTP proxy for gluetun's.

**Files:** none modified — this is a verification task whose findings are recorded in the spec.

- [ ] **Step 1: Start a logging proxy on the compose bridge**

```bash
NET=$(docker inspect prowlarr -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
docker run -d --name probe-proxy --network "$NET" \
  -e LOG_LEVEL=Connect vimagick/tinyproxy
sleep 3 && docker logs probe-proxy | tail -3
```

- [ ] **Step 2: Create a `probe` tag and an Http proxy pointing at it**

```bash
K=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' ~/prowlarr-stack/config/prowlarr/config.xml | head -1)
TAG=$(curl -s -X POST -H "X-Api-Key: $K" -H 'Content-Type: application/json' \
  -d '{"label":"probe"}' http://127.0.0.1:9696/api/v1/tag | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
curl -s -X POST -H "X-Api-Key: $K" -H 'Content-Type: application/json' \
  -d "{\"name\":\"probe\",\"implementation\":\"Http\",\"configContract\":\"HttpSettings\",\"tags\":[$TAG],\"fields\":[{\"name\":\"host\",\"value\":\"probe-proxy\"},{\"name\":\"port\",\"value\":8888}]}" \
  http://127.0.0.1:9696/api/v1/indexerproxy | head -c 200
```

- [ ] **Step 3: Tag NZBgeek and run a search**

```bash
DEF=$(curl -s -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/indexer/15)
echo "$DEF" | python3 -c "import sys,json; d=json.load(sys.stdin); d['tags']=[$TAG]; print(json.dumps(d))" \
  | curl -s -X PUT -H "X-Api-Key: $K" -H 'Content-Type: application/json' -d @- \
    http://127.0.0.1:9696/api/v1/indexer/15 >/dev/null
curl -s -G -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/search \
  --data-urlencode "query=Sample Show" --data-urlencode "type=search" \
  --data-urlencode "categories=5000" >/dev/null
docker logs probe-proxy 2>&1 | grep -i "connect\|request" | tail -10
```

Expected: the proxy log shows a connection to NZBgeek's host — the **search** was proxied.

- [ ] **Step 4: Grab a result and confirm the grab is proxied too**

Extract the first result's `guid` and POST it back, then re-read the log:

```bash
BEFORE=$(docker logs probe-proxy 2>&1 | wc -l)
GUID=$(curl -s -G -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/search \
  --data-urlencode "query=Sample Show" --data-urlencode "type=search" \
  --data-urlencode "categories=5000" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[0]["guid"] if r else "")')
[ -n "$GUID" ] || echo "no results — widen the query before continuing"
curl -s -X POST -H "X-Api-Key: $K" -H 'Content-Type: application/json' \
  -d "{\"guid\":\"$GUID\",\"indexerId\":15}" http://127.0.0.1:9696/api/v1/search
AFTER=$(docker logs probe-proxy 2>&1 | wc -l)
echo "proxy log grew from $BEFORE to $AFTER lines"
docker logs probe-proxy 2>&1 | tail -5
```

Expected: new proxy log lines for the download host — the **grab** was proxied.
This is the behaviour the whole torrent path depends on.

- [ ] **Step 5: Tear the probe down completely**

```bash
curl -s -X DELETE -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/indexerproxy/$(
  curl -s -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/indexerproxy \
  | python3 -c "import sys,json;print([p['id'] for p in json.load(sys.stdin) if p['name']=='probe'][0])")
DEF=$(curl -s -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/indexer/15)
echo "$DEF" | python3 -c "import sys,json; d=json.load(sys.stdin); d['tags']=[]; print(json.dumps(d))" \
  | curl -s -X PUT -H "X-Api-Key: $K" -H 'Content-Type: application/json' -d @- \
    http://127.0.0.1:9696/api/v1/indexer/15 >/dev/null
curl -s -X DELETE -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/tag/$TAG
docker rm -f probe-proxy
```

- [ ] **Step 6: Record the result in the spec and commit**

Add the empirical confirmation to the spec's "Four verified facts" section, then:

```bash
git add docs/superpowers/specs/2026-09-17-per-indexer-egress-design.md
git commit -m "docs: empirically confirm tag-scoped proxying of search and grab"
```

## Task 9: Turn on gluetun's HTTP proxy

**Files:**
- Modify: `docker-compose.yml`
- Test: `tests/compose_profiles.test` (extend)

- [ ] **Step 1: Extend the test**

Assert the **resolved** compose configuration rather than the file's text —
`docker compose config` is the behaviour that matters, and a grep over source
would pass on a commented-out line.

```bash
test_gluetun_exposes_http_proxy() {
  local root; root=$(mktemp -d)
  cp docker-compose.yml docker-compose.qbt-vpn.yml "$root/"
  printf 'COMPOSE_PROFILES=vpn\nDOWNLOADS_DIR=/tmp/d\nCOMPLETED_DIR=/tmp/c\n' > "$root/.env"
  local env_json
  env_json=$( (cd "$root" && docker compose config --format json) \
    | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["services"]["gluetun"]["environment"]))')
  rm -rf "$root"
  [[ "$env_json" == *'"HTTPPROXY": "on"'* || "$env_json" == *'HTTPPROXY=on'* ]]
}

test_http_proxy_is_not_published_to_the_host() {
  # 8888 is bridge-only: reachable by sibling containers, never bound on the host.
  local root; root=$(mktemp -d)
  cp docker-compose.yml docker-compose.qbt-vpn.yml "$root/"
  printf 'COMPOSE_PROFILES=vpn\nDOWNLOADS_DIR=/tmp/d\nCOMPLETED_DIR=/tmp/c\n' > "$root/.env"
  local published
  published=$( (cd "$root" && docker compose config --format json) \
    | python3 -c 'import sys,json; s=json.load(sys.stdin)["services"]; print(" ".join(str(p.get("published","")) for v in s.values() for p in v.get("ports",[])))')
  rm -rf "$root"
  [[ "$published" != *8888* ]]
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep compose_profiles`
Expected: `FAIL ...::test_gluetun_exposes_http_proxy`.

- [ ] **Step 3: Apply the change**

Add to gluetun's `environment:`:

```yaml
      - HTTPPROXY=on
```

If Task 1 found bridge-inbound refused, also add:

```yaml
      - FIREWALL_INPUT_PORTS=8888
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep compose_profiles`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml tests/compose_profiles.test
git commit -m "feat: expose gluetun's tunnel as a bridge-local HTTP proxy"
```

## Task 10: Seed the `vpn` tag and `Http` proxy

**Files:**
- Modify: `scripts/patch-prowlarr-db`
- Test: `tests/patch_prowlarr_db.test` (extend)

- [ ] **Step 1: Extend the test**

```bash
test_seeds_vpn_tag_and_http_proxy_under_profile() {
  local root; root=$(_make_db)
  COMPOSE_PROFILES=vpn scripts/patch-prowlarr-db "$root"
  local db="$root/config/prowlarr/prowlarr.db"
  [[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM Tags WHERE Label='vpn';")" -eq 1 ]]
  [[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM IndexerProxies WHERE Implementation='Http';")" -eq 1 ]]
  rm -rf "$root"
}

test_does_not_seed_proxy_without_profile() {
  local root; root=$(_make_db)
  COMPOSE_PROFILES= scripts/patch-prowlarr-db "$root"
  [[ "$(sqlite3 "$root/config/prowlarr/prowlarr.db" "SELECT COUNT(*) FROM IndexerProxies WHERE Implementation='Http';")" -eq 0 ]]
  rm -rf "$root"
}

test_vpn_proxy_seeding_is_idempotent() {
  local root; root=$(_make_db)
  COMPOSE_PROFILES=vpn scripts/patch-prowlarr-db "$root"
  COMPOSE_PROFILES=vpn scripts/patch-prowlarr-db "$root"
  [[ "$(sqlite3 "$root/config/prowlarr/prowlarr.db" "SELECT COUNT(*) FROM IndexerProxies WHERE Implementation='Http';")" -eq 1 ]]
  rm -rf "$root"
}
```

`_make_db` must create the `Tags` and `IndexerProxies` tables. Extend it:

```bash
  sqlite3 "$db" 'CREATE TABLE IF NOT EXISTS Tags (Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL);'
  sqlite3 "$db" 'CREATE TABLE IF NOT EXISTS IndexerProxies (Id INTEGER PRIMARY KEY AUTOINCREMENT, Name TEXT NOT NULL, Implementation TEXT NOT NULL, Settings TEXT NOT NULL, ConfigContract TEXT NOT NULL, Tags TEXT NOT NULL DEFAULT '"'"'[]'"'"');'
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep patch_prowlarr_db`
Expected: `FAIL` on the three new functions.

- [ ] **Step 3: Implement the seeding**

Append to `scripts/patch-prowlarr-db`:

```bash
# Seed the vpn tag + Http indexer proxy, only when the vpn profile is active.
if [[ "${COMPOSE_PROFILES:-}" == *vpn* ]]; then
  sqlite3 "$db" "INSERT INTO Tags (Label) SELECT 'vpn' WHERE NOT EXISTS (SELECT 1 FROM Tags WHERE Label='vpn');"
  vpn_tag=$(sqlite3 "$db" "SELECT Id FROM Tags WHERE Label='vpn' ORDER BY Id LIMIT 1;")
  sqlite3 "$db" "
    INSERT INTO IndexerProxies (Name, Implementation, Settings, ConfigContract, Tags)
    SELECT 'VPN', 'Http', json_object('host','gluetun','port',8888), 'HttpSettings', json_array($vpn_tag)
    WHERE NOT EXISTS (SELECT 1 FROM IndexerProxies WHERE Implementation='Http');"
  sqlite3 "$db" "
    UPDATE IndexerProxies
       SET Settings = json_set(Settings,'\$.host','gluetun','\$.port',8888),
           Tags = json_array($vpn_tag)
     WHERE Implementation='Http';"
  log_ok "prowlarr" "vpn tag (id $vpn_tag) + Http proxy → gluetun:8888"
fi

# byparr's FlareSolverr proxy no longer shares Prowlarr's namespace.
sqlite3 "$db" "
  UPDATE IndexerProxies
     SET Settings = json_set(Settings,'\$.host','http://gluetun:8191/')
   WHERE Implementation='FlareSolverr';"
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep patch_prowlarr_db`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/patch-prowlarr-db tests/patch_prowlarr_db.test
git commit -m "feat: seed the vpn tag and Http indexer proxy"
```

## Task 11: `scripts/tag-vpn-indexers`

**Files:**
- Create: `scripts/tag-vpn-indexers`
- Modify: `setup` (invoke it after start)
- Test: `tests/tag_vpn_indexers.test`

- [ ] **Step 1: Write the failing test**

Create `tests/tag_vpn_indexers.test`:

```bash
#!/usr/bin/env bash
set -u
source scripts/lib/common

test_selects_only_enabled_torrent_indexers() {
  local json='[{"id":1,"name":"Usenet A","protocol":"usenet","enable":true,"tags":[]},
               {"id":2,"name":"Tracker B","protocol":"torrent","enable":true,"tags":[]},
               {"id":3,"name":"Tracker C","protocol":"torrent","enable":false,"tags":[]}]'
  local ids; ids=$(jexpr "$json" "(SELECT group_concat(json_extract(value,'\$.id'),' ')
    FROM json_each(j)
    WHERE json_extract(value,'\$.protocol')='torrent'
      AND json_extract(value,'\$.enable') IN (1,'true'))")
  [[ "$ids" == "2" ]]
}

test_script_is_executable() {
  [[ -x scripts/tag-vpn-indexers ]]
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep tag_vpn_indexers`
Expected: `FAIL ...::test_script_is_executable`.

- [ ] **Step 3: Write the script**

Create `scripts/tag-vpn-indexers`:

```bash
#!/usr/bin/env bash
# scripts/tag-vpn-indexers — tag every enabled torrent-protocol indexer with
# `vpn` so Prowlarr routes its searches AND grabs through the tunnel proxy.
#
# Protocol is not stored in prowlarr.db (Cardigann covers both), so this reads
# GET /api/v1/indexer. Idempotent; never removes tags; leaves usenet alone.
#
# Usage: tag-vpn-indexers [--dry-run] [--url URL]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common
source scripts/lib/common

DRY_RUN=0
URL="http://127.0.0.1:9696"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --url) URL="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

vpn_profile_active || { log_info "no VPN configured — nothing to tag"; exit 0; }

command -v sqlite3 >/dev/null || die "sqlite3 is required"
KEY=$(fetch_prowlarr_api_key) || die "could not read Prowlarr API key"
BASE="$URL/api/v1"
_get()  { curl -fsS --max-time 30 -H "X-Api-Key: $KEY" "$BASE$1"; }
_post() { curl -fsS --max-time 60 -X POST -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d "$2" "$BASE$1"; }
_put()  { curl -fsS --max-time 60 -X PUT  -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d "$2" "$BASE$1"; }

tagid=$(jexpr "$(_get /tag)" \
  "(SELECT json_extract(value,'\$.id') FROM json_each(j) WHERE json_extract(value,'\$.label')='vpn' LIMIT 1)")
if [[ -z "$tagid" ]]; then
  [[ $DRY_RUN -eq 1 ]] && { log_info "(dry-run) would create tag 'vpn'"; exit 0; }
  tagid=$(jexpr "$(_post /tag '{"label":"vpn"}')" "json_extract(j,'\$.id')")
  log_ok "tag" "created 'vpn' (id $tagid)"
fi

all=$(_get /indexer)
ids=$(jexpr "$all" "(SELECT group_concat(json_extract(value,'\$.id'),' ')
  FROM json_each(j)
  WHERE json_extract(value,'\$.protocol')='torrent'
    AND json_extract(value,'\$.enable') IN (1,'true'))")

n=0
for id in $ids; do
  def=$(_get "/indexer/$id")
  name=$(jexpr "$def" "json_extract(j,'\$.name')")
  has=$(jexpr "$def" "(SELECT COUNT(*) FROM json_each(json_extract(j,'\$.tags')) WHERE value=$tagid)")
  if [[ "$has" -ge 1 ]]; then
    log_info "$name: already tagged 'vpn'"
    continue
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would tag '$name' with 'vpn'"
    continue
  fi
  _put "/indexer/$id" "$(jexpr "$def" "json_insert(j,'\$.tags[#]',$tagid)")" >/dev/null
  log_ok "$name" "tagged 'vpn'"
  n=$((n + 1))
done

log_info "tagged $n indexer(s)"
```

Then `chmod +x scripts/tag-vpn-indexers`.

- [ ] **Step 4: Invoke it from `setup`**

After the `verify_isolation` call in `setup`, add:

```bash
if vpn_profile_active; then
  scripts/tag-vpn-indexers || log_warn "tagging" "could not tag torrent indexers — run scripts/tag-vpn-indexers"
fi
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test 2>&1 | grep tag_vpn_indexers`
Expected: two `PASS` lines.

- [ ] **Step 6: Commit**

```bash
git add scripts/tag-vpn-indexers setup tests/tag_vpn_indexers.test
git commit -m "feat: auto-tag torrent indexers for vpn routing"
```

## Task 12: Live tunnel integration (blocked — requires a working VPN)

**This task cannot be completed on the current machine.** The VPN subscription is
cancelled, so gluetun has no tunnel and no exit IP to compare. Everything else in
Phase 2 is verified by Task 8's substitution and the unit tests.

- [ ] **Step 1: With a working VPN, bring the stack up under the profile**

```bash
cd ~/prowlarr-stack
./setup --reconfigure     # supply VPN provider + WireGuard key
./check
```

Expected: `check` reports a tunnel exit IP differing from the direct exit IP, and
"every enabled torrent indexer carries the vpn tag".

- [ ] **Step 2: Confirm a torrent indexer reaches an ISP-blocked site**

Enable one previously-blocked torrent indexer in Prowlarr, then:

```bash
K=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' config/prowlarr/config.xml | head -1)
curl -s -X POST -H "X-Api-Key: $K" http://127.0.0.1:9696/api/v1/indexer/testall | head -c 400
```

Expected: the torrent indexer passes, proving the proxy carries traffic that the
ISP path cannot.

- [ ] **Step 3: Record the outcome in the spec and commit**

Replace the spec's "One unverified dependency" section with the confirmed
live-tunnel result, then:

```bash
git add docs/superpowers/specs/2026-09-17-per-indexer-egress-design.md
git commit -m "docs: confirm per-indexer egress against a live tunnel"
```

---

# Phase 3 — Migration and documentation

## Task 13: `migrations/0004-per-indexer-egress`

**Files:**
- Create: `migrations/0004-per-indexer-egress`
- Test: `tests/migration_0004.test`

- [ ] **Step 1: Write the failing test**

Create `tests/migration_0004.test`:

```bash
#!/usr/bin/env bash
set -u

MIGRATION="${MIGRATION:-migrations/0004-per-indexer-egress}"

_make_root() {  # $1 = "vpn" to seed VPN credentials
  local root; root=$(mktemp -d)
  mkdir -p "$root/config/prowlarr"
  local db="$root/config/prowlarr/prowlarr.db"
  sqlite3 "$db" 'CREATE TABLE Tags (Id INTEGER PRIMARY KEY AUTOINCREMENT, Label TEXT NOT NULL);'
  sqlite3 "$db" 'CREATE TABLE IndexerProxies (Id INTEGER PRIMARY KEY AUTOINCREMENT, Name TEXT NOT NULL, Implementation TEXT NOT NULL, Settings TEXT NOT NULL, ConfigContract TEXT NOT NULL, Tags TEXT NOT NULL DEFAULT '"'"'[]'"'"');'
  sqlite3 "$db" "INSERT INTO IndexerProxies (Name,Implementation,Settings,ConfigContract,Tags) VALUES ('FlareSolverr','FlareSolverr',json_object('host','http://localhost:8191/'),'FlareSolverrSettings','[]');"
  if [[ "${1:-}" == "vpn" ]]; then
    printf 'VPN_SERVICE_PROVIDER=nordvpn\n' > "$root/.env"
  else
    printf 'DOWNLOADS_DIR=/tmp/d\n' > "$root/.env"
  fi
  echo "$root"
}
_db() { echo "$1/config/prowlarr/prowlarr.db"; }

test_writes_compose_profiles_when_vpn_configured() {
  local root; root=$(_make_root vpn)
  "$MIGRATION" "$root"
  grep -q '^COMPOSE_PROFILES=vpn$' "$root/.env"
  rm -rf "$root"
}

test_leaves_profile_empty_without_vpn() {
  local root; root=$(_make_root)
  "$MIGRATION" "$root"
  ! grep -q '^COMPOSE_PROFILES=vpn$' "$root/.env"
  rm -rf "$root"
}

test_repoints_flaresolverr_host() {
  local root; root=$(_make_root vpn)
  "$MIGRATION" "$root"
  [[ "$(sqlite3 "$(_db "$root")" "SELECT json_extract(Settings,'\$.host') FROM IndexerProxies WHERE Implementation='FlareSolverr';")" == "http://gluetun:8191/" ]]
  rm -rf "$root"
}

test_is_idempotent() {
  local root; root=$(_make_root vpn)
  "$MIGRATION" "$root"
  "$MIGRATION" "$root"
  [[ "$(sqlite3 "$(_db "$root")" "SELECT COUNT(*) FROM IndexerProxies WHERE Implementation='Http';")" -eq 1 ]]
  [[ "$(sqlite3 "$(_db "$root")" "SELECT COUNT(*) FROM Tags WHERE Label='vpn';")" -eq 1 ]]
  rm -rf "$root"
}

test_no_op_without_db() {
  local root; root=$(mktemp -d); printf 'X=1\n' > "$root/.env"
  "$MIGRATION" "$root"
  rm -rf "$root"
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `scripts/test 2>&1 | grep migration_0004`
Expected: `FAIL` on all — the migration does not exist.

- [ ] **Step 3: Write the migration**

Create `migrations/0004-per-indexer-egress`:

```bash
#!/usr/bin/env bash
# 0004-per-indexer-egress — move an existing install from "Prowlarr lives inside
# gluetun's network namespace" to per-indexer egress.
#
# Writes COMPOSE_PROFILES=vpn when VPN credentials exist (so gluetun and byparr
# keep running), re-points the FlareSolverr proxy at gluetun:8191 now that
# Prowlarr no longer shares its namespace, and seeds the vpn tag + Http proxy.
# Indexer tagging is NOT done here — protocol is only available from the API, so
# setup runs scripts/tag-vpn-indexers after the stack is up.
#
# Idempotent; a no-op on already-correct state.
#
# Usage: 0004-per-indexer-egress <install_dir>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/common
source "$here/../scripts/lib/common"

root="${1:?usage: 0004-per-indexer-egress <install_dir>}"
db="$root/config/prowlarr/prowlarr.db"
env_file="$root/.env"

provider=$(read_env_value "$env_file" VPN_SERVICE_PROVIDER 2>/dev/null || true)
if [[ -n "$provider" ]]; then
  write_env_value "$env_file" COMPOSE_PROFILES "vpn"
  log_ok "0004" "COMPOSE_PROFILES=vpn (VPN credentials present)"
else
  write_env_value "$env_file" COMPOSE_PROFILES ""
  log_info "no VPN credentials — usenet-only stack"
fi

if [[ ! -f "$db" ]]; then
  log_info "no prowlarr.db — skipping database changes"
  exit 0
fi

sqlite3 "$db" "
  UPDATE IndexerProxies
     SET Settings = json_set(Settings,'\$.host','http://gluetun:8191/')
   WHERE Implementation='FlareSolverr'
     AND json_extract(Settings,'\$.host') LIKE '%localhost%';"

if [[ -n "$provider" ]]; then
  sqlite3 "$db" "INSERT INTO Tags (Label) SELECT 'vpn' WHERE NOT EXISTS (SELECT 1 FROM Tags WHERE Label='vpn');"
  vpn_tag=$(sqlite3 "$db" "SELECT Id FROM Tags WHERE Label='vpn' ORDER BY Id LIMIT 1;")
  sqlite3 "$db" "
    INSERT INTO IndexerProxies (Name, Implementation, Settings, ConfigContract, Tags)
    SELECT 'VPN','Http',json_object('host','gluetun','port',8888),'HttpSettings',json_array($vpn_tag)
    WHERE NOT EXISTS (SELECT 1 FROM IndexerProxies WHERE Implementation='Http');"
  log_ok "0004" "vpn tag (id $vpn_tag) + Http proxy seeded — tag indexers with scripts/tag-vpn-indexers"
fi
```

Then `chmod +x migrations/0004-per-indexer-egress`.

- [ ] **Step 4: Run the tests**

Run: `scripts/test 2>&1 | grep migration_0004`
Expected: five `PASS` lines.

- [ ] **Step 5: Run the whole suite**

Run: `scripts/test`
Expected: `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add migrations/0004-per-indexer-egress tests/migration_0004.test
git commit -m "feat: migrate existing installs to per-indexer egress"
```

## Task 14: Documentation

**Files:**
- Modify: `README.md:5`, `docs/architecture.md:5-33`, `docs/architecture.md:120-128`, `docs/indexers.md`, `CHANGELOG.md`

- [ ] **Step 1: Rewrite the README's positioning**

Replace line 5. The current text sends VPN-less users away:

> Indexer queries (and optionally torrent traffic) are routed through a WireGuard VPN tunnel — that's the point of this stack. If you don't want a VPN in the loop, [linuxserver/prowlarr](...) is a simpler one-container option.

with:

> Torrent indexer queries and grabs are routed through a WireGuard VPN tunnel — most torrent sites are ISP-blocked, and peers see your address. Usenet indexers run direct, because only your paid news-server ever sees your address. A VPN is optional: configure one to use torrent indexers, or leave it out for a usenet-only stack.

- [ ] **Step 2: Rewrite `docs/architecture.md` §Traffic routing**

Replace the two per-container topology tables with a single per-upstream table
matching the spec's "Routing model" section, and amend the **Kill-switch**
paragraph: Prowlarr no longer loses connectivity when the tunnel drops, but
`vpn`-tagged indexers do, because gluetun's proxy listens only inside the tunnel
namespace — connection-refused, never a fallthrough to the ISP.

- [ ] **Step 3: Update `docs/architecture.md` setup phases**

Phase 2 (line ~120) no longer lists the WireGuard key as required — mark VPN
configuration optional and note `COMPOSE_PROFILES`. Phase 5 (line ~123) no longer
describes LAN-IP host rewriting; it is container DNS now. Phase 10 (line ~128) is
the per-indexer tag assertion, not an exit-IP comparison.

- [ ] **Step 4: Add a section to `docs/indexers.md`**

Document that a torrent indexer added after install needs the `vpn` tag, that
`scripts/tag-vpn-indexers` applies it, and that `./check` fails the upgrade gate
if one is missing.

- [ ] **Step 5: Add the CHANGELOG entry**

```markdown
### Changed
- Egress is now a property of the indexer, not the stack. Prowlarr runs directly
  and torrent indexers reach the VPN through a tag-scoped indexer proxy, so a
  dropped or absent tunnel no longer blinds usenet search.
- A VPN is now optional. `./setup` accepts a blank provider for a usenet-only
  stack; gluetun and byparr sit behind the `vpn` compose profile.

### Fixed
- A lapsed VPN subscription no longer takes every indexer offline.
```

- [ ] **Step 6: Commit**

```bash
git add README.md docs/architecture.md docs/indexers.md CHANGELOG.md
git commit -m "docs: per-indexer egress and optional VPN"
```

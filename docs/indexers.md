# Indexer setup & optimization

Prowlarr is an aggregator: every search you run is fanned out, in parallel, to every indexer you've enabled. The whole search waits on the slowest one. **Adding more indexers does not always make searches better — it usually makes them slower.** This page covers how to add indexers, how to diagnose the slow or broken ones, and how to keep your search latency low.

## How a search actually behaves

```
Your client  ──►  Prowlarr  ──►  indexer A
                          ├───►  indexer B
                          ├───►  indexer C
                          └───►  indexer N

Returns when ALL of {A, B, ..., N} have responded or timed out.
```

Two consequences flow from that picture:

1. **Search latency ≈ slowest enabled indexer's response time.** A single bad indexer drags the whole result.
2. **Concurrent searches multiply HTTP traffic.** A "search whole season" action that fans out 10 episode queries against 6 indexers is 60 simultaneous outbound requests through a single VPN tunnel. Latency cascades quickly under load.

Keep this in mind whenever you're tempted to enable "one more indexer just in case."

## Adding an indexer

In Prowlarr (`http://localhost:9696`):

1. **Indexers** → **Add Indexer**.
2. Filter by type (Torrent / Usenet) or privacy (Public / Semi-Private / Private). Public indexers work without an account; private trackers need a username/passkey/API key.
3. Click an indexer. Fill in any required fields.
4. **Test** before saving. A failed test means it'll never work — don't save with the intent to "fix it later."
5. Save.

A working indexer turns up in **Indexers** with a green "Test" indicator and recent successful searches under **Indexer Stats**.

### Public indexers

These work straight away — paste the entry, test, save. No account, no VPN-required-for-login, just available. They're also the ones most likely to flap (see [When to disable an indexer](#when-to-disable-an-indexer)). Treat them as best-effort.

### Private trackers

Require an account on the tracker site, plus the credentials Prowlarr asks for (varies — usually a passkey or API key from your account profile). They're more reliable and often higher quality than public sources, but you have to be a member.

If you hit a "couldn't authenticate" error after a working test, the tracker probably rotated your passkey or session expired — re-test from your account page.

### Usenet providers

Need a paid provider for the actual NZB downloads, plus an indexer (also usually paid) for search. Prowlarr handles the indexer side; the download client (SABnzbd / NZBGet) handles the provider side. Faster and more reliable than torrents but not free.

### FlareSolverr-protected indexers

Some indexers sit behind Cloudflare's "checking your browser" challenge. Prowlarr can't pass that on its own. The stack runs **byparr** (a maintained, FlareSolverr-API-compatible solver) as a sidecar that drives a real browser and forwards the cleared request.

The stack pre-configures the Prowlarr side for you: a **FlareSolverr** indexer proxy (Settings → Indexers) pointed at `http://localhost:8191/`, carrying a tag named **`byparr`**.

**You must tag the indexers that need it.** Prowlarr applies an indexer proxy *only* to indexers that share a tag with it — an untagged proxy is used by nothing. So for each Cloudflare-protected indexer: open it in Prowlarr, add the **`byparr`** tag, save. Only tag the ones that actually need it — a tagged indexer routes *all* its searches through the (slower) browser solver, so don't tag indexers that work directly.

Or let the stack do it for you:

```sh
~/prowlarr-stack/scripts/tag-cf-indexers
```

It tests each enabled indexer and tags only the Cloudflare-blocked ones with `byparr` (creating the tag if needed), then re-tests. Idempotent and safe to re-run after adding new indexers; `--dry-run` shows what it would change.

If a Cloudflare-fronted indexer keeps failing after tagging, check `docker logs byparr` — you should see "Challenge detected, attempting to solve". Note that the solver egresses through gluetun's VPN IP, which Cloudflare treats as low-trust; the hardest sites can still time out regardless of solver, in which case the fix is a residential/mobile egress proxy (byparr `PROXY_SERVER`).

## Optimizing for speed

The single biggest lever is **fewer enabled indexers, all healthy**. Beyond a small set the marginal new indexer adds more tail latency than it does coverage.

A reasonable target on a VPN-tunnelled stack:

| Count | Behavior |
| ----- | -------- |
| 1–4   | Fast — search returns in single digits of seconds when all indexers are healthy. Limited coverage. |
| 5–8   | Sweet spot — broad coverage with searches typically returning in 5–20s. |
| 9–15  | Diminishing returns — coverage barely improves, latency is dominated by the slowest 2–3 indexers. |
| 15+   | Self-defeating. One flaky indexer in the set will drag every search past your client's timeout. |

If you're seeing search times consistently over 30s, **you have at least one slow or broken indexer enabled.** Don't bump the timeout — find it and disable it.

### Avoid stacking aggregators

A "meta-aggregator" indexer is one that itself queries multiple upstream sites and returns combined results. Enabling such an aggregator alongside the upstream sites it already covers is a slow duplicate: Prowlarr queries both the aggregator (15s+ as it fans out internally) and each upstream directly. Pick one or the other, not both.

### Concurrent searches

If you batch-search (a whole season, a whole movie collection), each query is independent and runs in parallel. With N enabled indexers and M concurrent searches the stack is making `N × M` simultaneous outbound requests through one VPN tunnel. Most providers throttle long before that becomes a problem.

If your client supports it, **cap concurrent searches at 2–3** rather than firing all of them at once. The total wall-clock time is similar but no individual query trips a timeout.

## When to disable an indexer

A healthy indexer:

- Returns in single digits of seconds for a typical query.
- Completes successfully more often than not (Prowlarr's **Indexer Stats** shows the success rate).
- Shows no recent entries in **System → Events** with `failed` or `timed out`.

Disable (or delete) an indexer if any of the following:

- Prowlarr's **Indexer Stats** shows it failing more often than succeeding.
- It appears in `/api/v1/indexerstatus` (i.e. Prowlarr has auto-disabled it temporarily after repeated failures) for two cooldowns in a row.
- Its log entries are dominated by `503 ServiceUnavailable`, `Http request timed out`, or `TaskCanceledException`.
- The site behind it has been intermittently dead for weeks and the Cardigann/YAML definition is just keeping the row alive.

Prowlarr's auto-disable mechanism is a *cooldown*, not a fix — it re-enables the indexer after ~24h, the indexer fails again, you wait 24h, repeat. Once an indexer falls into that loop it's wasting your time on every search until you disable it permanently.

## Diagnosing problems

### From the Prowlarr UI

- **Indexers → Indexer Stats** — per-indexer query count, success rate, average response time. The slow ones jump out immediately.
- **System → Events** — recent search/grab attempts. Look for `Failed` and `Cancelled`.
- **System → Logs** — full traces. Switch the level to *Debug* before reproducing if you need more detail.

### From the API

The control server doesn't need authentication on the loopback interface. Replace `<KEY>` with the API key from `config/prowlarr/config.xml` (`<ApiKey>…</ApiKey>`):

```sh
# List all configured indexers
curl -s -H "x-api-key: <KEY>" http://localhost:9696/api/v1/indexer \
  | jq -r '.[] | "\(.id)\t\(.enable)\t\(.name)"'

# List currently auto-disabled indexers (Prowlarr put them in cooldown)
curl -s -H "x-api-key: <KEY>" http://localhost:9696/api/v1/indexerstatus | jq

# Watch a slow search end-to-end
docker exec prowlarr sh -c \
  'ls -1t /config/logs/*.txt | head -1 | xargs tail -f' \
  | grep -E "(api/v1/search.*OK|failed|timed out|ServiceUnavailable)"
```

The third command is the most useful diagnostic — run it in one terminal, run a search in your client, and watch which indexer is the slow one.

### From gluetun

If indexer queries fail in clusters at the same timestamp, the VPN itself probably restarted:

```sh
docker logs gluetun | grep -E "healthcheck|stopping|starting|public IP"
```

Each VPN restart kills indexer traffic for ~10s. Indexers that were mid-query during a restart end up in Prowlarr's auto-disable list — you'll need to manually re-enable them once the VPN is stable, or wait for the cooldown.

A flapping VPN is most often caused by a distant exit (Asia/South America from a European host, etc.) — pick a closer endpoint and the healthcheck timeouts go away.

## A reasonable starter set

A practical opening lineup if you have no preference:

- 1–2 large public torrent indexers from Prowlarr's "Add Indexer" list, filtering for **Health: Healthy** at the time you set up. Avoid anything Prowlarr already lists as known-flaky.
- 1 meta-aggregator (only if you don't enable its upstreams separately).
- 1 FlareSolverr-protected indexer if you want broader coverage.
- Any private trackers you have accounts on — these are almost always more reliable than public.

Then run a few searches and look at **Indexer Stats** after a day. Disable anything with a success rate under ~80% or an average response time over 10s. Repeat once a month — the public-indexer landscape shifts.

## Testing without your own indexers

If you want to confirm the stack works end-to-end before signing up for anything, three sources publish openly-licensed content as torrents. None require an account or even a Prowlarr indexer entry — you can grab a `.torrent` from the website and drop it into qBittorrent directly.

- [Internet Archive](https://archive.org) — public-domain films, books, audio.
- [Academic Torrents](https://academictorrents.com) — research datasets.
- [Blender Open Movies](https://studio.blender.org/films/) — open-licensed short films.

Once one of those completes a download into your watch directory, the rest of the pipeline (Prowlarr → qBittorrent → completion → library) is proven working.

# Runbook: backfilling `ai:*` recording-rule history into the live TSDB

Task D.1 (Ryan-directed, 2026-08-24): the `ai:tokens:sum` / `ai:tool_calls:sum`
/ `ai:cost_usd:sum` / `ai:efficiency:*` recording rules only started
evaluating live once `otel-prometheus` picked up
`provisioning/prometheus/recording-rules.yml` — so the Spend Trend panels
have a hard "wall" at the deploy date instead of continuous history, even
though the RAW metrics they're built from (`claude_code_cost_usage_USD_total`
etc.) go back much further. `promtool tsdb create-blocks-from rules`
retroactively evaluates a rules file against historical data and produces
TSDB blocks you drop into the live data directory — this is what closes that
gap.

**This is live-TSDB surgery. Read the whole runbook before running anything
against the production data directory.** The block-*generation* step below
is 100% safe (it only reads via the Prometheus HTTP API and writes to a local
output directory — it cannot corrupt anything). The block-*move* step is
where care is required.

## What's already been validated (2026-08-24, this session)

- `promtool tsdb create-blocks-from rules --help` confirms the pinned
  Prometheus image (`prom/prometheus:latest`, currently 3.12.0 — same image
  family `otel-prometheus` runs) has the subcommand.
- `--url` accepts the Grafana datasource-proxy URL
  (`https://otel.rozich.com/api/datasources/proxy/uid/prometheus`) with
  `--http.config.file` supplying the `CF-Access-Client-Id`/
  `CF-Access-Client-Secret` headers via a `http_headers:` block — verified
  end-to-end: a real 6h test backfill produced real blocks with real data
  (`up` metric, 2 series, 4 samples).
- Data-availability probe (`count(claude_code_cost_usage_USD_total)` via
  `query_range`, stepping back from today): real samples exist continuously
  from **2026-04-08** onward; nothing found further back (checked to
  2026-04-01 with no hits, and explicitly confirmed empty 150-400 days ago).
  So `--start 2026-04-07T00:00:00Z` safely covers all available history with
  a one-day margin.
- A full backfill run (`--start 2026-04-07T00:00:00Z --end
  2026-08-24T20:00:00Z`, rules coarsened to `interval: 15m` for this
  historical pass only — see below) was run against the live API from this
  session and produced real blocks with real series/sample counts:
  **2,950 blocks, ~60 MB, generated over 19 minutes wall-clock** through the
  CF Access hop (the run was stopped manually at that point, not because it
  errored -- block generation for the full ~140-day range was still
  progressing steadily; running directly on the deploy host against local
  Prometheus, per the note below Step 1, should be substantially faster
  since it skips the proxy hop). Spot-checked block `meta.json` files show
  real, plausible series/sample counts across the April-August range (e.g.
  12-16 series, 12-40 samples per representative 1-1.5h block). This
  session's generated blocks were NOT moved into the live TSDB (Steps 2-3
  below were intentionally not run from this session -- no deploy-host
  access, and per Ryan's own instruction, that step is yours to schedule).
  **Do not reuse this session's generated block directory even if you can
  find it -- regenerate fresh with an `--end` appropriate to when you
  actually run Step 3**, since stale blocks generated hours/days earlier
  would leave a gap between their `--end` and whenever the live rules
  actually started recording. Note the run was stopped before reaching the
  full `--end` of 2026-08-24T20:00:00Z -- a genuinely complete run over the
  full ~140-day range will take longer than 19 minutes; budget accordingly
  or run it in the background.

## Step 1 — generate blocks (safe, do this from anywhere with API access)

```bash
mkdir -p /tmp/otl-backfill && cd /tmp/otl-backfill

cat > http-config.yaml <<'EOF'
http_headers:
  CF-Access-Client-Id:
    values: ["$CF_ACCESS_CLIENT_ID"]
  CF-Access-Client-Secret:
    values: ["$CF_ACCESS_CLIENT_SECRET"]
EOF

# Coarsen interval for the HISTORICAL pass only -- 1m resolution over ~140
# days is unnecessary query load for a trend panel and risks large/slow
# API responses through the CF Access proxy. The LIVE rules file (deployed,
# evaluating going forward) keeps its real interval: 1m -- this coarsening
# is local to the backfill-only copy.
cp /path/to/repo/provisioning/prometheus/recording-rules.yml backfill-rules.yml
sed -i '' 's/interval: 1m/interval: 15m/' backfill-rules.yml   # macOS sed; drop '' on Linux

docker run --rm \
  -v "$PWD:/work" \
  --entrypoint promtool prom/prometheus:latest \
  tsdb create-blocks-from rules \
  --url https://otel.rozich.com/api/datasources/proxy/uid/prometheus \
  --http.config.file /work/http-config.yaml \
  --start "2026-04-07T00:00:00Z" \
  --end   "<NOW minus a safety margin -- see Step 1a>" \
  --output-dir /work/out \
  /work/backfill-rules.yml
```

**If running directly ON the deploy host** against the local Prometheus
(recommended — avoids the CF Access hop and is faster), swap `--url` for
`http://localhost:9090` (or whatever the box's internal Prometheus address
is) and drop `--http.config.file` entirely.

### Step 1a — pick `--end` correctly (avoid double-counting)

`--end` MUST be a timestamp **before** `otel-prometheus`'s current process
start time (check `curl .../api/v1/status/runtimeinfo` → `startTime`, or
just use "when the `ai:*` rules were actually deployed and began evaluating
live" if you know it) — otherwise the backfilled blocks and the live head
block will both claim samples in the same window, which is exactly the
overlap the promtool docs warn against.

⚠️ Superseded in part by Step 5a: do NOT pick a comfortable buffer. A margin
is what creates a boundary dip. Pin the live rule's true first sample
empirically and stop ~30 seconds short of it.

### Step 1b — validate the generated blocks BEFORE touching the server

```bash
for b in out/*/; do
  docker run --rm -v "$PWD:/work" --entrypoint promtool prom/prometheus:latest \
    tsdb list --human-readable /work/"$(basename "$b")" 2>&1 || true
done
# or simpler: eyeball a few meta.json files for sane minTime/maxTime/numSamples
cat out/<ulid>/meta.json | python3 -m json.tool
```

Confirm block time ranges are contiguous, non-overlapping, and end before
your chosen `--end`. Confirm `numSamples`/`numSeries` are nonzero and
plausible (not suspiciously tiny for the whole window, which would mean the
rules file or `--url` was wrong).

## Step 2 — back up the live TSDB before moving anything in

```bash
# on the deploy host, wherever otel-prometheus's data volume is mounted
docker compose stop otel-prometheus   # stop writes cleanly first
tar czf /backups/otel-prometheus-tsdb-$(date +%Y%m%d-%H%M).tar.gz \
  -C /var/lib/docker/volumes/<otel-prometheus-data-volume>/_data .
# (or whatever the actual bind-mount/named-volume path is -- check
# `docker volume inspect` if unsure. docker-compose.yml uses
# ${OTEL_PROMETHEUS_DATA:-otel-prometheus-data} as a named volume by
# default.)
```

Verify the tarball is non-empty and roughly the expected size before
proceeding. Do not skip this step for a "quick" backfill — the whole point
of a backup is that it costs nothing when unneeded and saves everything when
it turns out to be needed.

## Step 3 — move blocks in, restart

With `otel-prometheus` still stopped (from Step 2):

```bash
cp -r /tmp/otl-backfill/out/*/ /var/lib/docker/volumes/<otel-prometheus-data-volume>/_data/
docker compose up -d otel-prometheus   # NOT `restart` -- see the compose-mount
                                        # gotcha in otel-stack-ops/SKILL.md if this
                                        # backfill ever needs a docker-compose.yml
                                        # change too (it doesn't, today)
```

Do this as ONE uninterrupted sequence (stop → backup already done in Step 2
→ copy → start) so the compactor never runs against a half-copied set of
blocks. Prometheus discovers new block directories on startup by scanning
its data directory — no separate "reload" step needed beyond the restart.

## Step 4 — verify

```bash
# via the Grafana proxy, or curl localhost:9090 directly on the host
curl -sG '.../api/v1/query_range' \
  --data-urlencode 'query=sum(max_over_time(ai:cost_usd:sum{provider="anthropic"}[1d]))' \
  --data-urlencode 'start=2026-04-08T00:00:00Z' \
  --data-urlencode 'end=2026-08-24T00:00:00Z' \
  --data-urlencode 'step=86400' | jq '.data.result[0].values | length'
```

Confirm nonzero values across the pre-today range, not just today. Then open
`dashboards/ai-usage.json`'s Spend Trend panels in Grafana and confirm the
line now extends back to April instead of starting flat-zero before the
deploy date.

**Record exactly how far back each series now reaches** (this differs by
metric — `ai:cost_usd:sum`/`ai:tokens:sum`/`ai:tool_calls:sum` should all
reach ~2026-04-08; `ai:efficiency:*` will only reach as far back as
`ai_subscription_limit_used_percent` has samples, which is bounded by
Loki's 168h out-of-order window per
`scripts/codex-limit-history-replay.sh` — see that script's header comment).

## Step 5 — re-backfilling a window that ALREADY has (bad) samples

Steps 1-4 cover the easy case: an empty stretch of history, where new
blocks simply fill a hole. OTL-88 (2026-08-26) hit the harder case —
2026-08-25 13:31-20:36 UTC already held samples, written live by the v1
max-latch accumulator that OTL-87/PR #182 replaced. Three extra rules
apply, all learned the hard way.

### 5a — pin BOTH seams empirically; never pick a safety margin

The OTL-85 seam lesson generalizes: a conservative buffer around the
boundary is what CREATES a boundary dip, because whatever the rule was
tracking can expire inside the buffer. Binary-scan the real sample
timestamps instead. `max(timestamp(<series>))` stepped at 10s resolves a
rule's true birth to the second — note that `timestamp(sum(x))` does NOT
work (the aggregation restamps to eval time); it must be
`max(timestamp(x))`.

```bash
# first sample of whichever rule bounds your window
curl -sG .../api/v1/query_range \
  --data-urlencode 'query=max(timestamp(ai:tokens_accum_delta:sum))' \
  --data-urlencode 'start=...' --data-urlencode 'end=...' \
  --data-urlencode 'step=10'
```

A rule shipped by the SAME PR as the fix is the cleanest birth marker for
that deploy — OTL-88 used `ai:tokens_accum_delta:sum` (new in #182) to pin
the #182 deploy at 1787690172.295 = 2026-08-25T20:36:12.295Z, and the
`--end` was set so the last backfilled sample landed 9.6 seconds before
it. The prose date in a PR description is not evidence; #182's own
description was a full day off, and #187's correction was still three
minutes off the true first sample.

### 5b — promtool cannot chain a self-reference; accumulate in two passes

OTL-85 recorded that `create-blocks-from rules` queries the LIVE server
for a rule's self-reference branch, so a self-latching accumulator
backfills as its raw branch only. That is fine when the raw branch is the
whole story, but it will NOT reconstruct a running total — and dropping a
non-accumulating raw-branch segment into the middle of an accumulator
produces a step at its right-hand seam, which the "per Interval" panels
render as a fresh phantom spike. Accumulate in two passes instead:

1. **Pass A** — backfill only the DELTA rules
   (`ai:tokens_accum_delta:sum` / `ai:cost_usd_accum_delta:sum`), byte-for-byte
   as shipped. They are pure functions of the raw counters with no
   self-reference, so promtool evaluates them retroactively without
   complaint. Move those blocks into the live TSDB (they are new history
   for a series that has no samples that far back, so nothing overlaps).
2. **Pass B** — backfill the accumulator as
   `anchor + sum_over_time(<delta series>[W])`, where the anchor is the
   last pre-flaw sample pinned with `@` (e.g.
   `last_over_time(ai:tokens_accum:sum[5m] @ 1787664560)`) and `W` is any
   window WIDER than the whole flawed window. Pass A samples exist only
   inside the window, so the sum self-clips to (window start, t] — no
   growing-window trick needed. Give each `or` branch a `+ 0` so the
   metric name is dropped on every branch, otherwise the branches never
   match and the rule errors on a duplicate labelset.

Do not try to do this in one pass with a subquery
(`sum_over_time((<delta expr>)[W:1m])`). It is correct, but it re-evaluates
the inner expression at every inner step for every outer step — hundreds of
thousands of range evaluations against the live server.

### 5c — delete the bad samples BEFORE inserting, via a temp admin container

Overlapping blocks with duplicate timestamps resolve non-deterministically;
the old samples must actually go. `otel-prometheus` does not run with
`--web.enable-admin-api` and should not be changed to. Stop it and run a
throwaway container over the same data directory instead:

```bash
docker compose stop otel-prometheus
docker run -d --name tmp-admin-prom --network host \
  -v /data/otel-stack-data/prometheus:/prometheus \
  -v /path/to/minimal-config:/etc/prometheus:ro \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=2y \
  --web.enable-admin-api \
  --web.listen-address=:9401
curl -X POST 'http://localhost:9401/api/v1/admin/tsdb/delete_series?match%5B%5D=<series>&start=...&end=...'
curl -X POST 'http://localhost:9401/api/v1/admin/tsdb/clean_tombstones'
```

⚠️ **`--storage.tsdb.retention.time=2y` is not optional.** The default is
15 days. A temp container started without it will silently delete every
block older than that — i.e. the entire backfilled history you are here to
protect.

⚠️ Pick the listen port by checking `ss -ltn` first. `:9090` on this host is
a stray Home Assistant Prometheus (the real one is `:9098`), and `:9401` was
chosen for OTL-88 only after `:9099` turned out to be taken — a readiness
probe against an occupied port cheerfully returns another service's 404.

Order matters: delete → `clean_tombstones` → copy Pass B blocks in → start
`otel-prometheus`. Copying first means the delete eats your own new samples.

### 5d — what this can and cannot fix

A reconstruction only repairs the window itself. Everything AFTER the
window was computed by the live accumulator from whatever (too-low) base
the broken rule left behind, so a faithful reconstruction ends higher than
the live series resumes and there is a one-sample cliff at the seam. That
is expected and benign here: every "per Interval" panel wraps its
subtraction in `clamp_min(..., 0)`, so the cliff renders as a single
understated bucket rather than a negative or a spike. Re-basing the whole
post-window series to remove the cliff would mean rewriting all history
since — do not do it without a Ryan-level decision. Say plainly in the
report which direction the seam steps and by how much.

## If this looks riskier than the value once you're actually doing it

Stop and report the assessment instead of proceeding — partial history is
not worth a corrupted TSDB. The block-generation step (Step 1) is safe to
run and re-run as many times as useful for evaluating the idea even if you
decide not to do Steps 2-3.

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
overlap the promtool docs warn against. Use a comfortable buffer (20+
minutes) before that boundary, not the exact instant.

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

## If this looks riskier than the value once you're actually doing it

Stop and report the assessment instead of proceeding — partial history is
not worth a corrupted TSDB. The block-generation step (Step 1) is safe to
run and re-run as many times as useful for evaluating the idea even if you
decide not to do Steps 2-3.

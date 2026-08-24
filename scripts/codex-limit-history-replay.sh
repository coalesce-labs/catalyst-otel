#!/usr/bin/env bash
# codex-limit-history-replay.sh — Task D.2 (Ryan-directed, 2026-08-24): one-shot
# replay of Codex's HISTORICAL rate_limits snapshots (already sitting in this
# laptop's rollout JSONLs) into Loki with their ORIGINAL timestamps, so the
# Spend Trend / Subscription Efficiency panels have pre-today history instead
# of starting cold at whenever ai-subscription-limit-scraper.sh's cron began.
#
# Unlike the live scraper (ai-subscription-limit-scraper.sh), this reads
# EVERY historical token_count event across ALL rollout JSONLs (not just the
# newest snapshot) and emits one OTLP log per sample, timestamped with that
# sample's REAL `timestamp` field from the rollout JSONL -- not "now".
#
# ⚠️ TWO Loki limits shape this, both measured empirically 2026-08-24, not
# assumed:
#
# 1. Global out-of-order age: samples ~168h/7 days old land; samples exactly
#    7 days old are rejected. Measured via a controlled probe (ascending
#    per-stream timestamp order, separate requests, waited past ingester
#    flush lag before checking -- an unordered/batched probe or an
#    under-waited check gives FALSE negatives, which is what an earlier,
#    less careful pass of this same probe produced). Matches Loki's
#    documented default `limits_config.reject_old_samples_max_age: 168h`,
#    which this deploy has never overridden. Consequence: **only the last
#    7 days of Codex rollout history can EVER be replayed this way** -- this
#    laptop's rollout JSONLs go back to 2025-09-16, but everything older
#    than 168h is structurally unreplayable through this ingestion path.
#
# 2. Per-STREAM high-water-mark (the one that actually bit this script on
#    first use): Loki's out-of-order tolerance is relative to the target
#    STREAM's own highest-ingested timestamp, not wall-clock "now" in
#    isolation. ai-subscription-limit-scraper.sh (the LIVE scraper) had
#    already written today's samples into the `service_name=
#    "ai-subscription-limit-scraper"` stream by the time this replay first
#    ran -- so replaying Aug-21-through-Aug-24-morning history into that
#    SAME stream got silently rejected (only the two newest samples, both
#    within an hour of the live stream's high-water-mark, survived; verified
#    by querying Loki afterward, not assumed from the 200 OK responses --
#    the OTLP HTTP receiver returns 200 even for entries Loki itself later
#    drops). Fix: this script writes to its OWN service_name
#    ("ai-subscription-limit-scraper-backfill", a stream the live scraper has
#    never touched, so it has no competing high-water-mark). This is safe to
#    mix with the live stream downstream because the collector's
#    `ai_subscription_limit_used_percent` gauge rule
#    (collector-config.yaml) keys on the `event_name` log attribute, not on
#    service_name -- both streams feed the same Prometheus series. Anyone
#    re-running this replay after the FIRST run should re-verify samples
#    actually landed (query Loki, don't trust the 200) -- the history
#    stream now has its own progressing high-water-mark too, and a second
#    replay covering an overlapping window will hit the same rejection this
#    comment describes.
#
# Claude has NO equivalent historical source at all (documented, not
# discovered here for the first time by this script): the 5h/7d used_percent
# `catalyst-stack claude-account status` / claude-accounts-usage.mjs reads is
# a live OAuth snapshot of CURRENT usage only -- there is no historical log
# of past used_percent values anywhere in this fleet's tooling. This is
# stated on the "Subscription Efficiency" caveat panel in
# dashboards/ai-usage.json (see the diff in the same commit as this script)
# so nobody goes looking for it.
#
# Usage: codex-limit-history-replay.sh [--dry-run] [--since-hours=N]
#   --dry-run          count + print what WOULD be sent, POST nothing.
#   --since-hours=N    override the lookback window (default 167, one hour
#                       inside Loki's 168h cutoff as a safety margin).
set -euo pipefail

DRY_RUN=0
SINCE_HOURS=167
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --since-hours=*) SINCE_HOURS="${arg#*=}" ;;
  esac
done

OTLP_HTTP_ENDPOINT="${OTLP_HTTP_ENDPOINT:-http://100.65.193.30:4318}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

CUTOFF_EPOCH=$(python3 -c "import time; print(time.time() - ${SINCE_HOURS}*3600)")

echo "codex-limit-history-replay: scanning $CODEX_HOME/sessions for rollout JSONLs modified in the last ${SINCE_HOURS}h (Loki's OOO cutoff is 168h; using ${SINCE_HOURS}h for a safety margin)..." >&2

# find files touched in the lookback window -- coarse pre-filter, exact
# per-sample filtering happens in the python pass below on each sample's
# real `timestamp` field, not the file's mtime.
mapfile -t FILES < <(find "$CODEX_HOME/sessions" -name "*.jsonl" -mmin "-$(( SINCE_HOURS * 60 + 60 ))" 2>/dev/null)

echo "codex-limit-history-replay: ${#FILES[@]} candidate rollout file(s)" >&2

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "codex-limit-history-replay: nothing to replay" >&2
  exit 0
fi

AUTH_FILE="$CODEX_HOME/auth.json"

CUTOFF_EPOCH="$CUTOFF_EPOCH" AUTH_FILE="$AUTH_FILE" DRY_RUN="$DRY_RUN" OTLP_HTTP_ENDPOINT="$OTLP_HTTP_ENDPOINT" \
python3 - "${FILES[@]}" <<'PYEOF'
import json, os, sys, time, subprocess
from datetime import datetime, timezone

files = sys.argv[1:]
cutoff = float(os.environ["CUTOFF_EPOCH"])
dry_run = os.environ["DRY_RUN"] == "1"
endpoint = os.environ["OTLP_HTTP_ENDPOINT"].rstrip("/") + "/v1/logs"

auth = json.load(open(os.environ["AUTH_FILE"]))
account_id = (auth.get("tokens") or {}).get("account_id", "unknown")
account = f"codex-{account_id[:8]}"

def window_label(minutes):
    if minutes == 10080:
        return "7d"
    if minutes == 300:
        return "5h"
    if minutes:
        return f"{minutes}m"
    return "unknown"

# Collect every (epoch_seconds, window, used_percent, window_minutes, resets_at)
# sample across all candidate files, filtered to the OOO-safe lookback.
samples = []
for path in files:
    try:
        with open(path) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "event_msg":
                    continue
                payload = d.get("payload", {})
                if payload.get("type") != "token_count":
                    continue
                ts_str = d.get("timestamp")
                if not ts_str:
                    continue
                try:
                    ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
                except Exception:
                    continue
                if ts < cutoff:
                    continue
                rl = payload.get("rate_limits") or {}
                for key in ("primary", "secondary"):
                    w = rl.get(key)
                    if not w or w.get("used_percent") is None:
                        continue
                    samples.append({
                        "ts": ts,
                        "window": window_label(w.get("window_minutes")),
                        "used_percent": w["used_percent"],
                        "window_minutes": w.get("window_minutes"),
                        "resets_at": w.get("resets_at"),
                    })
    except Exception as e:
        print(f"codex-limit-history-replay: skipping unreadable {path}: {e}", file=sys.stderr)

print(f"codex-limit-history-replay: {len(samples)} raw samples in window", file=sys.stderr)

# Downsample: Loki requires per-stream monotonically non-decreasing
# timestamps (verified empirically 2026-08-24 -- an unordered batch to the
# same stream silently drops the out-of-order entries), and thousands of
# near-identical points add nothing a "Spend Trend" panel needs. Keep the
# LAST sample per (window, hour-bucket) -- coarse enough to be fast and
# well within Loki's ordering requirement once sorted, fine enough for any
# trend panel.
by_bucket = {}
for s in samples:
    hour_bucket = int(s["ts"] // 3600)
    key = (s["window"], hour_bucket)
    prev = by_bucket.get(key)
    if prev is None or s["ts"] > prev["ts"]:
        by_bucket[key] = s

downsampled = sorted(by_bucket.values(), key=lambda s: s["ts"])
print(f"codex-limit-history-replay: {len(downsampled)} samples after hourly downsample", file=sys.stderr)

if not downsampled:
    sys.exit(0)

if dry_run:
    for s in downsampled:
        t = datetime.fromtimestamp(s["ts"], tz=timezone.utc).isoformat()
        print(f"  DRY-RUN would send: {t}  window={s['window']}  used_percent={s['used_percent']}")
    sys.exit(0)

def attr(k, v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return {"key": k, "value": {"doubleValue": float(v)}}
    return {"key": k, "value": {"stringValue": str(v)}}

sent = 0
failed = 0
for i, s in enumerate(downsampled):
    if i > 0:
        # The collector's batch/loki processor (5s timeout, see
        # collector-config.yaml) can coalesce several rapid-fire requests
        # into one export -- verified empirically 2026-08-24 that sending
        # all 82 replay samples back-to-back with no pacing silently
        # scrambled/dropped all but the last few, even on a brand-new
        # stream with no competing high-water-mark. A short pace keeps each
        # request in its own batch window so Loki sees them (and thus its
        # own per-stream ordering check) in the order they were generated.
        time.sleep(0.4)
    ts_ns = int(s["ts"] * 1e9)
    attrs = [
        attr("event_name", "ai.subscription_limit.sampled"),
        attr("provider", "openai"),
        attr("account", account),
        attr("window", s["window"]),
        attr("used_percent", s["used_percent"]),
        attr("history_replay", "true"),
    ]
    if s.get("window_minutes") is not None:
        attrs.append(attr("window_minutes", s["window_minutes"]))
    if s.get("resets_at") is not None:
        attrs.append(attr("resets_at", s["resets_at"]))
    payload = {
        "resourceLogs": [{
            "resource": {"attributes": [
                # Deliberately a DIFFERENT service.name than the live scraper --
                # see the "per-STREAM high-water-mark" note above. The
                # collector's gauge rule keys on event_name, not service_name,
                # so this still feeds the same Prometheus series.
                {"key": "service.name", "value": {"stringValue": "ai-subscription-limit-scraper-backfill"}},
                {"key": "host.name", "value": {"stringValue": "laptop"}},
            ]},
            "scopeLogs": [{
                "scope": {"name": "ai_subscription_limit_scraper"},
                "logRecords": [{
                    "timeUnixNano": str(ts_ns),
                    "observedTimeUnixNano": str(int(time.time() * 1e9)),
                    "severityNumber": 9,
                    "severityText": "INFO",
                    "body": {"stringValue": "ai.subscription_limit.sampled"},
                    "attributes": attrs,
                }],
            }],
        }],
    }
    body = json.dumps(payload)
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
         "-H", "Content-Type: application/json", "-d", body, "--max-time", "10", endpoint],
        capture_output=True, text=True,
    )
    code = r.stdout.strip()
    if code == "200":
        sent += 1
    else:
        failed += 1
        print(f"codex-limit-history-replay: POST failed HTTP {code} for {datetime.fromtimestamp(s['ts'], tz=timezone.utc).isoformat()}", file=sys.stderr)

print(f"codex-limit-history-replay: sent {sent}, failed {failed} (of {len(downsampled)})", file=sys.stderr)
PYEOF

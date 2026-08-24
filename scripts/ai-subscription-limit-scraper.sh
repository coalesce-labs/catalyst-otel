#!/usr/bin/env bash
# ai-subscription-limit-scraper.sh — Task C (Ryan-directed, 2026-08-24): the
# "denominator" telemetry for subscription efficiency (retail-$ of work per %
# of subscription limit consumed). Neither Claude Code nor Codex exports this
# as OTLP on its own -- this script is the missing scraper, reading each
# provider's own local usage snapshot and emitting one OTLP log event per
# (provider, account, window). A collector `signal_to_metrics` rule (see
# collector-config.yaml, ai_subscription_limit_used_percent) turns that into
# a Prometheus gauge.
#
# Zero API calls of its own for Codex (parses the rollout JSONL Codex already
# wrote). For Claude, shells out to the fleet's own
# plugins/dev/scripts/claude-accounts-usage.mjs --json (the same OAuth-usage
# probe `catalyst-stack claude-account status` already uses) -- no new
# credential, no new API surface.
#
# Run on a cron/launchd schedule (every 5-15min is plenty -- both sources
# update at most once per API call, and the subscription windows are hours/
# days wide). Safe to run from any laptop context that already has Claude
# Code + Codex configured -- reads only local files + the existing fleet
# tooling, never any credential this script doesn't already have on disk.
#
# Usage: ai-subscription-limit-scraper.sh [--dry-run]
#   --dry-run   print the OTLP payload instead of POSTing it.
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Same transport every laptop Claude Code / Codex session already uses (see
# ~/.claude/settings.json's env block / CLAUDE_OBSERVABILITY.md) -- the
# collector's Tailscale address, OTLP/HTTP (simpler to construct from bash
# than gRPC; the collector's otlp receiver accepts both protocols on the
# same host, gRPC on :4317 / HTTP on :4318).
OTLP_HTTP_ENDPOINT="${OTLP_HTTP_ENDPOINT:-http://100.65.193.30:4318}"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_ACCOUNTS_USAGE_MJS="${CLAUDE_ACCOUNTS_USAGE_MJS:-$HOME/catalyst/plugin-source/plugins/dev/scripts/claude-accounts-usage.mjs}"

# ---------------------------------------------------------------------------
# Gather: Codex (this laptop's single ChatGPT-subscription account)
# ---------------------------------------------------------------------------
codex_json="[]"
latest=$(ls -t "$CODEX_HOME"/sessions/*/*/*/*.jsonl 2>/dev/null | head -1) || true
if [[ -n "${latest:-}" ]]; then
  snap=$(grep -ho '"rate_limits":{.*' "$latest" | tail -1) || true
  if [[ -n "${snap:-}" ]]; then
    auth_file="$CODEX_HOME/auth.json"
    codex_json=$(SNAP="$snap" AUTH="$auth_file" python3 <<'PY'
import json, os, sys
raw = os.environ["SNAP"]
frag = raw[raw.index('{'):]
depth = 0
for i, c in enumerate(frag):
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            frag = frag[:i + 1]
            break
d = json.loads(frag)
auth = json.load(open(os.environ["AUTH"]))
account_id = (auth.get("tokens") or {}).get("account_id", "unknown")
account = f"codex-{account_id[:8]}"

out = []
for window_key, window_label in (("primary", None), ("secondary", None)):
    w = d.get(window_key)
    if not w:
        continue
    minutes = w.get("window_minutes")
    # Codex's own window label is derived from window_minutes (10080 = 7 days,
    # 300 = 5 hours) -- mirror the Claude side's "5h"/"7d" spelling so the two
    # providers' `window` label values line up in the dashboard.
    if minutes == 10080:
        label = "7d"
    elif minutes == 300:
        label = "5h"
    elif minutes:
        label = f"{minutes}m"
    else:
        label = window_key
    out.append({
        "provider": "openai",
        "account": account,
        "window": label,
        "used_percent": w.get("used_percent"),
        "window_minutes": minutes,
        "resets_at": w.get("resets_at"),
    })
print(json.dumps(out))
PY
)
  fi
fi

# ---------------------------------------------------------------------------
# Gather: Claude (the whole fleet's account rotation -- acct1..N)
# ---------------------------------------------------------------------------
claude_json="[]"
if [[ -f "$CLAUDE_ACCOUNTS_USAGE_MJS" ]]; then
  claude_json=$(node "$CLAUDE_ACCOUNTS_USAGE_MJS" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = []
for a in d.get("accounts", []):
    if a.get("error"):
        continue
    label = a.get("label", "unknown")
    for window_key, window_label, minutes in (("fiveHour", "5h", 300), ("sevenDay", "7d", 10080)):
        w = a.get(window_key)
        if not w or w.get("pct") is None:
            continue
        resets_at = None
        if w.get("resetsAt"):
            from datetime import datetime, timezone
            resets_at = datetime.fromisoformat(w["resetsAt"].replace("Z", "+00:00")).timestamp()
        out.append({
            "provider": "anthropic",
            "account": label,
            "window": window_label,
            "used_percent": w.get("pct"),
            "window_minutes": minutes,
            "resets_at": resets_at,
        })
print(json.dumps(out))
' 2>/dev/null) || claude_json="[]"
fi

# ---------------------------------------------------------------------------
# Build + send the OTLP/HTTP logs payload (one logRecord per provider/
# account/window sample).
# ---------------------------------------------------------------------------
CODEX_JSON="$codex_json" CLAUDE_JSON="$claude_json" OTLP_HTTP_ENDPOINT="$OTLP_HTTP_ENDPOINT" SCRAPER_DRY_RUN="$([[ $DRY_RUN -eq 1 ]] && echo 1 || echo 0)" python3 <<PYEOF
import json, os, sys, time, subprocess

codex = json.loads(os.environ["CODEX_JSON"])
claude = json.loads(os.environ["CLAUDE_JSON"])
samples = codex + claude

now_ns = int(time.time() * 1e9)

def attr(k, v):
    if isinstance(v, bool):
        return {"key": k, "value": {"boolValue": v}}
    if isinstance(v, (int, float)):
        return {"key": k, "value": {"doubleValue": float(v)}}
    return {"key": k, "value": {"stringValue": str(v)}}

records = []
for s in samples:
    if s.get("used_percent") is None:
        continue
    attrs = [
        attr("event_name", "ai.subscription_limit.sampled"),
        attr("provider", s["provider"]),
        attr("account", s["account"]),
        attr("window", s["window"]),
        attr("used_percent", s["used_percent"]),
    ]
    if s.get("window_minutes") is not None:
        attrs.append(attr("window_minutes", s["window_minutes"]))
    if s.get("resets_at") is not None:
        attrs.append(attr("resets_at", s["resets_at"]))
    records.append({
        "timeUnixNano": str(now_ns),
        "observedTimeUnixNano": str(now_ns),
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "ai.subscription_limit.sampled"},
        "attributes": attrs,
    })

if not records:
    print("ai-subscription-limit-scraper: no samples gathered (Codex rollout JSONL missing/empty, "
          "and/or claude-accounts-usage.mjs unavailable/erroring) -- nothing to emit", file=sys.stderr)
    sys.exit(0)

payload = {
    "resourceLogs": [{
        "resource": {"attributes": [
            {"key": "service.name", "value": {"stringValue": "ai-subscription-limit-scraper"}},
            {"key": "host.name", "value": {"stringValue": "laptop"}},
        ]},
        "scopeLogs": [{
            "scope": {"name": "ai_subscription_limit_scraper"},
            "logRecords": records,
        }],
    }],
}

body = json.dumps(payload)
print(f"ai-subscription-limit-scraper: {len(records)} sample(s) -- "
      + ", ".join(f"{s['provider']}/{s['account']}/{s['window']}={s['used_percent']}%" for s in samples if s.get("used_percent") is not None),
      file=sys.stderr)

dry_run = os.environ.get("SCRAPER_DRY_RUN") == "1"
if dry_run:
    print(body)
    sys.exit(0)

endpoint = os.environ["OTLP_HTTP_ENDPOINT"].rstrip("/") + "/v1/logs"
r = subprocess.run(
    ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
     "-H", "Content-Type: application/json", "-d", body, "--max-time", "10", endpoint],
    capture_output=True, text=True,
)
code = r.stdout.strip()
if code != "200":
    print(f"ai-subscription-limit-scraper: POST to {endpoint} returned HTTP {code} (expected 200)", file=sys.stderr)
    sys.exit(1)
print(f"ai-subscription-limit-scraper: sent OK (HTTP {code})", file=sys.stderr)
PYEOF

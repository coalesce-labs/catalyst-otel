#!/usr/bin/env bash
# Deterministic validation gates for dashboard JSON and collector config.
# Exits 0 on all-pass, 1 on first failure.
set -euo pipefail

DASH="dashboards/unified-dashboard.json"
COLLECTOR="collector-config.yaml"
FAIL=0

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# --- collector: task_type + catalyst_exec_context + catalyst_dispatch_mode +
#     account-level rate-limit attrs (CTL-787) must reach Loki ---
for attr in task_type catalyst_exec_context catalyst_dispatch_mode account_email ratelimit_five_hour_pct ratelimit_seven_day_pct; do
  if grep -q "attributes\[\"${attr}\"\]" "$COLLECTOR"; then
    pass "${attr} copied in transform/logs ($COLLECTOR)"
  else
    fail "${attr} not copied in transform/logs ($COLLECTOR)"
  fi
done

# --- collector: CTL-812 fan-out agent attrs — account pace + host + process
#     metrics must reach Loki as underscore labels. These are added by the
#     collector half of CTL-812 (host.metrics.sampled / host.process.sampled /
#     account.ratelimit pace fields). EXPECTED to FAIL until that half lands. ---
for attr in ratelimit_five_hour_pace ratelimit_seven_day_pace host_cpu_pct host_mem_used_pct host_disk_used_pct host_mem_total_mb host_disk_total_gb host_cpu_count process_command process_rss_mb process_cpu_pct process_ticket process_phase; do
  if grep -q "attributes\[\"${attr}\"\]" "$COLLECTOR"; then
    pass "${attr} copied in transform/logs ($COLLECTOR)"
  else
    fail "${attr} not copied in transform/logs ($COLLECTOR) [EXPECTED until CTL-812 collector half lands]"
  fi
done

# --- dashboard: JSON validity ---
if jq empty "$DASH" 2>/dev/null; then
  pass "dashboard JSON is valid"
else
  fail "dashboard JSON is invalid"
fi

# --- dashboard: unique panel IDs ---
DUP=$(jq '[.. | objects | select(has("id") and has("gridPos")) | .id] | (length) as $n | (unique | length) as $u | $n - $u' "$DASH")
if [ "$DUP" -eq 0 ]; then
  pass "panel IDs are unique"
else
  fail "duplicate panel IDs (count: $DUP)"
fi

# --- dashboard: datasource UIDs resolve to known sources ---
BAD=$(jq '[.. | objects | select(.datasource?.uid) | .datasource.uid] | map(select(. != "prometheus" and . != "loki" and . != "-- Grafana --" and (startswith("$") | not))) | length' "$DASH")
if [ "$BAD" -eq 0 ]; then
  pass "all datasource UIDs are known"
else
  fail "unknown datasource UIDs (count: $BAD)"
fi

# --- dashboard: required new Prometheus phase panels present ---
for t in "Cost by Phase" "Tokens by Phase" "Sessions by Exec Context"; do
  COUNT=$(jq --arg t "$t" '[.. | objects | select(.title==$t)] | length' "$DASH")
  if [ "$COUNT" -gt 0 ]; then
    pass "panel '$t' present"
  else
    fail "missing panel '$t'"
  fi
done

# --- dashboard: Loki Tool Calls by Phase panel present ---
COUNT=$(jq '[.. | objects | select(.title=="Tool Calls by Phase")] | length' "$DASH")
if [ "$COUNT" -gt 0 ]; then
  pass "panel 'Tool Calls by Phase' present"
else
  fail "missing panel 'Tool Calls by Phase'"
fi

# --- dashboard: Cost by Dispatch Mode panel present (OTL-7) ---
COUNT=$(jq '[.. | objects | select(.title=="Cost by Dispatch Mode")] | length' "$DASH")
if [ "$COUNT" -gt 0 ]; then
  pass "panel 'Cost by Dispatch Mode' present"
else
  fail "missing panel 'Cost by Dispatch Mode'"
fi

# --- dashboard: Account Rate-Limit Usage panel present (CTL-787) ---
COUNT=$(jq '[.. | objects | select(.title=="Account Rate-Limit Usage (5h/7d) by account")] | length' "$DASH")
if [ "$COUNT" -gt 0 ]; then
  pass "panel 'Account Rate-Limit Usage (5h/7d) by account' present"
else
  fail "missing panel 'Account Rate-Limit Usage (5h/7d) by account'"
fi

# --- dashboard: Hierarchical placeholder panel present ---
COUNT=$(jq '[.. | objects | select(.type=="text" and (.title | test("Hierarchical"; "i")))] | length' "$DASH")
if [ "$COUNT" -gt 0 ]; then
  pass "hierarchical placeholder text panel present"
else
  fail "missing hierarchical placeholder text panel"
fi

# --- dashboard: Catalyst Orchestration row contains expected panel count ---
ROW_COUNT=$(jq '[.panels[] | select(.title=="Catalyst Orchestration") | .panels | length] | add // 0' "$DASH")
if [ "${ROW_COUNT:-0}" -eq 8 ]; then
  pass "Catalyst Orchestration row has 8 panels"
else
  fail "Catalyst Orchestration row has $ROW_COUNT panels (expected 8)"
fi

# --- dashboard: CTL-812 fan-out agent panels present (row + scoreboard + host
#     gauges + capacity stat + process attribution table) ---
for t in \
  "Catalyst Agent — Accounts & Host" \
  "Per-Account Rate-Limit Scoreboard" \
  "Host CPU % by hostname" \
  "Host Memory Used % by hostname" \
  "Host Disk Used % by hostname" \
  "Host Capacity (mem / disk / CPUs)" \
  "Top Processes by RSS (command / ticket / phase)"; do
  COUNT=$(jq --arg t "$t" '[.. | objects | select(.title==$t)] | length' "$DASH")
  if [ "$COUNT" -gt 0 ]; then
    pass "panel '$t' present"
  else
    fail "missing panel '$t'"
  fi
done

# --- dashboard: widened account selector — no bare execution-core selector may
#     remain in the account rate-limit panel (panel 52, CTL-812 widening) ---
BARE=$(jq '[.panels[] | select(.id==52) | .targets[].expr | select(test("service_name=\"catalyst.execution-core\""))] | length' "$DASH")
if [ "$BARE" -eq 0 ]; then
  pass "panel 52 account selector widened to catalyst.execution-core|catalyst.agent"
else
  fail "panel 52 still has $BARE bare catalyst.execution-core selector(s)"
fi

# NOTE: the single pass/fail gate is at the END of this file (not here), so every
# check below — the scoreboard check and ALL collector invariant checks (OTL-1
# one-pipeline-per-signal, OTL-25 traces-only-Tempo) — runs on every invocation
# regardless of dashboard-panel state. A mid-script early-exit here used to make
# those collector gates dead code whenever any dashboard assertion was red.

# --- scoreboard (panel 61): LogQL must use last_over_time (current value) and
#     the topk-by wrapper — `count_over_time(...) by (...)` is a LogQL parse
#     error (grouping not allowed on log-range aggregations) that shipped once ---
if jq -e '[.panels[] | select(.id==61) | .targets[].expr | select(test("last_over_time|topk by") | not)] | length == 0' "$DASH" > /dev/null; then
  pass "scoreboard panel 61 queries use last_over_time / topk by"
else
  fail "scoreboard panel 61 has a query without last_over_time/topk by"
fi

# --- collector: payload-parity invariant (OTL-1) — exactly ONE pipeline per
#     signal type. Fan-out destinations append to the EXISTING pipeline's
#     exporters (after the shared processors); a parallel per-vendor pipeline
#     (logs/honeycomb, metrics/dash0, ...) would let processor chains drift and
#     destinations fall out of sync. Comments are stripped before checking. ---
STRIPPED=$(grep -v '^\s*#' "$COLLECTOR")
if echo "$STRIPPED" | grep -qE '^\s+(logs|metrics|traces)/[A-Za-z0-9_]+:'; then
  fail "parallel per-vendor pipeline found in $COLLECTOR (violates OTL-1 payload-parity invariant)"
else
  pass "no parallel per-vendor pipelines (payload-parity invariant)"
fi
# Count pipelines ONLY within service.pipelines. Connectors (e.g. count,
# signal_to_metrics — OTL-20) declare `logs:`/`metrics:` INPUT keys at the same
# indent, so a whole-file grep miscounts them as pipelines. Scope to the
# pipelines: block (it is the last section under service:).
PIPELINES_BLOCK=$(echo "$STRIPPED" | awk '/^  pipelines:/{f=1;next} f')
for sig in logs metrics traces; do
  COUNT=$(echo "$PIPELINES_BLOCK" | grep -cE "^    ${sig}:\s*$" || true)
  if [ "$COUNT" -eq 1 ]; then
    pass "exactly one ${sig} pipeline"
  else
    fail "expected exactly one ${sig} pipeline, found ${COUNT}"
  fi
done

# --- collector: OTL-25 traces route to Tempo ONLY. Allowlist (not denylist):
#     the traces pipeline's exporter set must be a SUBSET of {otlp/tempo, debug}.
#     This fails on Loki (can't ingest traces), the per-span-billed vendors
#     (honeycomb/dash0), ANY future otlp/<vendor> trace leg, AND the case where
#     otlp/tempo is dropped entirely. The traces pipeline is last in the block. ---
TRACES_EXPORTERS=$(echo "$PIPELINES_BLOCK" | awk '/^    traces:/{f=1} f' | grep -E "^\s+exporters:" | head -1)
TRACES_IDS=$(echo "$TRACES_EXPORTERS" | sed -E 's/.*\[//; s/\].*//; s/,/ /g')
BAD_TRACE_EXP=""
HAVE_TEMPO=0
for id in $TRACES_IDS; do
  case "$id" in
    otlp/tempo) HAVE_TEMPO=1 ;;
    debug) : ;;
    *) BAD_TRACE_EXP="$BAD_TRACE_EXP $id" ;;
  esac
done
if [ -n "$BAD_TRACE_EXP" ]; then
  fail "traces pipeline exports to non-Tempo backend(s) (OTL-25: traces -> Tempo only):$BAD_TRACE_EXP"
elif [ "$HAVE_TEMPO" -eq 1 ]; then
  pass "traces pipeline routes to Tempo only (exporters subset of {otlp/tempo, debug})"
else
  fail "traces pipeline is missing the otlp/tempo exporter (OTL-25: traces -> Tempo)"
fi

# --- single pass/fail gate (moved here from mid-script so all checks run) ---
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Validation FAILED — see FAIL lines above"
  exit 1
fi

echo ""
echo "All checks passed."

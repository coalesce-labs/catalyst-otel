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
ROW_COUNT=$(jq '.panels[] | select(.title=="Catalyst Orchestration") | .panels | length' "$DASH")
if [ "$ROW_COUNT" -eq 8 ]; then
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

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Validation FAILED — see FAIL lines above"
  exit 1
fi

echo ""
echo "All checks passed."

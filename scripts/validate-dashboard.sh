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

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Validation FAILED — see FAIL lines above"
  exit 1
fi

echo ""
echo "All checks passed."

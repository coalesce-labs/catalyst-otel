#!/usr/bin/env bash
# Deterministic validation gates for dashboard JSON and collector config.
# Exits 0 on all-pass, 1 on first failure.
set -euo pipefail

DASH="dashboards/unified-dashboard.json"
HOSTS="dashboards/catalyst-fleet-hosts.json"   # OTL-21: Fleet & Hosts split out of $DASH
CODEX="dashboards/codex-usage.json"            # OTL-53: net-new Codex Usage dashboard
EVENTS="dashboards/catalyst-worker-event-stream.json"  # OTL-63: Loki-only forensic event tail
FLEETOPS="dashboards/catalyst-fleet-ops.json"          # OTL-5: fleet-ops / aiops dashboard
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

# --- dashboard: Account rate-limit panel present (CTL-787; renamed to the
#     per-account templated form "Account Rate Limits — $account", panel 52) ---
COUNT=$(jq '[.. | objects | select(.title=="Account Rate Limits — $account")] | length' "$DASH")
if [ "$COUNT" -gt 0 ]; then
  pass "panel 'Account Rate Limits — \$account' present"
else
  fail "missing panel 'Account Rate Limits — \$account'"
fi

# --- dashboard: Hierarchical placeholder panel present ---
COUNT=$(jq '[.. | objects | select(.type=="text" and (.title | test("Hierarchical"; "i")))] | length' "$DASH")
if [ "$COUNT" -gt 0 ]; then
  pass "hierarchical placeholder text panel present"
else
  fail "missing hierarchical placeholder text panel"
fi

# --- dashboard: CTL-812 fan-out account panels still in $DASH (the Fleet & Hosts
#     section moved to $HOSTS in OTL-21; the per-account scoreboard stayed here) ---
for t in \
  "Per-Account Rate-Limit Scoreboard"; do
  COUNT=$(jq --arg t "$t" '[.. | objects | select(.title==$t)] | length' "$DASH")
  if [ "$COUNT" -gt 0 ]; then
    pass "panel '$t' present ($DASH)"
  else
    fail "missing panel '$t' ($DASH)"
  fi
done

# --- fleet-hosts dashboard: JSON validity + the host/capacity/process panels
#     that moved out of $DASH in OTL-21 (catalyst-fleet-hosts split) ---
if jq empty "$HOSTS" 2>/dev/null; then
  pass "fleet-hosts dashboard JSON is valid"
else
  fail "fleet-hosts dashboard JSON is invalid"
fi
for t in \
  "Host CPU % by hostname" \
  "Host Memory Used % by hostname" \
  "Host Disk Used % by hostname" \
  "Host Capacity (mem / disk / CPUs)" \
  "Top Processes by RSS — \$hostname"; do
  COUNT=$(jq --arg t "$t" '[.. | objects | select(.title==$t)] | length' "$HOSTS")
  if [ "$COUNT" -gt 0 ]; then
    pass "panel '$t' present ($HOSTS)"
  else
    fail "missing panel '$t' ($HOSTS)"
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

# --- collector: traces exporter allowlist. Must include otlp/tempo and stay a
#     SUBSET of {otlp/tempo, otlp_http/honeycomb, otlp_http/dash0, debug}.
#     OTL-45 (#82) added the vendor legs (honeycomb/dash0) AFTER tail_sampling, so
#     the per-span bill rides only the sampled stream — they are now allowed.
#     Loki (otlp_http) is STILL rejected (it cannot ingest traces -> 404s), as is
#     any other unknown trace leg, AND the case where otlp/tempo is dropped
#     entirely. The traces pipeline is last in the block. ---
TRACES_EXPORTERS=$(echo "$PIPELINES_BLOCK" | awk '/^    traces:/{f=1} f' | grep -E "^\s+exporters:" | head -1)
TRACES_IDS=$(echo "$TRACES_EXPORTERS" | sed -E 's/.*\[//; s/\].*//; s/,/ /g')
BAD_TRACE_EXP=""
HAVE_TEMPO=0
for id in $TRACES_IDS; do
  case "$id" in
    otlp/tempo) HAVE_TEMPO=1 ;;
    otlp_http/honeycomb|otlp_http/dash0) : ;;
    debug) : ;;
    *) BAD_TRACE_EXP="$BAD_TRACE_EXP $id" ;;
  esac
done
if [ -n "$BAD_TRACE_EXP" ]; then
  fail "traces pipeline exports to a disallowed backend (allowed: otlp/tempo, otlp_http/honeycomb, otlp_http/dash0, debug):$BAD_TRACE_EXP"
elif [ "$HAVE_TEMPO" -eq 1 ]; then
  pass "traces pipeline exporters are within the allowlist {otlp/tempo, otlp_http/honeycomb, otlp_http/dash0, debug}"
else
  fail "traces pipeline is missing the otlp/tempo exporter (traces must always reach Tempo)"
fi

# =============================================================================
# OTL-53: Codex Usage dashboard ($CODEX) — structural + content assertions.
# Mirrors the $DASH/$HOSTS blocks so the net-new dashboard is a first-class,
# regression-gated artifact. Accumulates into $FAIL like every other check.
# =============================================================================

# --- codex dashboard: file exists + JSON validity ---
if [ -f "$CODEX" ] && jq empty "$CODEX" 2>/dev/null; then
  pass "codex dashboard JSON is valid"
else
  fail "codex dashboard JSON missing or invalid ($CODEX)"
fi

# --- codex dashboard: unique panel IDs ---
DUPC=$(jq '[.. | objects | select(has("id") and has("gridPos")) | .id]
           | (length) as $n | (unique | length) as $u | $n - $u' "$CODEX" 2>/dev/null || echo 1)
[ "${DUPC:-1}" -eq 0 ] && pass "codex panel IDs are unique" \
                       || fail "codex duplicate panel IDs (count: ${DUPC:-?})"

# --- codex dashboard: datasource UIDs resolve to known sources ---
BADC=$(jq '[.. | objects | select(.datasource?.uid) | .datasource.uid]
           | map(select(. != "prometheus" and . != "loki" and . != "-- Grafana --"
                        and (startswith("$") | not))) | length' "$CODEX" 2>/dev/null || echo 1)
[ "${BADC:-1}" -eq 0 ] && pass "codex datasource UIDs are known" \
                       || fail "codex unknown datasource UIDs (count: ${BADC:-?})"

# --- codex dashboard: unique uid, not the unified dashboard's ---
UIDC=$(jq -r '.uid // empty' "$CODEX" 2>/dev/null || echo "")
[ "$UIDC" = "codex-usage" ] && pass "codex uid is codex-usage" \
                            || fail "codex uid must be 'codex-usage' (got: '${UIDC:-none}')"

# --- codex dashboard: required named panels present (acceptance scenario 1) ---
for t in "Turns" "Tokens" "Tool Calls" "Cache Hit Rate" "Threads" "TTFT p50" \
         "Token Rate by Type" "Turn Rate by Model" "Tokens by Model" \
         "Turn Latency (p50/p95)" "TTFT / TTFM Latency (p50/p95)" \
         "Tool Usage" "Tool Success Rate" "Codex Events" "Codex Errors"; do
  if jq -e --arg t "$t" '[.. | objects | select(.title==$t)] | length > 0' "$CODEX" >/dev/null 2>&1; then
    pass "codex panel present: $t"
  else
    fail "codex panel missing: $t"
  fi
done

# --- codex dashboard: no cost telemetry (ChatGPT-sub auth emits none) ---
if jq -e '[.. | objects | select(.expr?) | .expr | select(test("cost"))] | length == 0' \
     "$CODEX" >/dev/null 2>&1; then
  pass "codex dashboard has no cost queries"
else
  fail "codex dashboard references a cost metric (must be absent)"
fi

# --- codex dashboard: sparse-event occurrence panels use count_over_time, not increase() ---
# Any Loki target that filters a codex.* event body must use count_over_time /
# last_over_time, never increase() (a Prometheus-counter idiom that expires at 15m
# and errors on empty ranges — see acceptance scenario 2).
if jq -e '[.. | objects | select(.datasource?.uid=="loki") | .targets[]?.expr
          | select(test("increase\\("))] | length == 0' "$CODEX" >/dev/null 2>&1; then
  pass "codex Loki targets avoid increase()"
else
  fail "codex Loki target uses increase() (use count_over_time for sparse events)"
fi

# --- codex dashboard: histogram_quantile keeps le inside sum by() ---
if jq -e '[.. | objects | select(.expr?) | .expr
          | select(test("histogram_quantile")) | select(test("sum by \\([^)]*le") | not)]
          | length == 0' "$CODEX" >/dev/null 2>&1; then
  pass "codex histogram_quantile queries keep le in sum by()"
else
  fail "codex histogram_quantile query missing le in sum by()"
fi

# --- docs: CLAUDE.md references the codex dashboard (OTL-53 Phase 3) ---
if grep -q "codex-usage.json" CLAUDE.md; then
  pass "CLAUDE.md documents codex-usage.json"
else
  fail "CLAUDE.md does not mention codex-usage.json"
fi

# =============================================================================
# OTL-63: Worker Event Stream Tail ($EVENTS) — structural + Loki-only assertions.
# Mirrors the $CODEX block so the net-new forensic tail is a first-class,
# regression-gated artifact. Accumulates into $FAIL like every other check.
# =============================================================================

# file exists + valid JSON
[ -f "$EVENTS" ] && jq empty "$EVENTS" 2>/dev/null && pass "events dashboard JSON valid" || fail "events dashboard missing/invalid ($EVENTS)"
# unique panel IDs
DUPE=$(jq '[..|objects|select(has("id") and has("gridPos"))|.id]|(length) as $n|(unique|length) as $u|$n-$u' "$EVENTS" 2>/dev/null || echo 1)
[ "${DUPE:-1}" -eq 0 ] && pass "events panel IDs unique" || fail "events duplicate panel IDs"
# datasource UID allowlist
BADE=$(jq '[..|objects|select(.datasource?.uid)|.datasource.uid]|map(select(.!="prometheus" and .!="loki" and .!="-- Grafana --" and (startswith("$")|not)))|length' "$EVENTS" 2>/dev/null || echo 1)
[ "${BADE:-1}" -eq 0 ] && pass "events datasource UIDs known" || fail "events unknown datasource UIDs"
# uid pinned
[ "$(jq -r '.uid//empty' "$EVENTS" 2>/dev/null)" = "catalyst-worker-event-stream" ] && pass "events uid ok" || fail "events uid must be catalyst-worker-event-stream"
# Loki-only: NO prometheus datasource anywhere (OTL-63 scope)
[ "$(jq '[..|objects|select(.datasource?.uid=="prometheus")]|length' "$EVENTS" 2>/dev/null||echo 1)" -eq 0 ] && pass "events dashboard is Loki-only" || fail "events dashboard references prometheus (must be Loki-only)"
# required template vars present (the noise floor + facets)
for v in node service noise noisename minsev search ticket; do
  jq -e --arg v "$v" '[.templating.list[]|select(.name==$v)]|length>0' "$EVENTS" >/dev/null 2>&1 \
    && pass "events var present: \$$v" || fail "events var missing: \$$v"
done
# events-only scope: every Loki target filters log_file_name="" (no pino leak)
jq -e '[..|objects|select(.datasource?.uid=="loki")|.targets[]?.expr]|all(test("log_file_name\\s*=\\s*\"\""))' "$EVENTS" >/dev/null 2>&1 \
  && pass "events targets scope log_file_name=\"\"" || fail "an events target does not scope log_file_name=\"\""
# never `| json` (shipped-broken gotcha)
jq -e '[..|objects|select(.targets?)|.targets[]?.expr|select(test("\\|\\s*json"))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "events dashboard avoids | json" || fail "events dashboard uses | json (forbidden)"
# line_format uses {{ __line__ }} not {{ .__line__ }}
jq -e '[..|objects|select(.targets?)|.targets[]?.expr|select(test("\\.__line__"))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "events line_format uses __line__" || fail "events uses {{ .__line__ }} (wrong)"
# no count_over_time(...) by (...) — grouping on log-range agg is a parse error; use sum by()(count_over_time())
jq -e '[..|objects|select(.targets?)|.targets[]?.expr|select(test("count_over_time\\([^)]*\\)\\s*by\\s*\\("))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "events avoids count_over_time(...) by (...)" || fail "events has count_over_time(...) by (...)"
# no increase() in Loki targets
jq -e '[..|objects|select(.datasource?.uid=="loki")|.targets[]?.expr|select(test("increase\\("))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "events Loki targets avoid increase()" || fail "events Loki target uses increase()"
# required named panels (filled in Phase 2/3)
for t in "Event Tail" 'Events / min — $node' "Last Seen by Entity / Action"; do
  jq -e --arg t "$t" '[..|objects|select(.title==$t)]|length>0' "$EVENTS" >/dev/null 2>&1 \
    && pass "events panel present: $t" || fail "events panel missing: $t"
done
# --- OTL-63 Phase 2: the tail + noise floor ---
# tail panel is a logs panel, Descending, with details
jq -e '[.panels[]|select(.title=="Event Tail")|select(.type=="logs" and .options.sortOrder=="Descending" and .options.enableLogDetails==true)]|length==1' "$EVENTS" >/dev/null 2>&1 \
  && pass "Event Tail is a descending logs panel with details" || fail "Event Tail panel shape wrong"
# noise floor: tail expr carries BOTH event_action!~ and event_name!~ (defect #1)
jq -e '[.panels[]|select(.title=="Event Tail")|.targets[].expr|select(test("event_action!~") and test("event_name!~"))]|length>0' "$EVENTS" >/dev/null 2>&1 \
  && pass "tail has paired action+name noise filters" || fail "tail missing paired noise filter (defect #1)"
# --- OTL-63 Phase 3: orientation strip + last-seen ---
# events/min: fixed [1m] window (NOT $__interval — that is not a per-minute rate),
# repeated over $node, and `or vector(0)` so a SILENT node reads 0 instead of
# vanishing (Loki emits no sample for an absent series). OTL-63 review P2 x3.
jq -e '[.panels[]|select(.title=="Events / min — $node")|.targets[].expr|select(test("count_over_time") and test("\\[1m\\]") and test("or vector\\(0\\)"))]|length>0' "$EVENTS" >/dev/null 2>&1 \
  && pass "events/min is per-minute with a vector(0) zero-floor" || fail "events/min must use [1m] and `or vector(0)`"
jq -e '[.panels[]|select(.title=="Events / min — $node")|select(.repeat=="node")]|length==1' "$EVENTS" >/dev/null 2>&1 \
  && pass "events/min repeats per node" || fail "events/min must repeat over \$node so each worker gets its own zero-floor"
jq -e '[.panels[]|select(.title=="Events / min — $node")|.targets[].expr|select(test("\\[\\$__interval\\]"))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "events/min avoids [\$__interval]" || fail "events/min uses [\$__interval] — not a per-minute rate"
# last-seen must compute a REAL wall-clock via max_over_time(unwrap observed_timestamp),
# NOT count_over_time — a count says THAT a family fired in the window, never WHEN,
# so it cannot deliver the stopped-family signal the panel is named for. OTL-63 review P2.
jq -e '[.panels[]|select(.title=="Last Seen by Entity / Action")|.targets[].expr|select(test("max by \\([^)]*event_entity") and test("max_over_time") and test("unwrap observed_timestamp"))]|length>0' "$EVENTS" >/dev/null 2>&1 \
  && pass "last-seen computes a real timestamp (unwrap observed_timestamp)" || fail "last-seen must use max_over_time(unwrap observed_timestamp), not a count"
jq -e '[.panels[]|select(.title=="Last Seen by Entity / Action")|.targets[].expr|select(test("count_over_time"))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "last-seen is not a count table" || fail "last-seen still uses count_over_time"
jq -e '[.panels[]|select(.title=="Last Seen by Entity / Action")|.fieldConfig.overrides[]?.properties[]?|select(.id=="unit" and .value=="dateTimeFromNow")]|length>0' "$EVENTS" >/dev/null 2>&1 \
  && pass "last-seen renders as time-ago" || fail "last-seen needs unit dateTimeFromNow"
# --- OTL-63 review: Loki ANCHORS label-filter regexes, so an unwrapped noise
# alternation silently suppresses nothing. Every non-sentinel $noise/$noisename
# option must carry an explicit `.*` wrap. Verified live: unwrapped, the tail
# leaked ~700 noise events/hr (42% of the "clean" tail).
for v in noise noisename; do
  jq -e --arg v "$v" '[.templating.list[]|select(.name==$v)|.options[]|select(.value!="zzz_never_zzz")|.value|select(test("\\.\\*")|not)]|length==0' "$EVENTS" >/dev/null 2>&1 \
    && pass "\$$v terms are wildcard-wrapped (Loki anchors regex)" || fail "\$$v has an unwrapped term — Loki anchors, so it suppresses nothing"
done

# --- OTL-63 review: the noise floor must never suppress a FAILURE ---
# catalyst.linear.read{result=failed} decomposes to event_action=read, and
# catalyst.observability.forward_failed matched the old forward.* name term, so the
# floor was hiding an ERROR-severity signal (190/hr) and the documented read-path
# failure signal (12/hr). Every noise clause carries an `or severity_number>=13`
# escape hatch, and $noisename suppresses forward_LAG only. NOTE: the hatch is
# >=17 (ERROR), NOT >=13 (WARN) — autotune-gauge and parallelism-sampled are
# emitted at WARN (239+240/hr), so a WARN hatch readmits 479/hr of pure metronome.
# Failed reads are WARN, so they are exempted explicitly by linear_read_result.
jq -e '[..|objects|select(.datasource?.uid=="loki")|.targets[]?.expr|select(test("event_action!~"))|select(test("or severity_number>=17")|not)]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "noise floor exempts ERROR + failed reads (failures never suppressed)" || fail "a noise-filtered target lacks the `or severity_number>=17` escape hatch"
jq -e '[.templating.list[]|select(.name=="noisename")|.options[]|.value|select(test("forward_failed"))]|length==0' "$EVENTS" >/dev/null 2>&1 \
  && pass "noisename does not suppress forward_failed" || fail "noisename suppresses forward_failed (the stack-blind signal)"
jq -e '[.templating.list[]|select(.name=="node")|select(.allValue==".*")]|length==1' "$EVENTS" >/dev/null 2>&1 \
  && pass "node allValue is .* (retains hostless events)" || fail "node allValue must be .* not .+"

# =============================================================================
# OTL-5: Fleet Ops dashboard ($FLEETOPS) — structural + content assertions.
# Mirrors the $EVENTS block. Accumulates into $FAIL.
# =============================================================================

# --- Phase 1: skeleton ---
[ -f "$FLEETOPS" ] && jq empty "$FLEETOPS" 2>/dev/null \
  && pass "fleet-ops dashboard JSON valid" || fail "fleet-ops dashboard missing/invalid ($FLEETOPS)"

DUPF=$(jq '[..|objects|select(has("id") and has("gridPos"))|.id]|(length) as $n|(unique|length) as $u|$n-$u' "$FLEETOPS" 2>/dev/null || echo 1)
[ "${DUPF:-1}" -eq 0 ] && pass "fleet-ops panel IDs unique" || fail "fleet-ops duplicate panel IDs (${DUPF:-?})"

BADF=$(jq '[..|objects|select(.datasource?.uid)|.datasource.uid]|map(select(.!="prometheus" and .!="loki" and .!="-- Grafana --" and (startswith("$")|not)))|length' "$FLEETOPS" 2>/dev/null || echo 1)
[ "${BADF:-1}" -eq 0 ] && pass "fleet-ops datasource UIDs known" || fail "fleet-ops unknown datasource UIDs (${BADF:-?})"

[ "$(jq -r '.uid//empty' "$FLEETOPS" 2>/dev/null)" = "catalyst-fleet-ops" ] \
  && pass "fleet-ops uid ok" || fail "fleet-ops uid must be catalyst-fleet-ops"

for v in node service; do
  jq -e --arg v "$v" '[.templating.list[]|select(.name==$v)]|length>0' "$FLEETOPS" >/dev/null 2>&1 \
    && pass "fleet-ops has \$$v var" || fail "fleet-ops missing \$$v template var"
done
jq -e '[.templating.list[]|select(.name=="node")|select(.allValue==".*")]|length==1' "$FLEETOPS" >/dev/null 2>&1 \
  && pass "fleet-ops node allValue==.*" || fail "fleet-ops node allValue must be .*"

# --- Phase 2: Prometheus panels ---
for t in "Effective vs Target Slots" "Running vs Queued Workers" "Load per Core" \
         "Eligible Work Waiting" "Dispatch Outcomes" "Phase Complete / Failed" \
         "Pipeline Completion Cadence"; do
  jq -e --arg t "$t" '[..|objects|select(.title==$t)]|length>0' "$FLEETOPS" >/dev/null 2>&1 \
    && pass "fleet-ops panel '$t' present" || fail "fleet-ops missing panel '$t'"
done
jq -e '[..|objects|select(.title=="Effective vs Target Slots")|.targets[].expr|select(test("catalyst_scheduler_max_parallel_(effective|target)"))]|length>=2' "$FLEETOPS" >/dev/null 2>&1 \
  && pass "fleet-ops slots panel uses scheduler gauges" || fail "fleet-ops slots panel missing scheduler gauges"

# --- Phase 3: Loki panels + idiom guards ---
for t in "Node Liveness (recent heartbeats)" "Worker Transitions" "Held / Needs-Human" \
         "Reap Requested vs Complete" "Reap Leak by Type" "Memory Pressure (warn / killed)"; do
  jq -e --arg t "$t" '[..|objects|select(.title==$t)]|length>0' "$FLEETOPS" >/dev/null 2>&1 \
    && pass "fleet-ops panel '$t' present" || fail "fleet-ops missing panel '$t'"
done
jq -e '[..|objects|select(.title=="Reap Requested vs Complete")|.targets[].expr|select(test("event_name=~\".+reap-(requested|complete)\"") and test("count_over_time"))]|length>=2' "$FLEETOPS" >/dev/null 2>&1 \
  && pass "fleet-ops reap panel uses Loki count_over_time on event_name" || fail "fleet-ops reap panel wrong source"
jq -e '[..|objects|select(.datasource?.uid=="loki")|.targets[]?.expr|select(test("\\|\\s*json") or test("increase\\("))]|length==0' "$FLEETOPS" >/dev/null 2>&1 \
  && pass "fleet-ops Loki targets avoid |json and increase()" || fail "fleet-ops Loki targets use |json or increase()"

# --- Phase 4: Forensic log report ---
jq -e '[.panels[]|.. |objects|select(.title=="Fleet Event Log")|select(.type=="logs")]|length==1' "$FLEETOPS" >/dev/null 2>&1 \
  && pass "fleet-ops has a logs-type 'Fleet Event Log'" || fail "fleet-ops missing logs-type 'Fleet Event Log'"
for v in ev sev; do
  jq -e --arg v "$v" '[.templating.list[]|select(.name==$v)]|length>0' "$FLEETOPS" >/dev/null 2>&1 \
    && pass "fleet-ops has \$$v var" || fail "fleet-ops missing \$$v template var"
done

# --- Phase 5: Alert file ---
FLEETALERTS="provisioning/alerting/fleet-ops-rules.yaml"
if [ -f "$FLEETALERTS" ] && command -v yq >/dev/null 2>&1; then
  yq -e '.groups[0].rules|length>=3' "$FLEETALERTS" >/dev/null 2>&1 \
    && pass "fleet-ops alerts define >=3 rules" || fail "fleet-ops alerts missing rules ($FLEETALERTS)"
elif [ -f "$FLEETALERTS" ]; then
  grep -q "catalyst_fleet_" "$FLEETALERTS" \
    && pass "fleet-ops alerts file present (yq absent — grep fallback)" || fail "fleet-ops alerts file malformed"
else
  fail "fleet-ops alerts file missing ($FLEETALERTS)"
fi

# --- single pass/fail gate (moved here from mid-script so all checks run) ---
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Validation FAILED — see FAIL lines above"
  exit 1
fi

echo ""
echo "All checks passed."

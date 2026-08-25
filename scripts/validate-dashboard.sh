#!/usr/bin/env bash
# Deterministic validation gates for dashboard JSON and collector config.
# Exits 0 on all-pass, 1 on first failure.
set -euo pipefail

DASH="dashboards/unified-dashboard.json"
HOSTS="dashboards/catalyst-fleet-hosts.json"   # OTL-21: Fleet & Hosts split out of $DASH
CODEX="dashboards/codex-usage.json"            # OTL-53: net-new Codex Usage dashboard
EVENTS="dashboards/catalyst-worker-event-stream.json"  # OTL-63: Loki-only forensic event tail
FLEETOPS="dashboards/catalyst-fleet-ops.json"          # OTL-5: fleet-ops / aiops dashboard
AIUSAGE="dashboards/ai-usage.json"                     # OTL: unified cross-provider spend dashboard
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

# NOTE (OTL-75): the six per-dimension panels carry the "Cumulative " prefix because their
#     counters are aggregated with max_over_time, not increase — per-session counters that
#     expire after 15m, so a per-bucket increase() undercounts. These assertions match on
#     EXACT titles, so a future rename breaks them loudly rather than silently; update the
#     title lists below together with the dashboard. Layout (y = 5,12,19,26,33,40,47) and the
#     weighted-allocation query contract are unchanged by that rename.
# --- OTL-71: spend/token economics panels are paired by dimension, followed by
#     model x token-type matrices. Exact grid assertions catch order, overlap,
#     and first-section placement regressions. ---
ECON_TITLES='["Cumulative Spend by Host","Cumulative Tokens by Host","Cumulative Spend by Model","Cumulative Tokens by Model","Cumulative Spend by Type","Cumulative Tokens by Type","Tokens by Model × Token Type","Spend by Model × Token Type"]'
ECON_LAYOUT='[
  {"title":"Cumulative Spend by Host","gridPos":{"h":7,"w":24,"x":0,"y":5}},
  {"title":"Cumulative Tokens by Host","gridPos":{"h":7,"w":24,"x":0,"y":12}},
  {"title":"Cumulative Spend by Model","gridPos":{"h":7,"w":24,"x":0,"y":19}},
  {"title":"Cumulative Tokens by Model","gridPos":{"h":7,"w":24,"x":0,"y":26}},
  {"title":"Cumulative Spend by Type","gridPos":{"h":7,"w":24,"x":0,"y":33}},
  {"title":"Cumulative Tokens by Type","gridPos":{"h":7,"w":24,"x":0,"y":40}},
  {"title":"Tokens by Model × Token Type","gridPos":{"h":8,"w":12,"x":0,"y":47}},
  {"title":"Spend by Model × Token Type","gridPos":{"h":8,"w":12,"x":12,"y":47}}
]'
if jq -e --argjson titles "$ECON_TITLES" '
  [.panels[] | select(.title as $t | $titles | index($t)) | .title] as $present
  | ($titles - $present) | length == 0
' "$DASH" >/dev/null; then
  pass "OTL-71 spend/token economics panels are present"
else
  fail "OTL-71 spend/token economics panel missing"
fi

if jq -e --argjson layout "$ECON_LAYOUT" '
  ($layout | map(.title)) as $titles
  | [.panels[] | select(.title as $t | $titles | index($t)) | {title, gridPos}]
  | sort_by(.gridPos.y, .gridPos.x) == $layout
' "$DASH" >/dev/null; then
  pass "OTL-71 spend/token panels have the paired first-section layout"
else
  fail "OTL-71 spend/token panel layout is wrong"
fi

# Tokens by Model must use the native token counter. Spend by Type must allocate
# native model spend using model+type token weights (input=1, output=5,
# cacheRead=.1, cacheCreation=2) rather than introducing a second cost source.
if jq -e '[.panels[] | select(.title=="Cumulative Tokens by Model") | .targets[].expr
          | select(test("claude_code_token_usage_tokens_total") and test("model"))]
         | length > 0' "$DASH" >/dev/null; then
  pass "OTL-71 Tokens by Model uses native model-attributed tokens"
else
  fail "OTL-71 Tokens by Model query is missing native model attribution"
fi

if jq -e '
  def complete_allocation($window):
    contains("claude_code_cost_usage_USD_total")
    and contains("claude_code_token_usage_tokens_total")
    and contains("type=\"input\"")
    and test("type=\\\"output\\\".*\\* 5")
    and test("type=\\\"cacheRead\\\".*\\* 0\\.1")
    and test("type=\\\"cacheCreation\\\".*\\* 2")
    and contains("on (model) group_left")
    and contains("clamp_min(")
    and contains(", 1e-12)")
    and contains($window);
  ([.panels[] | select(.title=="Cumulative Spend by Type") | .targets[].expr
    | select(complete_allocation("[$__range]"))] | length > 0)
  and
  ([.panels[] | select(.title=="Spend by Model × Token Type") | .targets[].expr
    | select(complete_allocation("[$__range]"))] | length > 0)
' "$DASH" >/dev/null; then
  pass "OTL-71 spend panels allocate native model spend with complete weighted proportions"
else
  fail "OTL-71 spend allocation query is incomplete"
fi

for matrix_spec in "Tokens by Model × Token Type|tokens|short|0" "Spend by Model × Token Type|spend|currencyUSD|12"; do
  IFS='|' read -r title value_field unit x <<EOF
$matrix_spec
EOF
  if jq -e --arg title "$title" --arg value_field "$value_field" --arg unit "$unit" --argjson x "$x" '
    [.panels[] | select(.title==$title
                         and .type=="table"
                         and .gridPos=={"h":8,"w":12,"x":$x,"y":47}
                         and .fieldConfig.defaults.unit==$unit
                         and (.targets | length)==4
                         and .targets[0].instant==true
                         and .targets[0].range==false
                         and .targets[0].format=="table"
                         and (.targets[0].expr | contains("claude_code_token_usage_tokens_total"))
                         and (.targets[0].expr | contains("[$__range]")))
     | .transformations[]
     | select(.id=="groupingToMatrix"
              and .options.rowField=="model_family"
              and .options.columnField=="type"
              and .options.valueField==$value_field
              and .options.emptyValue=="zero")]
    | length == 1
  ' "$DASH" >/dev/null; then
    pass "OTL-71 matrix configured: $title"
  else
    fail "OTL-71 model x token-type matrix misconfigured: $title"
  fi
done

# Matrix comparisons must remain stable across refreshes. Rows use hidden
# family/version keys, columns use the desired token lifecycle order, and every
# nominal cell exposes its share of the complete matrix as a percentage tooltip.
if jq -e '
  def matrix_ready($title; $value_field):
    .panels[]
    | select(.title==$title)
    | . as $panel
    | (.targets | map(.refId)) == ["A", "B", "C", "D"]
      and (.targets[0].expr | contains("family_rank") and contains("version_major") and contains("version_minor"))
      and (.targets[1].expr | contains(" * 100") and contains("scalar(clamp_min("))
      and all(.targets[0:2][];
              (.expr | contains("max without (type)")) and
              (["input", "cacheCreation", "cacheRead", "output"]
               | all(. as $type | any($panel.targets[0:2][]; .expr | contains("\"type\", \"" + $type + "\"")))))
      and (["input share", "cache write share", "cache hit share", "output share"]
           | all(. as $type | $panel.targets[1].expr | contains("\"type\", \"" + $type + "\"")))
      and (.targets[2].expr | startswith("label_replace(min(") and contains("\"config\", \"min\""))
      and (.targets[3].expr | startswith("label_replace(max(") and contains("\"config\", \"max\""))
      and all(.targets[2:4][]; (.hide // false) == false)
      and ([.transformations[]
            | select(.id=="sortBy" and .filter.id=="byRefId" and .filter.options=="/^(?:A|merge-A(?:-A)*)$/")
            | .options.sort]
           == [[{"field":"version_minor","desc":true}],
               [{"field":"version_major","desc":true}],
               [{"field":"family_rank","desc":false}]])
      and any(.transformations[];
              .id=="convertFieldType" and .filter.id=="byRefId" and .filter.options=="/^(?:A|merge-A(?:-A)*)$/"
              and .options.conversions==[
                {"targetField":"family_rank","destinationType":"number"},
                {"targetField":"version_major","destinationType":"number"},
                {"targetField":"version_minor","destinationType":"number"}
              ])
      and any(.transformations[];
              .id=="configFromData" and .options.configRefId=="merge-C-D"
              and .options.applyTo=={"id":"byName","options":"Value"}
              and .options.mappings==[
                {"fieldName":"min","handlerKey":"min","reducerId":"min"},
                {"fieldName":"max","handlerKey":"max","reducerId":"max"}
              ])
      and ([.transformations[] | select(.id=="groupingToMatrix" and .filter.options=="/^(?:A|merge-A(?:-A)*)$/")
            | .options.valueField] | index($value_field) != null)
      and ([.transformations[] | select(.id=="groupingToMatrix" and .filter.options=="/^(?:B|merge-B(?:-B)*)$/")
            | .options.valueField] | index("share") != null)
      and any(.transformations[]; .id=="joinByField" and .options.byField=="model_family\\type" and .options.mode=="outer")
      and any(.transformations[];
              .id=="calculateField"
              and .options.mode=="reduceRow"
              and .options.alias=="Total"
              and .options.replaceFields==false
              and .options.reduce=={"include":["input","cacheCreation","cacheRead","output"],"reducer":"sum"})
      and (.transformations | map(.id)
           | index("configFromData") < index("calculateField")
             and index("joinByField") < index("calculateField")
             and index("calculateField") < rindex("organize"))
      and ([.transformations[] | select(.id=="organize" and .options.indexByName["model_family\\type"]==0)
            | .options.indexByName]
           | index({"model_family\\type":0,"input":1,"cacheCreation":2,"cacheRead":3,"output":4,"Total":5,
                    "input share":6,"cache write share":7,"cache hit share":8,"output share":9}) != null)
      and .fieldConfig.defaults.fieldMinMax==false
      and (.fieldConfig.defaults | has("min") | not)
      and .fieldConfig.defaults.color.mode=="continuous-BlYlRd"
      and .fieldConfig.defaults.custom.cellOptions=={"type":"auto"}
      and ([.fieldConfig.overrides[]
            | select(any(.properties[]; .id=="custom.cellOptions"))
            | .matcher.options] | sort
           == (["input","cache write","cache hit (read)","output"] | sort))
      and ([{"value":"input","share":"input share"},
            {"value":"cache write","share":"cache write share"},
            {"value":"cache hit (read)","share":"cache hit share"},
            {"value":"output","share":"output share"}]
           | all(. as $column
             | any($panel.fieldConfig.overrides[];
                   .matcher.options==$column.value and
                   any(.properties[]; .id=="custom.cellOptions" and .value=={"type":"color-background","mode":"gradient"}) and
                   any(.properties[]; .id=="custom.tooltip.field" and .value==$column.share) and
                   any(.properties[]; .id=="custom.tooltip.placement" and .value=="auto"))
               and any($panel.fieldConfig.overrides[];
                       .matcher.options==$column.share and
                       any(.properties[]; .id=="custom.hideFrom.viz" and .value==true) and
                       any(.properties[]; .id=="unit" and .value=="percent"))))
      and (["input","cache write","cache hit (read)","output","Total"]
           | all(. as $field
             | any($panel.fieldConfig.overrides[];
                   .matcher.options==$field and
                   any(.properties[]; .id=="custom.footer.reducers" and .value==["sum"]))))
      and all($panel.fieldConfig.overrides[] | select(.matcher.options=="Total");
              all(.properties[]; .id!="custom.cellOptions"));
  matrix_ready("Tokens by Model × Token Type"; "tokens")
  and matrix_ready("Spend by Model × Token Type"; "spend")
' "$DASH" >/dev/null; then
  pass "OTL-71 matrices have deterministic axes, isolated gradients, share tooltips, and uncolored totals"
else
  fail "OTL-71 matrix comparison behavior is incomplete"
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

# --- codex dashboard: no FAKE cost telemetry -- Codex has no native
# codex_*cost* Prometheus metric (ChatGPT-sub auth emits none, verified
# 2026-08-24: no cost/dollar/usd/price/credit field in the rollout JSONLs,
# the OTLP feed, or the OpenAI platform Costs API, which is unreachable from
# this box -- no API key configured). A REAL cost row would have to reference
# a metric name matching this pattern, so guard against that specifically
# rather than banning "cost" outright -- the dashboard DOES carry a
# LogQL/unwrap-derived ESTIMATED-at-list-price row (OTL, 2026-08-24; see
# provisioning/prometheus/codex-price-table.md), which is legitimate as long
# as it never claims to be a native/real cost metric.
if jq -e '[.. | objects | select(.expr?) | .expr | select(test("codex.*cost|cost.*codex"; "i"))] | length == 0' \
     "$CODEX" >/dev/null 2>&1; then
  pass "codex dashboard has no fake native cost metric"
else
  fail "codex dashboard references a codex_*cost* metric (does not exist -- must be absent)"
fi

# --- codex dashboard: every panel titled "Cost" is labeled CALCULATED ---
# Guards the labeling discipline from acceptance scenario in the OTL PR: a
# cost panel that doesn't say CALCULATED (title or description) could be
# mistaken for a real bill. Renamed from "ESTIMATED" (Ryan directive,
# 2026-08-24) -- "calculated" pairs with Claude's "reported" on the AI Usage
# dashboard (both are list-price valuations of usage, computed by different
# parties; neither is a real marginal dollar).
if jq -e '[.. | objects | select(.title? // "" | test("cost"; "i"))
          | select((.title // "") + " " + (.description // "") | test("calculat"; "i") | not)] | length == 0' \
     "$CODEX" >/dev/null 2>&1; then
  pass "codex cost panels are labeled CALCULATED"
else
  fail "codex has a cost-titled panel not labeled CALCULATED (title or description)"
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

# --- Phase 5b: OTL-67 attribution-health guard (presence-over-absence) ---
TIERB="provisioning/alerting/tier-b-alerts.yaml"
if [ -f "$TIERB" ] && command -v yq >/dev/null 2>&1; then
  yq -e '.groups[].rules[] | select(.uid=="claude_code_attribution_missing")' "$TIERB" >/dev/null 2>&1 \
    && pass "attribution-health rule present" \
    || fail "attribution-health rule missing ($TIERB)"
  # presence-over-absence invariants: must NOT fire on quiet/idle fleet
  yq -e '.groups[].rules[] | select(.uid=="claude_code_attribution_missing")
         | select(.noDataState=="OK" and .execErrState=="OK" and .condition=="C")' \
        "$TIERB" >/dev/null 2>&1 \
    && pass "attribution-health rule is noData/execErr OK, condition C" \
    || fail "attribution-health rule must be noData/execErr OK with condition C"
  # threshold must be a 'gt' (fire on presence of a HIGH unattributed ratio)
  yq -e '.groups[].rules[] | select(.uid=="claude_code_attribution_missing")
         | .data[] | select(.refId=="C") | .model.conditions[0].evaluator.type == "gt"' \
        "$TIERB" >/dev/null 2>&1 \
    && pass "attribution-health threshold is gt" \
    || fail "attribution-health threshold must be gt"
elif [ -f "$TIERB" ]; then
  grep -q 'claude_code_attribution_missing' "$TIERB" \
    && pass "attribution-health rule present (yq absent — grep fallback)" \
    || fail "attribution-health rule missing (grep fallback)"
else
  fail "tier-b alerts file missing ($TIERB)"
fi

# --- OTL-67: attribution-health panel exists in unified dashboard ---
HAS_ATTRIB_PANEL=$(jq '[.. | objects | select(.title? == "Attribution Health")] | length' "$DASH")
[ "${HAS_ATTRIB_PANEL:-0}" -ge 1 ] \
  && pass "attribution-health panel present" \
  || fail "attribution-health panel missing in $DASH"
jq -e '[.. | objects | select(.targets?) | .targets[]?.expr | select(test("linear_key=\"\""))] | length > 0' "$DASH" >/dev/null 2>&1 \
  && pass "attribution-health panel queries linear_key=\"\"" \
  || fail "attribution-health panel query missing linear_key filter"

# --- OTL-67: runbook + data-dictionary cross-link ---
[ -f docs/runbook-otl-67-attribution.md ] \
  && pass "OTL-67 attribution runbook present" \
  || fail "docs/runbook-otl-67-attribution.md missing"
grep -q 'runbook-otl-67-attribution' docs/data-dictionary.md \
  && pass "data-dictionary links the OTL-67 runbook" \
  || fail "data-dictionary missing OTL-67 runbook link"

# =============================================================================
# OTL: AI Usage dashboard ($AIUSAGE) — unified cross-provider spend/usage.
# Mirrors the $CODEX block. Real ($) and estimated ($) must never be
# summable into one metric name/panel by accident -- the checks below guard
# that split as a structural invariant, not just a convention.
# =============================================================================

# --- ai-usage dashboard: file exists + JSON validity ---
if [ -f "$AIUSAGE" ] && jq empty "$AIUSAGE" 2>/dev/null; then
  pass "ai-usage dashboard JSON is valid"
else
  fail "ai-usage dashboard JSON missing or invalid ($AIUSAGE)"
fi

# --- ai-usage dashboard: unique panel IDs ---
DUPA=$(jq '[.. | objects | select(has("id") and has("gridPos")) | .id]
           | (length) as $n | (unique | length) as $u | $n - $u' "$AIUSAGE" 2>/dev/null || echo 1)
[ "${DUPA:-1}" -eq 0 ] && pass "ai-usage panel IDs are unique" \
                       || fail "ai-usage duplicate panel IDs (count: ${DUPA:-?})"

# --- ai-usage dashboard: datasource UIDs resolve to known sources ---
# "-- Mixed --" is allowed here (and only here) -- the Tokens by Provider
# panel deliberately mixes a Loki target (headless relay tokens) with two
# Prometheus targets (native anthropic/openai-desktop legs) on one axis,
# which requires the panel-level datasource to be the Mixed pseudo-source
# for per-target overrides to take effect.
BADA=$(jq '[.. | objects | select(.datasource?.uid) | .datasource.uid]
           | map(select(. != "prometheus" and . != "loki" and . != "-- Grafana --"
                        and . != "-- Mixed --"
                        and (startswith("$") | not))) | length' "$AIUSAGE" 2>/dev/null || echo 1)
[ "${BADA:-1}" -eq 0 ] && pass "ai-usage datasource UIDs are known" \
                       || fail "ai-usage unknown datasource UIDs (count: ${BADA:-?})"

# --- ai-usage dashboard: unique uid ---
UIDA=$(jq -r '.uid // empty' "$AIUSAGE" 2>/dev/null || echo "")
[ "$UIDA" = "ai-usage" ] && pass "ai-usage uid is ai-usage" \
                         || fail "ai-usage uid must be 'ai-usage' (got: '${UIDA:-none}')"

# --- ai-usage dashboard: required panels present ---
for t in "Claude Spend (reported)" "Codex Spend (calculated)" \
         "Spend Trend by Provider" "Codex Spend Trend (calculated)" \
         "Tool Calls by Provider" "Tokens by Provider"; do
  if jq -e --arg t "$t" '[.. | objects | select(.title==$t)] | length > 0' "$AIUSAGE" >/dev/null 2>&1; then
    pass "ai-usage panel present: $t"
  else
    fail "ai-usage panel missing: $t"
  fi
done

# --- ai-usage: no panel/query ever sums a reported-$ series with a
# calculated-$ series into one target. Heuristic: no single panel may have
# BOTH a target whose datasource is prometheus AND a target whose datasource
# is loki when its unit is currencyUSD -- that combination is exactly the
# "blended $" shape this dashboard must never produce (reported and
# calculated stay in separate panels, each single-datasource). Token/tool-
# call panels (unit != currencyUSD) are exempt on purpose -- Tokens by
# Provider deliberately mixes Prometheus+Loki targets to show headless
# relay tokens alongside the native legs (Ryan directive, 2026-08-24) --
# counts, not dollars, so no blend risk.
MIXED=$(jq '[.panels[] | select(.fieldConfig.defaults.unit? == "currencyUSD")
            | (.datasource.uid // (.targets[0].datasource.uid // "?")) as $ds0
            | select([.targets[].datasource.uid // $ds0] | unique | length > 1)] | length' \
      "$AIUSAGE" 2>/dev/null || echo 1)
[ "${MIXED:-1}" -eq 0 ] && pass "ai-usage never mixes reported+calculated \$ datasources in one panel" \
                         || fail "ai-usage has a currencyUSD panel mixing prometheus+loki targets (reported+calculated blend risk)"

# --- ai-usage: every currencyUSD panel sourced from Loki (i.e. Codex) is
# labeled ESTIMATED; every one sourced from Prometheus (i.e. the ai:*
# recording rules, reported $) is NOT labeled calculated (catches a stale/
# wrong label as loudly as a missing one). Renamed real/estimated ->
# reported/calculated (Ryan directive, 2026-08-24) -- neither number is a
# real marginal dollar (both providers are flat-rate subscriptions), they
# differ only in who computed them. ---
BADLABEL=$(jq '[.panels[] | select(.fieldConfig.defaults.unit? == "currencyUSD")
            | (.datasource.uid // (.targets[0].datasource.uid // "?")) as $ds
            | (.title // "") as $title
            | ((.title // "") + " " + (.description // "")) as $text
            | select(
                ($ds == "loki" and ($text | test("calculat"; "i") | not))
                or
                ($ds == "prometheus" and ($title | test("calculat"; "i")))
              )] | length' "$AIUSAGE" 2>/dev/null || echo 1)
[ "${BADLABEL:-1}" -eq 0 ] && pass "ai-usage \$ panels are labeled reported vs calculated correctly" \
                            || fail "ai-usage has a \$ panel with a reported/calculated label mismatch"

# --- single pass/fail gate (moved here from mid-script so all checks run) ---
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Validation FAILED — see FAIL lines above"
  exit 1
fi

echo ""
echo "All checks passed."

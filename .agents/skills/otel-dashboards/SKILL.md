---
name: otel-dashboards
description: Building and editing Grafana dashboards for this stack — the Claude Code / Codex telemetry schema (Prometheus metric names, Loki event/attribute names), PromQL/LogQL query patterns, the Loki-labels gotcha, and panel/color conventions. Use when adding or editing panels in dashboards/*.json.
---

# OTel dashboard development

Grafana reads Prometheus (metrics) and Loki (logs/events). Dashboards live in `dashboards/*.json` and hot-reload (no restart). Validate with `make dashboard-validate`.

## Telemetry schema

OTel dot-notation → Prometheus underscores, `_total` suffix on counters (`claude_code.cost.usage` → `claude_code_cost_usage_USD_total`).

**Prometheus counters:** `claude_code_session_count_total`, `claude_code_lines_of_code_count_total` (label `type`=added/removed), `claude_code_pull_request_count_total`, `claude_code_commit_count_total`, `claude_code_cost_usage_USD_total` (label `model`), `claude_code_token_usage_tokens_total` (labels `type`,`model`), `claude_code_code_edit_tool_decision_total` (labels `tool`,`decision`).

**Loki events** (log body carries the full `claude_code.<event>` name; the `event_name` label carries the short form): `user_prompt` (prompt_length), `tool_result` (tool_name, success, duration_ms, error), `api_request` (model, cost_usd, duration_ms, input/output/cache_read_tokens), `api_error` (model, error, status_code, attempt), `tool_decision` (tool_name, decision, source).

**Standard attributes** on all data: `session.id`, `app.version`, `organization.id`, `user.account_uuid`, `operator` (who was at keyboard), `project`, `hostname`, `branch`, `linear.key`, `catalyst.orchestration`, `catalyst.role`, `catalyst.orchestrator`. Cardinality controls and full env-var list: see `CLAUDE_OBSERVABILITY.md`.

## Codex (OpenAI) telemetry — same pipeline, no extra config

Codex CLI/desktop rides the **same** collector → Prometheus/Loki path; no Codex-specific config exists. Native `codex_*` metrics pass straight through; log events land in Loki under `service_name="codex_exec"` (widen selectors to `service_name=~"codex.*"`) via the service-agnostic `transform/metrics_normalize` (`event.name → event_name`). Surfaced by `dashboards/codex-usage.json`. **No cost telemetry** — ChatGPT-subscription auth emits no `codex_*_cost_*` series, so no cost panels.

Prometheus: `codex_conversation_turn_count_total` (model, originator, host_name) · `codex_tool_call_total` (tool, success, originator) · `codex_turn_token_usage_sum`/`_count`/`_bucket` (token_type, model) · `codex_turn_ttft_seconds_bucket` / `_ttfm_` / `_e2e_` latency histograms (model) · `codex_websocket_request_total`.

Loki events (body `|= "codex.tool_result"` under `{service_name=~"codex.*"}`; attrs `event_name`/`originator`/`model`/`tool`/`success` are labels): `codex.api_request`, `codex.tool_result`, `codex.tool_decision`, `codex.conversation_starts`, `codex.user_prompt`, `codex.turn_ttft`.

**Codex Usage dashboard conventions** (`codex-usage.json`, UID `codex-usage`; gated by `scripts/validate-dashboard.sh` + `make dashboard-validate`):
- Template vars `model`/`originator`/`hostname`/`bucket`; selectors on `codex_*` (Prom) and `service_name=~"codex.*"` (Loki).
- **Sparse-event KPIs** (Turns, Tool Calls, Threads, event logs) use Loki `count_over_time`, **not** Prometheus `increase()` — native `codex_*` counters expire at `metric_expiration:15m`, so a short/idle session keeps only its first sample and `increase()` reads zero. Turns = `codex.turn_ttft`; Tool Calls = `codex.tool_result`; Threads = `codex.conversation_starts`.
- The **Tokens** KPI has no per-event Loki source, so it uses the Prometheus `codex_turn_token_usage_sum` histogram, filtered by `model` only (it carries `token_type`+`model`, never `originator`/`host_name`).

## Loki labels — critical gotcha

OTel log-record attributes become **Loki stream labels** (`service_name`, `event_name`, `tool_name`, `success`, `status_code`, `model`, `duration_ms`, …). The `event_name` label is the **short** name (`tool_result`), never the `claude_code.`-prefixed form (that's in the body).
- Filter by body substring (preferred, matches existing panels): `{service_name=~"claude-code.*"} |= "claude_code.tool_result"`
- Filter/aggregate by label: `| success = "true"`, `sum by (tool_name) (...)`, `| line_format "{{.tool_name}}"`
- **Never** `| json` — the body is a plain string, not JSON.

## Query patterns

PromQL:
```promql
sum by (model) (rate(claude_code_cost_usage_USD_total{job="otel-collector"}[5m]))
sum(increase(claude_code_session_count_total{job="otel-collector"}[1h]))
sum by (model) (changes(claude_code_cost_usage_USD_total[5m]))
```
LogQL:
```logql
sum by (tool_name) (count_over_time({service_name=~"claude-code.*"} |= "claude_code.tool_result" [$__range]))
sort_desc(topk(10, sum by (tool_name) (count_over_time({service_name=~"claude-code.*"} |= "claude_code.tool_result" [$__range]))))
```
Sparse-event counts (occurrences, idle/short sessions): use Loki `count_over_time`, **not** Prometheus `increase()` — native counters expire at `metric_expiration:15m`, so `increase()` reads zero for a just-born/idle counter.

## Conventions

- **Stat/KPI:** `lastNotNull`, thresholds green→yellow→red, background color mode. Guard sparse LogQL with `or vector(0)` so empty reads show `0` not "No data".
- **Timeseries:** `table` legend with max/mean/sum; axis units; per-series color overrides.
- **Logs:** `line_format` for readability, sort descending.
- **`histogram_quantile`:** keep `le` inside `sum by (le, ...)`.
- **Template vars:** `includeAll:true`, `allValue:".*"`, `multi:true`. `allValue:".*"` also matches series lacking the label.
- **Colors:** green=success/added · yellow=warning · red=error/removed/Bash · blue=Read/Haiku/cache-read · purple=Sonnet/cache-create · orange=input/Grep.

Adding a panel: pick source (Prometheus=counters, Loki=events) → write query with the patterns above → choose viz → set gridPos (h,w,x,y) → thresholds/colors → test against live data → `make dashboard-validate`.

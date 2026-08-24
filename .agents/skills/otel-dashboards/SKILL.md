---
name: otel-dashboards
description: Building and editing Grafana dashboards for this stack — the Claude Code / Codex telemetry schema (Prometheus metric names, Loki event/attribute names), PromQL/LogQL query patterns, the Loki-labels gotcha, and panel/color conventions. Use when adding or editing panels in dashboards/*.json.
---

# OTel dashboard development

Grafana reads Prometheus (metrics) and Loki (logs/events). Dashboards live in `dashboards/*.json` and hot-reload (no restart). Validate with `make dashboard-validate`.

## Telemetry schema

OTel dot-notation → Prometheus underscores, `_total` suffix on counters (`claude_code.cost.usage` → `claude_code_cost_usage_USD_total`).

**Prometheus counters:** `claude_code_session_count_total`, `claude_code_lines_of_code_count_total` (label `type`=added/removed), `claude_code_pull_request_count_total`, `claude_code_commit_count_total`, `claude_code_cost_usage_USD_total` (label `model`), `claude_code_token_usage_tokens_total` (labels `type`,`model`), `claude_code_code_edit_tool_decision_total` (labels `tool`,`decision`).

**Loki events** (log body carries the full `claude_code.<event>` name; the `event_name` field carries the short form — see the structured-metadata gotcha below): `user_prompt` (prompt_length), `tool_result` (tool_name, success, duration_ms, error), `api_request` (model, cost_usd, duration_ms, input/output/cache_read_tokens), `api_error` (model, error, status_code, attempt), `tool_decision` (tool_name, decision, source).

**Standard attributes** on all data: `session.id`, `app.version`, `organization.id`, `user.account_uuid`, `operator` (who was at keyboard), `project`, `hostname`, `branch`, `linear.key`, `catalyst.orchestration`, `catalyst.role`, `catalyst.orchestrator`. Cardinality controls and full env-var list: see `CLAUDE_OBSERVABILITY.md`.

## Codex (OpenAI) telemetry — same pipeline, no extra config

Codex CLI/desktop rides the **same** collector → Prometheus/Loki path; no Codex-specific config exists. Native `codex_*` metrics pass straight through; log events land in Loki under `service_name="codex_exec"` (widen selectors to `service_name=~"codex.*"`) via the service-agnostic `transform/metrics_normalize` (`event.name → event_name`). Surfaced by `dashboards/codex-usage.json`. **No cost telemetry** — ChatGPT-subscription auth emits no `codex_*_cost_*` series, so no cost panels.

Prometheus: `codex_conversation_turn_count_total` (model, originator, host_name) · `codex_tool_call_total` (tool, success, originator) · `codex_turn_token_usage_sum`/`_count`/`_bucket` (token_type, model) · `codex_turn_ttft_seconds_bucket` / `_ttfm_` / `_e2e_` latency histograms (model) · `codex_websocket_request_total`.

Loki events (body `|= "codex.tool_result"` under `{service_name=~"codex.*"}`; attrs `event_name`/`originator`/`model`/`tool`/`success` are structured metadata — filter them with pipeline filters, see the gotcha below): `codex.api_request`, `codex.tool_result`, `codex.tool_decision`, `codex.conversation_starts`, `codex.user_prompt`, `codex.turn_ttft`.

**Codex Usage dashboard conventions** (`codex-usage.json`, UID `codex-usage`; gated by `scripts/validate-dashboard.sh` + `make dashboard-validate`):
- Template vars `model`/`originator`/`hostname`/`bucket`; selectors on `codex_*` (Prom) and `service_name=~"codex.*"` (Loki).
- **Sparse-event KPIs** (Turns, Tool Calls, Threads, event logs) use Loki `count_over_time`, **not** Prometheus `increase()` — native `codex_*` counters expire at `metric_expiration:15m`, so a short/idle session keeps only its first sample and `increase()` reads zero. Turns = `codex.turn_ttft`; Tool Calls = `codex.tool_result`; Threads = `codex.conversation_starts`.
- The **Tokens** KPI has no per-event Loki source, so it uses the Prometheus `codex_turn_token_usage_sum` histogram, filtered by `model` only (it carries `token_type`+`model`, never `originator`/`host_name`).

## Relay workers and container runners — attribution schema

The mini execution-core daemons are **retired**. Work runs as **laptop relay workers**
(`relay-dispatch.sh`, one `claude -p` per ticket) and, next, as **Cloudflare container runners**.
Both are ordinary Claude Code sessions emitting the same `claude_code_*` metrics and
`claude_code.*` events, so everything depends on what the launcher stamps on the OTel resource.

**Use the fleet's existing keys — do NOT invent new ones.** The daemon's per-worker composition
(CTL-492/495) is what the dashboards are already built on, and the collector already promotes it:

| resource attribute | label | notes |
| -- | -- | -- |
| `linear.key` | `linear_key` | **the ticket.** `unified-dashboard.json` keys *Token Burn / Cost / Tokens by Ticket* and *Unique Tickets* on it. A new `catalyst.ticket` would be a second, unused spelling — don't. |
| `task.type` | `task_type` | the phase. Drives *Cost by Phase* / *Tokens by Phase*. |
| `project` / `branch` | `project` / `branch` | repo + branch; these are unified's template vars. |
| `catalyst.orchestration` | `catalyst_orchestration` | who dispatched. Relay sets `relay`, which is the **relay-vs-interactive discriminator** (interactive sets nothing). |

For the container era, prefer **real semconv fields** over customs — all four verified end-to-end
through the CF tunnel into both Loki and Prometheus:

| `service.instance.id` | `service_instance_id` | which instance produced the record |
| `cloud.provider` / `cloud.platform` / `cloud.region` | `cloud_*` | absent on laptops, so `cloud_platform` cleanly separates runtimes |
| `container.id` | `container_id` | the container instance |
| `session.id` | `session_id` | already set by Claude Code itself |

### Loki promotes resource attributes automatically — the allowlist is NOT for that

⚠️ The comment above `transform/logs` says resource attributes "are not automatically promoted by
Loki's default config". **That is wrong as an argument for the allowlist.** Measured 2026-08-24: an
OTLP post carrying `catalyst.ticket`, `catalyst.phase`, `cloud.provider/platform/region`,
`container.id`, `service.instance.id` and `session.id` went through `logs/cloudflare` — whose only
processor is `resource/catalyst_cloud` — and **every one** arrived in Loki as structured metadata,
dot-to-underscore sanitized. Independently: `session_id`, `terminal_type`, `app_version` and
`organization_id` appear on `claude-code` streams and are in **no** allowlist entry.

So do not add a `transform/logs` copy just to make an attribute queryable in Loki — it already is.
The allowlist's real job is to create **log-record** attributes, which is what the logs-to-metrics
**connectors** group by (a connector cannot read a resource attribute). Add an entry only when a
connector needs that key as a grouping dimension. Prometheus needs nothing either way: the
`prometheus` exporter's `resource_to_telemetry_conversion` promotes any resource attribute to a label.

### ⚠️ The launcher trap that cost this signal entirely

`~/.claude/settings.json` has an `env` block, and it applies to **every** Claude Code session on the
box — **including one launched as `env OTEL_...=... claude -p`. The settings value wins.** Measured
2026-08-24: the relay dispatcher set `service.name`, `catalyst.ticket`, `host.name` and an endpoint
override; relay session `e68e2e6f` (CTC-178, 15:48:37Z–15:59:47Z) delivered **420 log records** in
which all four resolved to the *settings* values — `service_name="claude-code"`, `host_name="laptop"`,
no ticket, and no `service_namespace` (proving it went to the local collector, not the configured
tunnel). The data was never lost; it was **anonymous**, which reads exactly like "never sent".

The lever that outranks user settings is **`claude --settings <file>`** (documented order: managed >
command line > project-local > project > user). The file **replaces** the user value wholesale, so it
must restate every key you want — including the `host.name` pin.

The same replacement is why laptop sessions carry no `project`/`branch`/`linear_key` by default:
the user block's `OTEL_RESOURCE_ATTRIBUTES=host.name=laptop` overwrites direnv `use_otel_context`'s
richer set. Note `host_name` and `hostname` are **two different labels from two different sources**
(the settings pin vs direnv's `hostname -s`); nothing currently emits `hostname`, so a dashboard
filtering `hostname=~"$hostname"` will have an empty variable.

### The CF tunnel is the CONTAINER route, not the laptop route

Laptop sessions export **grpc direct to the internal collector's `otlp` receiver** and must stay
there — that is where the `claude_code_*` dashboards read from. The tunnel
(`otel-collector.catalystcloud.dev` → `:4319`) is the **M3 container** route. Contract, verified:

- `POST /v1/logs` and `/v1/traces` → **200**. Verified for BOTH `Content-Type: application/json`
  and `application/x-protobuf` (Claude Code sends protobuf, so container runners will too).
- `POST /v1/metrics` → **404** (no OTLP metrics pipeline on that receiver; `metrics/cloudflare` is
  fed by the spanmetrics connector). Container runners need that pipeline added before their
  cost/token metrics can land.
- Required headers: `CF-Access-Client-Id` + `CF-Access-Client-Secret` (the ingest pair). Without
  them the edge returns **403** — always run that no-auth control, because a 403 proves Access
  works and the fault is elsewhere.
- Everything through this receiver gets `service.namespace=catalyst-cloud`, so its presence on a
  record is a reliable "came via the tunnel" marker.

## Loki: structured metadata, NOT stream labels — critical gotcha

Only `service_name`, `service_namespace`, `__stream_shard__` are Loki **stream labels**. Every other OTel attribute — `event_name`, `event_action`, `event_entity`, `tool_name`, `success`, `status_code`, `model`, `host_name`, `scheduler_*`, … — is **structured metadata**, not a stream label. `event_name` is the short form (`tool_result`); the body carries the full `claude_code.tool_result`.

Consequences (each has shipped a broken panel to a live dashboard):
- **Filter metadata with a pipeline filter, NEVER inside the `{}` selector.** `{service_name="x"} |= "…" | host_name=~"$node"` works; `{service_name="x", host_name=~"$node"}` silently matches **zero** streams → "No data" (not an error).
- **`label_values(…, host_name)` returns empty** for a metadata field, so a Grafana template var built on it is blank — use a custom or metric-query var, not `label_values`. Likewise `/loki/api/v1/label/<field>/values` is empty; don't read that as "no data".
- You **can** still aggregate / unwrap by metadata: `sum by (event_action) (count_over_time({service_namespace="catalyst"}[1h]))`, `| unwrap scheduler_load1`.
- **Never `| json`** — the body is a plain string; `| json | __error__=""` silently drops every result. Match the body with `|= "claude_code.tool_result"`; format with `| line_format "{{.tool_name}}"`.
- `catalyst.*` `event_name` carries a high-card ticket/orchestration suffix (`phase.dispatch.launched.<TICKET>`) — match `event_name=~"prefix.*"`, never exact; it decomposes into low-card `event_entity` + `event_action`.
- When verifying a panel, run its **exact** query (selector + `$var`), not a hand-built `by (host_name)` aggregation that drops the selector — that false-greens a broken panel.

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

**Editing the JSON:** some `dashboards/*.json` mix jq-expanded and hand-compact objects, so a full `jq .` / reserialize round-trip can bury a 2-panel change under ~1000 lines of pure formatting churn. Check `jq . file | diff - file` first; if non-empty, splice new panels as text and shift a panel's row by string-replacing its compact `gridPos` line, rather than reserializing. Grafana renders by `gridPos`, so appended panels can sit visually mid-dashboard. Keep `git diff --stat` small.

Adding a panel: pick source (Prometheus=counters, Loki=events) → write query with the patterns above → choose viz → set gridPos (h,w,x,y) → thresholds/colors → test against live data → `make dashboard-validate`.

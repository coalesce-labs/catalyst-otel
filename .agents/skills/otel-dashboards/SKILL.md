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

## Relay workers (and future Cloudflare container runners) — attribution schema

The mini execution-core daemons are **retired**. Work runs as **laptop relay workers** — one
`claude -p` per ticket, dispatched by `~/catalyst/comms/coord/relay-dispatch.sh` — and later as
**Cloudflare container runners**. Both are ordinary Claude Code sessions, so they emit the SAME
`claude_code_*` metrics and `claude_code.*` Loki events as an interactive session. The only thing
that separates them is what the dispatcher stamps on the OTel **resource**.

**A series is a relay worker iff it carries `catalyst_ticket`.** Interactive sessions never set one.
That is the discriminator every panel in `dashboards/catalyst-relay-workers.json` (UID
`catalyst-relay-workers`) uses.

Semconv-first field list — real OpenTelemetry fields wherever one exists, namespaced customs only
for the two genuinely Catalyst-specific dimensions:

| resource attribute | label | who stamps it | why this field |
| -- | -- | -- | -- |
| `service.name` | `service_name` | dispatcher | semconv. **Currently loses** to `OTEL_SERVICE_NAME` in `~/.claude/settings.json` — see the trap below. |
| `service.instance.id` | `service_instance_id` | dispatcher / runner | semconv: WHICH instance produced the record (one worker, one container). Prefer over a custom `worker.id`. |
| `app.entrypoint` | `app_entrypoint` | Claude Code itself | needs `OTEL_METRICS_INCLUDE_ENTRYPOINT=1`. The relay-vs-interactive split that costs no custom attribute. |
| `session.id` | `session_id` | Claude Code itself | already emitted; one relay worker = one session. |
| `catalyst.ticket` | `catalyst_ticket` | dispatcher | **custom** — no semconv field means "unit of work". |
| `catalyst.phase` | `catalyst_phase` | dispatcher | **custom** — research/plan/implement/validate/pr/merge. |
| `cloud.provider` / `cloud.platform` / `cloud.region` | `cloud_*` | container runner only | semconv. Absent on laptop relays, so `cloud_platform` cleanly separates the two runtimes. |
| `container.id` | `container_id` | container runner only | semconv. |

**Prometheus gets these for free; Loki does NOT.** The `prometheus` exporter sets
`resource_to_telemetry_conversion: enabled`, which promotes *any* resource attribute to a label
(dots → underscores). `transform/logs` is an **allowlist**, so each attribute needs an explicit
`set(attributes["x"], resource.attributes["x.y"])` copy or it never becomes Loki structured
metadata. Both halves are wired in `collector-config.yaml`.

⚠️ **THE TRAP THAT COST THIS SIGNAL ENTIRELY (measured 2026-08-24).** `~/.claude/settings.json` has
an `env` block, and it applies to **every** Claude Code session on the box — including one launched
as `env OTEL_...=... claude -p`. It sets `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`,
`OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_PROTOCOL`, so the dispatcher's values were
silently discarded: relay session `e68e2e6f` (ticket CTC-178, 15:48–16:00 UTC) delivered **420 log
records** that carried `service_name="claude-code"`, `host_name="laptop"` and **no ticket at all**.
The data was never lost — it was anonymous. A per-invocation override has to win over user settings
(e.g. `claude --settings <file>`), or the keys must come out of `~/.claude/settings.json`.

The same block is why laptop sessions carry **no** `project` / `branch` / `linear_key`: its
`OTEL_RESOURCE_ATTRIBUTES=host.name=laptop` **replaces** (does not merge with) the richer set that
`use_otel_context` exports from direnv. `mini` / `mini-2` have no such block and do carry `project`.

**`host_name` is emitter-set, not derived here.** There is no collector-side hostname mapping table
— the laptop reads `laptop` because that string is hardcoded in `~/.claude/settings.json`, while the
separate `hostname` label comes from direnv's `hostname -s` (`Ryans-MacBook-Pro-2`). Two labels, two
sources, same machine. `transform/metrics_normalize` strips a trailing `.local` from `host_name`
(CTL-812 parity with `hostname`); it does no other rewriting.

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

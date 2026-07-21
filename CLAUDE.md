# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a comprehensive observability solution for monitoring Claude Code usage, performance, and costs. It implements OpenTelemetry-based monitoring with a complete stack: OTel Collector -> Prometheus (metrics) + Loki (logs) -> Grafana (visualization).

## Common Commands

### Stack Management
```bash
make up           # Start all services (Grafana on :3000, Prometheus on :9090, Loki on :3100, OTel Collector on :4317/:4318)
make down         # Stop all services
make restart      # Restart services
make status       # Show service status and URLs
make clean        # Clean up containers and volumes
```

### Development & Debugging
```bash
make logs                # View all logs
make logs-collector      # View OTel collector logs only
make logs-prometheus     # View Prometheus logs
make logs-grafana        # View Grafana logs
make validate-config     # Validate docker-compose and collector configs
make setup-claude        # Show Claude Code telemetry setup instructions
```

### Testing with Claude Code
To generate telemetry data for testing dashboards, run Claude Code with these environment variables:
```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_METRIC_EXPORT_INTERVAL=10000  # Optional: faster export for debugging
export OTEL_LOGS_EXPORT_INTERVAL=5000     # Optional: faster export for debugging
claude
```

## Architecture

### System Components

```
Claude Code (with telemetry enabled)
    |
    +-> OTLP gRPC (:4317) -+
    +-> OTLP HTTP (:4318) -+
                           |
                    OTel Collector
                           |
            +--------------+--------------+
            |                             |
      Metrics Pipeline              Logs Pipeline
            |                             |
            v                             v
    Prometheus (:8889)            Loki (:3100/otlp)
            |                             |
            +-------------+---------------+
                          |
                          v
                  Grafana (:3000)
```

### Component Details

1. **OpenTelemetry Collector** (collector-config.yaml)
   - Receivers: OTLP gRPC (:4317) and HTTP (:4318)
   - Processors: Resource processor (adds environment=production tag), Transform processor (copies resource attributes to log record attributes for Loki)
   - Exporters: Prometheus (:8889), Debug, OTLP HTTP to Loki
   - Pipelines: Separate routing for metrics and logs (logs pipeline includes transform/logs processor)

2. **Prometheus** (prometheus.yml)
   - Scrapes metrics from OTel Collector endpoint (:8889) every 15 seconds
   - Stores time-series metrics data
   - Queried by Grafana using PromQL

3. **Loki** (configured via docker-compose)
   - Receives logs/events from OTel Collector via OTLP HTTP
   - Stores event data for tool execution, API requests, and errors
   - Queried by Grafana using LogQL

4. **Grafana** (dashboards/unified-dashboard.json)
   - Pre-configured with Prometheus and Loki data sources
   - Dashboard auto-loaded from JSON file
   - 30-second refresh rate, default 1-hour time range

## Key Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Main stack orchestration with all service definitions |
| `collector-config.yaml` | OTel Collector configuration (receivers, processors, exporters, pipelines) |
| `prometheus.yml` | Prometheus scrape configuration targeting OTel Collector |
| `grafana-datasources.yml` | Auto-provisions Prometheus, Loki, and Alertmanager data sources |
| `grafana-dashboards.yml` | Auto-loads dashboard from JSON file |
| `dashboards/unified-dashboard.json` | Unified Grafana dashboard (33 panels across 10 sections) |
| `dashboards/codex-usage.json` | Codex Usage dashboard (Codex OpenAI CLI/desktop telemetry) |
| `Makefile` | All management commands for the stack |
| `CLAUDE_OBSERVABILITY.md` | Official Claude Code telemetry documentation reference |

## Claude Code Metrics Reference

### Counters (Prometheus)

| Metric | Prometheus Name | Description | Attributes |
|--------|-----------------|-------------|------------|
| `claude_code.session.count` | `claude_code_session_count_total` | CLI sessions started | - |
| `claude_code.lines_of_code.count` | `claude_code_lines_of_code_count_total` | Lines modified | type (added/removed) |
| `claude_code.pull_request.count` | `claude_code_pull_request_count_total` | PRs created | - |
| `claude_code.commit.count` | `claude_code_commit_count_total` | Commits created | - |
| `claude_code.cost.usage` | `claude_code_cost_usage_USD_total` | Cost in USD | model |
| `claude_code.token.usage` | `claude_code_token_usage_tokens_total` | Token usage | type, model |
| `claude_code.code_edit_tool.decision` | `claude_code_code_edit_tool_decision_total` | Tool decisions | tool, decision |

**Note**: OTel dot notation becomes underscore notation in Prometheus, with `_total` suffix for counters.

### Events (Loki Logs)

| Event Name | Description | Key Attributes |
|------------|-------------|----------------|
| `claude_code.user_prompt` | User prompt submission | prompt_length, prompt (if enabled) |
| `claude_code.tool_result` | Tool execution result | tool_name, success, duration_ms, error |
| `claude_code.api_request` | API request | model, cost_usd, duration_ms, input_tokens, output_tokens, cache_read_tokens |
| `claude_code.api_error` | API error | model, error, status_code, duration_ms, attempt |
| `claude_code.tool_decision` | Tool permission decision | tool_name, decision, source |

### Standard Attributes (All Data)

| Attribute | Description | Cardinality Control |
|-----------|-------------|---------------------|
| `session.id` | Unique session identifier | `OTEL_METRICS_INCLUDE_SESSION_ID` |
| `app.version` | Claude Code version | `OTEL_METRICS_INCLUDE_VERSION` |
| `organization.id` | Organization UUID | Always included when authenticated |
| `user.account_uuid` | Account UUID | `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` |
| `operator` | Who was at the keyboard (short name, e.g. `ryan`) | Set manually in `OTEL_RESOURCE_ATTRIBUTES` |
| `project` | Project name | Set via direnv `use_otel_context` |
| `hostname` | Machine short name | Set via direnv `use_otel_context` |
| `branch` | Git branch | Set via direnv `use_otel_context` |
| `linear.key` | Linear ticket ID (e.g. ADV-167) | Set via direnv `use_otel_context` |
| `catalyst.orchestration` | Catalyst orchestration group name | Set via direnv `use_otel_context` |
| `catalyst.role` | Catalyst worker/orchestrator role | Set via shell wrapper when `CATALYST_ORCHESTRATOR_ID` exists |
| `catalyst.orchestrator` | Catalyst orchestrator session ID | Set via shell wrapper when `CATALYST_ORCHESTRATOR_ID` exists |

## Codex Metrics Reference

Codex (OpenAI) CLI/desktop telemetry rides the **same** collector pipelines as Claude Code — no
Codex-specific collector, Prometheus, or Loki config exists. Native `codex_*` Prometheus metrics pass
straight through the OTLP receiver → Prometheus exporter (`:8889`); Codex log events land in Loki
under `service_name="codex_exec"` (widen selectors to `service_name=~"codex.*"`) via the
service-agnostic `transform/metrics_normalize` (`event.name → event_name`). Surfaced by the
**Codex Usage** dashboard (`dashboards/codex-usage.json`).

**No cost telemetry**: Codex authenticates via a ChatGPT subscription and emits **no** cost metric —
there is no `codex_*_cost_*` series and the dashboard has no cost panels.

### Metrics (Prometheus)

| Prometheus Name | Description | Attributes |
|-----------------|-------------|------------|
| `codex_conversation_turn_count_total` | Conversation turns | model, originator, host_name |
| `codex_tool_call_total` | Tool invocations | tool, success, originator |
| `codex_turn_token_usage_sum` / `_count` / `_bucket` | Token usage histogram per turn | token_type, model |
| `codex_turn_ttft_seconds_bucket` | Time-to-first-token latency histogram | model (use `histogram_quantile` with `le` inside `sum by`) |
| `codex_turn_ttfm_seconds_bucket` | Time-to-first-message latency histogram | model |
| `codex_turn_e2e_seconds_bucket` | End-to-end turn latency histogram | model |
| `codex_websocket_request_total` (and related) | Websocket request counters | - |

### Events (Loki Logs)

Filter on the log body (e.g. `|= "codex.tool_result"`) under `{service_name=~"codex.*"}`. Codex log
attributes (`event_name`, `originator`, `model`, `tool`, `success`) arrive as ordinary Loki labels.

| Event Name | Description | Key Attributes |
|------------|-------------|----------------|
| `codex.api_request` | API request | model, originator, duration |
| `codex.tool_result` | Tool execution result | tool, success, originator |
| `codex.tool_decision` | Tool permission decision | tool, decision, originator |
| `codex.conversation_starts` | New conversation/thread started | originator, model |
| `codex.user_prompt` | User prompt submission | originator, prompt_length |
| `codex.turn_ttft` | Turn time-to-first-token event | model, originator |

## Dashboard Development

### Current Dashboard Structure

Single unified dashboard (`dashboards/unified-dashboard.json`, UID: `claude-code-unified`) with 10 sections, 33 panels:

1. **Hero Stats** (y=0) — 6 stat/gauge panels: Estimated Cost, Token Burn, Sessions, Lines Changed, Cache Hit Rate, Tool Calls
2. **Activity Timeline** (y=5) — 5 full-width (w:24) timeseries: Cost Rate by Model, Token Rate by Type, Tool Usage Rate, Code Velocity, Active Sessions
3. **Model & Cache Intelligence** (y=41) — 4 pie/stat + 2 timeseries: Model Mix (Cost/Tokens), Token Type Breakdown, Cache Savings, Cache Efficiency Over Time, API Request Duration
4. **By Linear Ticket** (y=56) — 3 bar charts: Cost/Tokens/Tool Calls by `linear_key`
5. **By Project** (y=65) — 3 bar charts: Cost/Tokens/Tool Calls by `project`
6. **Top Tools** (y=74) — horizontal bar chart + Tool Success Rate timeseries
7. **Sessions** (y=83) — Token Burn by Session timeseries + Top Sessions bar chart (legend: `{{project}}/{{branch}} ({{linear_key}})`)
8. **Catalyst Orchestration** (y=92, collapsed) — Cost by Role + Worker Activity (only shows data when Catalyst is running)
9. **Cumulative Totals** (y=93) — Cumulative Cost + Tokens using `increase()` + Grafana `cumulativeTotal` transform
10. **Event Logs** (y=101) — Tool Execution Events + API Errors

### Codex Usage Dashboard

Separate dashboard `dashboards/codex-usage.json` (UID: `codex-usage`, title `Codex Usage`) surfacing
Codex (OpenAI) telemetry. Auto-provisioned via the same hot-reload provider as the unified dashboard
and gated by `scripts/validate-dashboard.sh` (structural + named-panel + query-shape assertions) and
`make dashboard-validate`. Sections:

1. **Codex — Overview** — 6 hero stats: Turns, Tokens, Tool Calls, Cache Hit Rate, Threads, TTFT p50
2. **Tokens & Turns** — Token Rate by Type, Turn Rate by Model, Tokens by Originator (timeseries)
3. **Latency** — Turn Latency (p50/p95, E2E) + TTFT/TTFM percentiles via `histogram_quantile`
4. **Tools** — Tool Usage (topk barchart) + Tool Success Rate
5. **Logs** — Codex Events + Codex Errors (Loki)

Query conventions:

- **No cost panels** — Codex ChatGPT-subscription auth emits no cost telemetry.
- Metric selectors filter on `service_name=~"codex.*"` events (Loki) and `codex_*` series
  (Prometheus), threaded with `model` / `originator` / `hostname` / `bucket` template variables.
- **Sparse-event/occurrence panels** (Threads, event logs) use Loki `count_over_time`, **not**
  Prometheus-counter `increase()` — native `codex_*` counters expire at `metric_expiration:15m`, so
  `increase()` errors on empty/idle ranges. This keeps idle-range panels empty without query errors.
- `histogram_quantile` queries keep `le` inside `sum by (le, ...)`.

### Template Variables

| Variable | Query | Cascades From |
|----------|-------|---------------|
| `project` | `label_values(claude_code_cost_usage_USD_total, project)` | — |
| `branch` | `label_values(...{project=~"$project"}, branch)` | project |
| `linear_key` | `label_values(...{project=~"$project"}, linear_key)` | project |
| `hostname` | `label_values(..., hostname)` | — |

All variables: `includeAll: true`, `allValue: ".*"`, `multi: true`.

### Query Patterns

**PromQL for Counters**:

```promql
# Rate over time
sum by (model) (rate(claude_code_cost_usage_USD_total{job="otel-collector"}[5m]))

# Increase over window
sum(increase(claude_code_session_count_total{job="otel-collector"}[1h]))

# Count changes (for tracking discrete events)
sum by (model) (changes(claude_code_cost_usage_USD_total[5m]))
```

**LogQL for Events**:

```logql
# Filter by event type using substring match on log body
# The log body contains the full event name (e.g., "claude_code.tool_result")
{service_name=~"claude-code.*"} |= "claude_code.tool_result"

# Filter by label via pipeline filter
# OTel attributes become Loki labels — event_name values do NOT have the claude_code. prefix
{service_name=~"claude-code.*"} | event_name = "tool_result"

# Filter by label value
{service_name=~"claude-code.*"} |= "claude_code.tool_result" | success = "true"

# Aggregate by label
sum by (tool_name) (count_over_time({service_name=~"claude-code.*"} |= "claude_code.tool_result" [$__range]))

# Sort metric results descending (for bar charts)
sort_desc(topk(10, sum by (tool_name) (count_over_time({service_name=~"claude-code.*"} |= "claude_code.tool_result" [$__range]))))

# Format log lines using label fields
{service_name=~"claude-code.*"} |= "claude_code.tool_result" | line_format "{{.tool_name}} {{.duration_ms}}ms"
```

**Important: Loki Labels and Log Body**

When OTel Collector exports to Loki via OTLP, OTel log record attributes become **Loki stream labels**:
- `service_name`, `event_name`, `tool_name`, `success`, `status_code`, `model`, `duration_ms`, etc. are all stream labels
- The `event_name` label contains the short name (e.g., `tool_result`, `api_request`, `api_error`) — NOT the `claude_code.` prefixed name
- The log body contains the full prefixed event name (e.g., `claude_code.tool_result`)
- Labels can be used in pipeline filters: `| success = "true"`, `| tool_name != ""`
- Labels can be used in aggregations: `sum by (tool_name)`, `sum by (status_code)`
- Labels can be used in line formatting: `| line_format "{{.tool_name}}"`
- High-cardinality labels (like `tool_name`) should be filtered via pipeline filters, not stream selectors
- Prefer `|= "claude_code.tool_result"` (substring match on body) over `| event_name = "tool_result"` for consistency with existing panels
- Do NOT use `| json` to parse log lines — the log body is a plain string, not JSON

### Panel Configuration Patterns

**Stat panels** (KPIs):

- Use `lastNotNull` for value
- Set thresholds: green (default) -> yellow (warning) -> red (critical)
- Background color mode for visual impact

**Timeseries panels**:

- Use `table` legend with calculated values (max, mean, sum)
- Configure axis labels and units
- Use overrides for specific series colors

**Logs panels**:

- Use `line_format` for readable output
- Enable log details for debugging
- Sort descending for recent events first

### Color Conventions

- **Green**: Healthy/success states, added lines
- **Yellow**: Warning thresholds
- **Red**: Error/critical states, Bash tool, removed lines
- **Blue**: Read tool, Haiku model, cache read tokens
- **Purple**: Sonnet model, cache creation tokens
- **Orange**: Input tokens, Grep tool

### Adding New Panels

1. Determine data source: Prometheus (counters/metrics) or Loki (events/logs)
2. Write query using patterns above
3. Choose visualization type based on data nature
4. Set appropriate grid position (h, w, x, y)
5. Configure thresholds and colors following conventions
6. Test with actual telemetry data

## Configuration Changes

### Change Procedures

| Change Type | File | Restart Required | Validation |
|-------------|------|------------------|------------|
| Collector pipeline | collector-config.yaml | Yes (`make restart`) | `make validate-config` |
| Prometheus scrape | prometheus.yml | Yes (`make restart`) | `make validate-config` |
| Data sources | grafana-datasources.yml | Yes (`make restart`) | Check Grafana UI |
| Dashboard | dashboards/unified-dashboard.json | No (auto-reload) | Refresh Grafana UI |
| Docker services | docker-compose.yml | Yes (`make restart`) | `make validate-config` |

### Extending the Collector

To add new processors or exporters to collector-config.yaml:

```yaml
processors:
  # Add new processors here
  batch:
    timeout: 1s
    send_batch_size: 1024

exporters:
  # Add new exporters here
  otlphttp/newbackend:
    endpoint: http://new-backend:4318

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [resource, batch]  # Add to pipeline
      exporters: [prometheus, debug, otlphttp/newbackend]
```

## Troubleshooting

### Common Issues

| Issue | Check | Solution |
|-------|-------|----------|
| No data in dashboards | Is Claude Code running with telemetry? | `make setup-claude` |
| Collector not receiving | Check collector logs | `make logs-collector` |
| Prometheus not scraping | Check targets | `http://localhost:9090/targets` |
| Grafana queries failing | Check data source health | Grafana UI -> Connections |
| Configuration errors | Validate configs | `make validate-config` |

### Debugging Data Flow

1. **At Claude Code**: Check `OTEL_METRICS_EXPORTER=console` output
2. **At Collector**: `make logs-collector` - look for received/exported data
3. **At Prometheus**: `http://localhost:9090/graph` - query raw metrics
4. **At Loki**: Grafana Explore -> Loki data source
5. **At Grafana**: Panel edit mode -> Query inspector

### Useful Debug Queries

```promql
# Check if any Claude Code metrics exist
{__name__=~"claude_code.*"}

# Check collector's own metrics
otelcol_receiver_accepted_metric_points
otelcol_exporter_sent_metric_points
```

```logql
# All Claude Code events
{service_name="claude-code"}

# Count events by type
sum by (event_name) (count_over_time({service_name="claude-code"} | json [1h]))
```

## Linear Ticket Workflow & PR Linking

Tickets live in the **OTL** Linear team. As you work a ticket, keep its Linear state, PR link, and progress trail current — do not leave a shipped ticket in Backlog.

### How PR ↔ ticket linking actually works (read this first)

Linear's **native GitHub integration** (webhook-driven, server-side — *not* subject to the `linearis` API rate limit) auto-attaches a PR to a ticket and advances its status. It links a PR to a ticket **only when the `OTL-NN` token appears in the PR _branch name_, _title_, or _body_ — NEVER in commit messages.**

- `Closes OTL-NN` (or `Fixes`/`Resolves`) in the **PR body** → ticket auto-advances **Backlog → PR** (PR open) → **Done** (merged).
- A bare `Refs OTL-NN` links the PR but is `contributes` — it will **not** auto-Done on merge. Prefer `Closes`.
- The OTL team's workflow state names are literally `Backlog → Research → Plan → Implement → Validate → PR → Done` (use these exact names with `--status`).

### Rules

1. **One ticket per branch/PR is the default.** Branch `otl-NN-slug`; PR title starts with `OTL-NN`; PR body has `Closes OTL-NN`. The catalyst-dev skills automate the rest: `/catalyst-dev:create-pr` → moves to `PR` + writes the Refs line; `/catalyst-dev:merge-pr` → moves to `Done`. Prefer these skills.
2. **File the ticket _before_ writing code** so the branch can carry its id and the integration attaches the PR on open. (OTL-22 was filed *after* its commit → it never linked.)
3. **Bundling multiple tickets in one PR requires manual care.** The branch names only one ticket; the body is scanned for all. List **every** delivered ticket in the body, each with its own keyword: `Closes OTL-18 · Closes OTL-22`. Preflight before opening a PR:
   ```bash
   git log --oneline origin/main..HEAD | grep -oE 'OTL-[0-9]+' | sort -u
   # if >1 id appears, ensure each is in the PR body (or split into separate PRs)
   ```
4. **Post a progress trail to the ticket** (commit-as-you-go is fine; at minimum post at PR time). Mirror research/build/verification summaries onto the ticket and attach artifacts — don't leave the narrative only in the PR body:
   ```bash
   linearis issues discuss OTL-NN --body "…what shipped, how verified, PR link, gap refs…"
   linearis files upload screenshot.png        # → returns assetUrl; embed as ![](assetUrl) in the comment
   linearis attachments create OTL-NN --url <url> --title "…"   # first-class link/artifact
   ```
5. **Reconciling a bundled/secondary ticket by hand** (when its code shipped on another ticket's branch): add its `Closes OTL-NN` to the PR body (the integration then attaches + advances it), then `linearis issues update OTL-NN --status PR` and post a comment noting it shipped bundled (commit SHA + primary ticket).

### `linearis` syntax (do not guess — `linearis issues usage`)

Everything is **plural** `linearis issues <verb>`; there is **no** singular `linearis issue` command. Read = `issues read OTL-NN` (NOT `issue get`); comment = `issues discuss OTL-NN --body`; status = `issues update OTL-NN --status`; attach = `attachments create OTL-NN --url`; upload = `files upload <file>`. The `catalyst-dev:linearis` skill's "Common mistakes" section is authoritative. JSON echo from mutations is sometimes unparseable even though the mutation succeeded. The Linear API rate limit (2500/hr) is **fleet-shared** — when it's hot, do forensics via `gh`/`git` and reserve `linearis` for fields only Linear has.

## Development Workflow

### Research Notes

Research documents and development thoughts are stored in `thoughts/shared/research/`. See `thoughts/CLAUDE.md` for the thoughts system documentation.

### Testing Changes

1. Start the stack: `make up`
2. Enable telemetry in Claude Code (see setup instructions above)
3. Use Claude Code to generate telemetry data
4. Verify data in Grafana dashboards
5. Iterate on dashboard/config changes
6. Export updated dashboard JSON if using Grafana UI editor

### Environment Variables Reference

For complete configuration options, see [CLAUDE_OBSERVABILITY.md](CLAUDE_OBSERVABILITY.md) which contains the official Claude Code telemetry documentation including:

- All supported environment variables
- Cardinality control options
- Privacy settings
- Backend considerations

<!-- catalyst-house-rules:begin -->
## Working the Loop (every agent — interactive too, not just skills)

These are house rules for anyone touching this repo's dev / PR / ticket workflow — whether you are
running a slash-command skill **or** working interactively and ad-hoc. They are **default
reflexes, not skill internals**: reach for them without being told, even on a one-off PR you opened
by hand. They defer their mechanism to the `catalyst-dev` plugin, available in every Catalyst-managed
repo. If that plugin is somehow unavailable, that is a broken environment — repair it (reload the
plugin) rather than routing around it. For GitHub state only, a single **bounded** `gh` check is an
acceptable last resort while you do; never a poll loop, and never a raw Linear API read (the
replica-read rule below is absolute).

- **Waiting on GitHub / CI / Linear state → subscribe to the event log, don't poll.** To block on a
  state change (a PR merged, CI turning green, a review posted, a push to a branch, a ticket
  transition), wait on the unified Catalyst event log instead of re-querying in a loop. Reach for
  the `catalyst-dev:wait-for-github` skill for GitHub events and `catalyst-dev:monitor-events` for
  the general wait-for-a-state-change pattern (they own the broker/webhook mechanics — don't
  reimplement them). A `gh` / `linearis` poll loop burns shared-quota API budget and silently misses
  reaction-only signals (next bullet). When the broker / webhook infra is down — or absent on a host
  with no event-log substrate — these skills degrade to a bounded single-event wait and a bounded
  poll becomes acceptable, but that degradation is the fallback, never your opening move.
- **Judging an automated code review → a clean pass is a reaction, not a review object.** The
  automated PR reviewer signals "no issues" with a 👍 reaction (or a terse "no major issues"
  comment) **instead of** opening review threads — detect it via the PR's reactions and issue
  comments, not only the reviews API. Recognizing the clean pass does **not** waive the rule that a
  PR is mergeable only once **every** review thread has been addressed and resolved.
- **Reading one Linear ticket → the freshness-gated local replica, not bare `linearis`.**
  Invoke the `catalyst-dev:linearis` skill and follow its "Reading Linear" contract — it reads the
  local replica behind a freshness gate (via its `linear_read_ticket` helper, run in the plugin's
  skill context) and does the loud stale/absent fallback for you. Don't hand-roll the read yourself:
  an **un-gated** `sqlite3` of the replica skips the freshness check (you may read stale data or
  create an empty DB), and a bare `linearis issues read <ID>` hits the rate-limited API and 429s the
  shared fleet quota — don't reach for it even as a fallback; the skill's helper owns the loud
  stale/absent path. Writes and list/search go through `linearis`.
<!-- catalyst-house-rules:end -->

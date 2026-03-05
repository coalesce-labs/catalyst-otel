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

4. **Grafana** (claude-code-dashboard.json)
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
| `claude-code-dashboard.json` | Main Grafana dashboard (17 panels across 6 sections) |
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
| `claude_code.tool_result` | Tool execution result | name, success, duration_ms, error |
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

## Dashboard Development

### Current Dashboard Structure

The dashboard (claude-code-dashboard.json) has 6 sections with 17 panels:

1. **Overview** (y=0) - 4 stat panels
   - Active Sessions, Cost, Token Usage, Lines of Code (all 1h windows)

2. **Cost & Usage Analysis** (y=5) - 3 timeseries panels
   - Cost by Model, Token Usage Rate by Type, API Requests by Model

3. **Tool Usage & Performance** (y=22) - 3 timeseries panels
   - Tool Usage Rate, Cumulative Tool Usage, Tool Success Rate

4. **Performance & Errors** (y=39) - 2 timeseries panels
   - API Request Duration by Model, API Error Rate

5. **User Activity & Productivity** (y=48) - 2 timeseries panels
   - Code Changes Rate, Development Activity (Commits/PRs)

6. **Event Logs** (y=57) - 2 logs panels
   - Tool Execution Events, API Error Events

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
# Filter by event type using structured metadata (NOT label selectors)
# ❌ Wrong: {service_name=~"claude-code.*", tool_name!=""}
# ✅ Correct: use pipeline filters for structured metadata
{service_name=~"claude-code.*"} | event_name = "tool_result"

# Filter by structured metadata field
{service_name=~"claude-code.*"} | tool_name != ""

# Aggregate by structured metadata field
sum by (tool_name) (count_over_time({service_name=~"claude-code.*"} | tool_name != "" [$__range]))

# Sort metric results descending (for bar charts)
sort_desc(topk(10, sum by (tool_name) (count_over_time({service_name=~"claude-code.*"} | tool_name != "" [$__range]))))

# Format log lines using structured metadata
{service_name=~"claude-code.*"} | event_name = "tool_result" | line_format "{{.tool_name}} {{.duration_ms}}ms"
```

**Important: Loki Structured Metadata vs Labels**

When OTel Collector exports to Loki via OTLP, event attributes become **structured metadata** (Loki 3.0+), NOT indexed labels:
- Only `service_name` is indexed as a queryable label
- Structured metadata fields (`tool_name`, `event_name`, `success`, etc.) can be used in:
  - Pipeline filters: `| tool_name != ""`
  - Aggregations: `sum by (tool_name)`
  - Line formatting: `| line_format "{{.tool_name}}"`
- They CANNOT be used in stream selectors: `{tool_name="Bash"}` won't work

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
| Dashboard | claude-code-dashboard.json | No (auto-reload) | Refresh Grafana UI |
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

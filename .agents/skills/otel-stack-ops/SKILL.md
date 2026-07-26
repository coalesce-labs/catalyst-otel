---
name: otel-stack-ops
description: Operating and changing the OTel stack — which config change needs a restart vs hot-reloads, how to extend the collector pipeline, and the data-flow troubleshooting path (collector → Prometheus → Loki → Grafana). Use when editing collector-config.yaml, prometheus.yml, docker-compose.yml, or debugging missing data.
---

# OTel stack operations

Commands are self-documenting: `make help`. Generate test telemetry: `make setup-claude` prints the env vars to point Claude Code at the local collector.

## Change → restart matrix

| Change | File | Restart? | Validate |
|---|---|---|---|
| Collector pipeline | collector-config.yaml | **yes** (`make restart`) | `make validate-config` |
| Prometheus scrape | prometheus.yml | **yes** | `make validate-config` |
| Data sources | grafana-datasources.yml | **yes** | Grafana UI |
| Dashboard JSON | dashboards/*.json | **no** (hot-reload) | `make dashboard-validate` |
| Docker services | docker-compose.yml | **yes** | `make validate-config` |

Gotcha: the collector validates **every declared exporter at boot** — an exporter block with an empty required field (e.g. an unset endpoint) crash-loops it. Keep env-gated exporters commented until their vars are set.

## Extending the collector

Add processors/exporters, then wire them into a pipeline's list (order matters):
```yaml
processors:
  batch: { timeout: 1s, send_batch_size: 1024 }
exporters:
  otlphttp/newbackend: { endpoint: http://new-backend:4318 }
service:
  pipelines:
    metrics:
      exporters: [prometheus, otlphttp/newbackend]   # append to the existing list
```

## Troubleshooting — follow the data path

| Symptom | Check | Fix |
|---|---|---|
| No data in dashboards | Claude Code running with telemetry? | `make setup-claude` |
| Collector not receiving | `make logs-collector` | — |
| Prometheus not scraping | `:9090/targets` | — |
| Grafana query fails | data-source health (Connections) | — |
| Config error | `make validate-config` | — |

Trace it end-to-end: Claude Code (`OTEL_METRICS_EXPORTER=console`) → collector (`make logs-collector`) → Prometheus (`:9090/graph`) → Loki (Grafana Explore) → Grafana (panel Query Inspector).

Debug queries:
```promql
{__name__=~"claude_code.*"}          # any Claude Code metric present?
otelcol_receiver_accepted_metric_points
otelcol_exporter_sent_metric_points
```
```logql
{service_name="claude-code"}         # all events
sum by (event_name) (count_over_time({service_name="claude-code"} [1h]))
```

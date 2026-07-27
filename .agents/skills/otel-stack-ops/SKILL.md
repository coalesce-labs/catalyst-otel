---
name: otel-stack-ops
description: Operating and changing the OTel stack — which config change needs a restart vs hot-reloads, how to extend the collector pipeline, and the data-flow troubleshooting path (collector → Prometheus → Loki → Grafana). Use when editing collector-config.yaml, prometheus.yml, docker-compose.yml, or debugging missing data.
disable-model-invocation: true
---

# OTel stack operations

Commands are self-documenting: `make help`. Generate test telemetry: `make setup-claude` prints the env vars to point Claude Code at the local collector.

## Environment — externalize, never hardcode

Environment-specific values are env vars, not literals in this repo. Reference them by name; do not hardcode a host, URL, endpoint, or token in a skill or config.

- **`OTEL_STACK_HOST`** — the deploy host (SSH). Ops commands that run remotely use `ssh "$OTEL_STACK_HOST" …`.
- **Fan-out exporters (optional, off by default):** `HONEYCOMB_API_KEY` / `HONEYCOMB_DATASET`, `DASH0_OTLP_ENDPOINT` / `DASH0_AUTH_TOKEN`. Their exporter blocks stay commented until the vars are set — the collector **validates every declared exporter at boot and crash-loops loudly** if an enabled exporter's endpoint expands empty (that is the intended fail-loud, not a silent drop).
- The private overlay adds its own (`CLOUDFLARE_TUNNEL_TOKEN`, `LANGFUSE_BASIC_AUTH`, …) — same rule.

If a command here needs an env var that is unset, **fail loudly** (`: "${OTEL_STACK_HOST:?set OTEL_STACK_HOST to your deploy host}"`) and tell the operator what to set — never silently fall back to a hardcoded default.

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

## Querying the live stack — use the Grafana datasource proxy

⚠️ On the deploy host, a bare `:9090` is a **different** Prometheus (host infra — no `otelcol_`/`catalyst_`/`claude_code_` series). The stack's own Prometheus scrapes `otel-collector:8889` inside the docker network. To query it (or Loki) directly, go through the Grafana datasource proxy:
```bash
docker exec otel-grafana curl -s \
  "http://localhost:3000/api/datasources/proxy/uid/prometheus/api/v1/query?query=<promql>"
# uid/loki for LogQL; paths: /label/__name__/values, /label/<key>/values, /series?match[]=<metric>
```
A bare host `:9090` returning "0 series" usually means you hit the wrong Prometheus, not a dead pipeline.

## Deploy gotchas

- **`make up`/`deploy` do NOT pull images** — `docker compose up -d` runs the tag already present, so a `:latest` service can sit months behind. Pin an image when a feature needs a minimum version (the collector is pinned to `0.154.0` for the `signal_to_metrics` connector). `--force-recreate` pulls a new tag if absent.
- **Single-file bind mounts go stale after `git pull`** — git replaces a file by rename (new inode), but a `./file:/container/file` mount stays pinned to the old inode, so the container serves pre-pull content until recreated. Mount **directories**, not single files (why `./dashboards` is a dir mount). After a config-only change, verify what the running container actually loaded, not the disk file.
- **The collector image is distroless** — no shell/`cat`/`grep`, so `docker exec otel-collector grep …` fails silently. Inspect the running config via `docker cp otel-collector:/etc/otel/collector-config.yaml /tmp/x` and read on the host.
- **`deploy.sh` exits non-zero at the push-dashboards step** — the unified dashboard is file-provisioned (`allowUiUpdates:false`), so the Grafana API POST returns 400. Benign: delivery is the bind mount + auto-reload, and the load-bearing container recreation already finished. Verify via `docker inspect otel-collector --format '{{.RestartCount}} {{.State.Status}}'`, not the exit code.
- **`make validate-config` only runs `docker compose config`.** To truly validate a collector config, `docker run otel/opentelemetry-collector-contrib:<pinned> validate --config …`.

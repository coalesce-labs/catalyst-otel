# catalyst-otel — codebase map

OpenTelemetry observability stack for Catalyst. Config-heavy: YAML + JSON +
a few shell scripts. No application source code.

## Top-level configs
- `docker-compose.yml` — defines the stack: `otel-collector`, `otel-prometheus`,
  `otel-loki`, `otel-tempo`, `otel-grafana` (+ named data volumes, `otel-network`).
- `docker-compose-lgtm.yml` — alternate all-in-one Grafana LGTM image.
- `collector-config.yaml` — OpenTelemetry Collector pipeline (receivers,
  processors, exporters). The largest/most important config in the repo (~50KB).
- `prometheus.yml` — Prometheus scrape config.
- `tempo.yaml` — Tempo (traces backend) config.
- `grafana-datasources.yml` / `grafana-dashboards.yml` — Grafana provisioning entrypoints.
- `Makefile` — up/down/logs helper targets.
- `setup-catalyst.sh` — large bootstrap/install script for the stack.
- `.envrc` — direnv env for the stack.

## Directories
- `provisioning/alerting/` — Grafana alert rules + routing: `alert-rules.yaml`,
  `scheduler-health-rules.yaml`, `tier-b-alerts.yaml`, `notification-policies.yaml`,
  `contact-points.yaml`.
- `dashboards/` — Grafana dashboard JSON: fleet daemon logs, control-loop-live,
  scheduler-health, unified-dashboard.
- `scripts/` — `setup-workspace.sh`, `deploy.sh`, `validate-dashboard.sh`.
- `docs/` — docs + `docs/images/` dashboard screenshots.
- `tests/` — sample OTel event JSON fixtures.

## Docs to read first
- `README.md` — stack overview + run instructions.
- `CLAUDE.md` / `CLAUDE_OBSERVABILITY.md` / `GEMINI.md` — agent + observability guidance.
- `CONTRIBUTING.md` — contribution workflow.

## Navigation note
Serena is read_only here. There is no navigable symbol graph (no TS/Python source);
value is file/dir location + config discovery. Grep across YAML/JSON for keys.

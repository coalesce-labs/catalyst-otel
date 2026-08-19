# Runbook: OTL-67 Attribution Health — Verifying `linear_key`/`project`/`branch` Return

## Root cause

SDK-dispatched execution-core workers emit `claude_code_*` metrics carrying only
`host_name`/`session_id`/`type` — no `linear_key`, `project`, or `branch`. The cause is a
settings.json precedence collision: `sdk-run-phase-agent.mjs` `buildQueryOptions()` sets
`settingSources: ["user","project"]`, so the host's `~/.claude/settings.json`
`OTEL_RESOURCE_ATTRIBUTES` pin (`host.name=<self>`) outranks the per-job env that
`buildSdkEnv()` composes (which correctly includes `linear_key`/`project`/`branch`).

The code fix is **[coalesce-labs/catalyst#3721](https://github.com/coalesce-labs/catalyst/pull/3721)**,
which changes the precedence so the per-job env wins.

## Detection

The `claude_code_attribution_missing` Grafana-managed alert (`tier-b-alerts.yaml`) fires when
more than 50% of live `claude_code_token_usage_tokens_total` series carry `linear_key=""`,
sustained for 15 minutes, with a volume floor of ≥5 series. The "Attribution Health" panel on the
unified dashboard (`dashboards/unified-dashboard.json`, uid `claude-code-unified`, panel 208)
shows the unattributed-series ratio over time.

## Post-merge verification (run after catalyst#3721 merges on `mini`)

Run these PromQL queries against the Prometheus instance on the otel-stack host. Wait for at least
one new SDK dispatch to land after the fix deploys.

```promql
# 1. Total live claude_code_* series
count(claude_code_token_usage_tokens_total)

# 2. Series with linear_key attributed — expect > 0 (was 0 before the fix)
count(claude_code_token_usage_tokens_total{linear_key!=""})

# 3. Series with project attributed — expect > 0
count(claude_code_token_usage_tokens_total{project!=""})
```

**Pass criterion:** attributed count in queries 2 and 3 climbs from 0 to approximately the total
from query 1 as new SDK dispatches land. The `claude_code_attribution_missing` alert returns to
Normal/NoData (no fire) automatically once the unattributed fraction drops below 0.5.

## Interactive sessions (not affected)

Sessions launched via `direnv use_otel_context` (interactive / concierge print-mode) are NOT
affected by this gap — they set env directly rather than going through `sdk-run-phase-agent.mjs`.
Only the `bg` SDK-dispatch path loses attribution.

## Manual silence / roll

If the alert fires on a known regression and you need to silence it while investigating:
1. Use Grafana's silence UI (under Alerting → Silences) to silence `claude_code_attribution_missing`.
2. Once catalyst#3721 is deployed and verified, remove the silence — the alert auto-resolves.

The live roll of the alert config itself (if you update `tier-b-alerts.yaml`) uses the human-gated
`scripts/deploy.sh` which restarts Grafana to reload provisioning. Validate with a throwaway
container first (see `provisioning/alerting/tier-b-alerts.yaml` header).

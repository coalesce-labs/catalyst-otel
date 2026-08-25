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

## Addendum (2026-08-24, OTL-81 investigation): a second, DIFFERENT unattributed population

The alert fired repeatedly 18:30-21:20 CT on 2026-08-24 (40-60% unattributed, well above the
50% threshold), well after catalyst#3721 was deployed. Investigating live against the otel-stack
Prometheus found this was **not a regression of the original OTL-67 bug** — the relay-dispatch
path itself was 100% attributed the entire window:

```
# ATTRIBUTED series in the 18:30-21:20 CT window: every single one has
# catalyst_orchestration="relay" and a non-empty linear_key (CTC-963/977/986/
# 990/991, account="acct6"). 0 exceptions.
#
# UNATTRIBUTED series in the same window: every single one has
# catalyst_orchestration ABSENT (not "relay", not ""), across 12 distinct
# sessions — a mix of standalone GLM probe sessions (model=~"glm.*", run
# interactively, not via relay-dispatch.sh) and interactive/concierge
# sessions including Agent-tool subagents dispatched in-process (e.g. this
# very OTL-81 worker's own session_id showed up unattributed).
```

**Root cause: a mix-shift, not a broken emitter.** Relay workers get their `linear.key`/`project`/
`branch` via `--settings` (the precedence fix is deliberate and was working the whole time, per
the "Interactive sessions (not affected)" section above — but that section undersold how much of
the total series volume interactive/subagent work can be on a night with heavy concierge
dispatch). These sessions were never in scope for the OTL-67 fix: a concierge/coordinator session
or an in-process Agent-tool subagent is not dispatched against one ticket the way a relay worker
is, so it structurally has no single `linear_key` to stamp. Counting them against the alert's
denominator just measures "how much of tonight's traffic was interactive," which is expected to
swing, not "is the relay-dispatch attribution fix still working."

**Fix (OTL-81, this PR):** both the alert (`provisioning/alerting/tier-b-alerts.yaml`,
`claude_code_attribution_missing`) and the dashboard panel (`unified-dashboard.json` panel 208,
"Attribution Health") are rescoped to `catalyst_orchestration="relay"` — the population the OTL-67
fix actually targets. A companion stat, "Interactive / Non-Relay Session Volume," was added next
to panel 208 so a growing interactive/subagent share of the fleet mix stays visible instead of
silently discounted.

**Also corrected while investigating:** GLM sessions carry **no `account` label at all** on this
stack (verified live: `count by (account) (claude_code_token_usage_tokens_total)` returns only
`account="acct6"` — GLM series have the label entirely absent, not `account="glm-coding"`). Any
future query or dashboard identifying GLM traffic must use `model=~"^glm.*"`, not an `account`
filter. See `provisioning/prometheus/recording-rules.yml`'s `ai:tokens:sum`/`ai:cost_usd:sum`
`provider="glm"` legs.

## Manual silence / roll

If the alert fires on a known regression and you need to silence it while investigating:
1. Use Grafana's silence UI (under Alerting → Silences) to silence `claude_code_attribution_missing`.
2. Once catalyst#3721 is deployed and verified, remove the silence — the alert auto-resolves.

The live roll of the alert config itself (if you update `tier-b-alerts.yaml`) uses the human-gated
`scripts/deploy.sh` which restarts Grafana to reload provisioning. Validate with a throwaway
container first (see `provisioning/alerting/tier-b-alerts.yaml` header).

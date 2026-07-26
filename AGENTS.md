# AGENTS.md

Agent instructions for this repo (vendor-neutral; `CLAUDE.md` imports this file).

## What this is

OpenTelemetry observability stack for monitoring Claude Code / Codex usage, cost, and performance: OTel Collector → Prometheus (metrics) + Loki (logs) → Grafana. Config-as-code; the stack runs on the `home` host.

- Commands: `make help` (self-documenting).
- Env-var / telemetry reference: `CLAUDE_OBSERVABILITY.md`.
- Research notes: `thoughts/shared/research/`.

## Task-specific context (load on demand)

- **Building/editing dashboards** (telemetry schema, PromQL/LogQL patterns, Loki-label gotcha, panel/color conventions) → skill `.claude/skills/otel-dashboards/`.
- **Changing config or debugging missing data** (restart-vs-hot-reload matrix, extending the collector, data-flow troubleshooting) → skill `.claude/skills/otel-stack-ops/`.

Don't restate those here — read the skill when the task calls for it.

## Linear + PR workflow (OTL team)

Tickets live in the **OTL** team; states are `Backlog → Research → Plan → Implement → Validate → PR → Done`. Keep a shipped ticket out of Backlog.

- Linear's GitHub integration links a PR to a ticket **only via the `OTL-NN` token in the PR branch, title, or body — never commit messages.** `Closes OTL-NN` in the body auto-advances Backlog→PR→Done on merge; bare `Refs` links but won't auto-Done — prefer `Closes`.
- **File the ticket before coding** so the branch carries its id. Default one ticket per branch/PR: branch `otl-NN-slug`, title starts `OTL-NN`, body has `Closes OTL-NN`.
- **Bundling multiple tickets:** the branch names one; list **every** delivered ticket in the body with its own `Closes`. Preflight: `git log --oneline origin/main..HEAD | grep -oE 'OTL-[0-9]+' | sort -u` — if >1, ensure each is in the body or split.
- Post a progress trail on the ticket (at least at PR time): `linearis issues discuss OTL-NN --body "…"`, attach artifacts with `linearis attachments create OTL-NN --url …`.
- Prefer the `catalyst-dev` skills (`create-pr` → PR state, `merge-pr` → Done). `linearis` is plural-only (`issues read|discuss|update`); `issues usage` for syntax.

> The always-on "Working the Loop" house rules (subscribe-don't-poll, clean-review-is-a-reaction, read-Linear-via-replica) live in `CLAUDE.md` under the tooling-managed `catalyst-house-rules` sentinel block — don't duplicate them here.

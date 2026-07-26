# AGENTS.md

Agent instructions for this repo (vendor-neutral; `CLAUDE.md` imports this file).

## What this is

OpenTelemetry observability stack for monitoring Claude Code / Codex usage, cost, and performance: OTel Collector → Prometheus (metrics) + Loki (logs) → Grafana. Config-as-code; the stack runs on the `home` host.

- Commands: `make help` (self-documenting).
- Env-var / telemetry reference: `CLAUDE_OBSERVABILITY.md`.
- Research notes: `thoughts/shared/research/`.

## Task-specific context (load on demand)

Skills live in `.agents/skills/` (vendor-neutral; Claude Code discovers them via
the `.claude/skills` → `../.agents/skills` symlink, and they are readable by any
agent at the path below):

- **Building/editing dashboards** (telemetry schema, PromQL/LogQL patterns, Loki-label gotcha, panel/color conventions) → `.agents/skills/otel-dashboards/SKILL.md`.
- **Changing config or debugging missing data** (restart-vs-hot-reload matrix, extending the collector, data-flow troubleshooting) → `.agents/skills/otel-stack-ops/SKILL.md`.

Don't restate those here — read the skill when the task calls for it.

## Linear + PR workflow (OTL team)

Tickets live in the **OTL** team; states are `Backlog → Research → Plan → Implement → Validate → PR → Done`. Keep a shipped ticket out of Backlog.

- Linear's GitHub integration links a PR to a ticket **only via the `OTL-NN` token in the PR branch, title, or body — never commit messages.** `Closes OTL-NN` in the body auto-advances Backlog→PR→Done on merge; bare `Refs` links but won't auto-Done — prefer `Closes`.
- **File the ticket before coding** so the branch carries its id. Default one ticket per branch/PR: branch `otl-NN-slug`, title starts `OTL-NN`, body has `Closes OTL-NN`.
- **Bundling multiple tickets:** the branch names one; list **every** delivered ticket in the body with its own `Closes`. Preflight: `git log --oneline origin/main..HEAD | grep -oE 'OTL-[0-9]+' | sort -u` — if >1, ensure each is in the body or split.
- Post a progress trail on the ticket (at least at PR time): `linearis issues discuss OTL-NN --body "…"`, attach artifacts with `linearis attachments create OTL-NN --url …`.
- Prefer the `catalyst-dev` skills (`create-pr` → PR state, `merge-pr` → Done). `linearis` is plural-only (`issues read|discuss|update`); `issues usage` for syntax.

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

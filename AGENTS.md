# AGENTS.md

Vendor-neutral agent instructions; `CLAUDE.md` imports this.

## What this is

OTel observability stack for Claude Code / Codex usage, cost, and performance: Collector → Prometheus (metrics) + Loki (logs) → Grafana. Config-as-code; runs on a single deploy host (reached over SSH as `$OTEL_STACK_HOST`).

- Commands: `make help`.
- Telemetry / env-var reference: `CLAUDE_OBSERVABILITY.md`.
- Research notes: `thoughts/shared/research/`.

## Skills (load on demand)

In `.agents/skills/` — Claude Code finds them via the `.claude/skills` symlink; any agent can read the path. Read the relevant one; don't restate it here.

- Dashboards — telemetry schema, PromQL/LogQL, Loki gotchas, panels → `otel-dashboards`.
- Stack config changes & missing-data debugging → `otel-stack-ops`.

## Linear + PR workflow (OTL team)

States: `Backlog → Research → Plan → Implement → Validate → PR → Done`. Don't leave shipped tickets in Backlog.

- GitHub↔Linear links a PR only via the `OTL-NN` token in the branch, title, or body — never commit messages. `Closes OTL-NN` in the body auto-advances Backlog→PR→Done on merge; bare `Refs` won't — prefer `Closes`.
- File the ticket before coding so the branch carries its id: `otl-NN-slug` branch, `OTL-NN` title, `Closes OTL-NN` body. One ticket per PR by default.
- Bundling >1 ticket: list each in the body with its own `Closes` (the branch names only one). Preflight `git log --oneline origin/main..HEAD | grep -oE 'OTL-[0-9]+' | sort -u`.
- Progress trail at PR time: the catalyst-dev create-pr / merge-pr skills handle it; else `linearis issues discuss OTL-NN` + `linearis attachments create`. `linearis` is plural (`issues read|discuss|update`; `issues usage` for syntax).

## Catalyst Development Workflow

This project uses [Catalyst](https://github.com/coalesce-labs/catalyst) for AI-assisted development.

### Available Workflows

**Research → Plan → Implement → Validate:**
```
/research-codebase    # Research codebase with parallel agents
/create-plan          # Create implementation plan (interactive)
/iterate-plan         # Update plan based on feedback
/implement-plan       # Execute plan (use --team for complex multi-domain work)
/validate-plan        # Verify implementation matches plan
```

**Oneshot (end-to-end with context isolation):**
```
/oneshot TICKET-123   # Full pipeline: research → plan → implement
/oneshot "question"   # Freeform research → plan → implement
```

**Git & PR Lifecycle:**
```
/commit               # Conventional commit with auto-detected type/scope
/create-pr            # Create PR with Linear integration
/describe-pr          # Generate/update PR description
/merge-pr             # Merge with verification
/wait-for-github      # Event-driven CI/PR wait — NEVER poll gh pr view/checks directly
```

**CI Commands (non-interactive, for automation):**
```
/ci-commit            # Autonomous commit (no prompts)
/ci-describe-pr       # Autonomous PR description
```

**Orchestration:**
```
/catalyst-filter      # Register semantic event interests (orchestrators only)
```

**Linear reads:** see "Working the Loop" below (freshness-gated local replica, never a bare `sqlite3`/`linearis issues read`).

### Agent Teams

For complex implementations spanning multiple domains (frontend + backend + tests),
use the `--team` flag with implement-plan:

```
/implement-plan --team thoughts/shared/plans/my-plan.md
```

**When to use `--team`:**
- Plan spans 3+ independent domains with non-overlapping file changes
- Total scope is 10+ files across 3+ directories
- Phases can be executed in parallel

**When NOT to use `--team`:**
- Sequential phases with tight dependencies
- Changes concentrated in same directory
- Small scope (fewer than 10 files)

### Model Selection

Catalyst uses explicit model tiers for optimal cost/quality:
- **Opus**: Planning, complex analysis, implementation orchestration
- **Sonnet**: Code analysis, PR workflows, structured research
- **Haiku**: File finding, data collection, fast lookups

### Thoughts System

This project uses the thoughts system for persistent context:
- Research → `thoughts/shared/research/`
- Plans → `thoughts/shared/plans/`
- Handoffs → `thoughts/shared/handoffs/`
- PR descriptions → `thoughts/shared/prs/`

**IMPORTANT**: NEVER write to `thoughts/searchable/` — it's a read-only search index.

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

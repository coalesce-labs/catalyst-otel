# CLAUDE.md

Repo instructions are vendor-neutral and live in `AGENTS.md` (imported below).
Task-specific reference is in progressively-disclosed skills under
`.claude/skills/` → `../.agents/skills/` (`otel-dashboards`, `otel-stack-ops`),
loaded on demand rather than every session.

@AGENTS.md

## Claude Code specifics

- **Worktrees:** do NOT use the built-in `EnterWorktree` tool here — its hardcoded
  default puts worktrees under `.claude/worktrees/` inside this checkout, which we
  never want. Use the Catalyst convention instead — the catalyst-dev
  create-worktree skill (→ `~/catalyst/wt/<repo>/<TICKET>`, outside the repo).

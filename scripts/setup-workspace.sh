#!/bin/bash
# setup-workspace.sh — Initialize a Conductor worktree for claude-code-otel
# Creates Claude Code project memory symlink so all worktrees share
# persistent config from ~/.config/claude-code-otel/

set -euo pipefail

CONFIG_DIR="$HOME/.config/claude-code-otel"
WORKSPACE_PATH="$(pwd)"

# Derive Claude Code's project memory path (replaces / with -)
CLAUDE_PROJECT_KEY=$(echo "$WORKSPACE_PATH" | sed 's|^/|-|' | tr '/' '-')
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/${CLAUDE_PROJECT_KEY}/memory"

# Ensure central config exists
if [ ! -d "$CONFIG_DIR" ]; then
  mkdir -p "$CONFIG_DIR"
  echo "Created $CONFIG_DIR — add deployment config files here."
fi

# Symlink Claude memory to central config
if [ -L "$CLAUDE_MEMORY_DIR" ]; then
  echo "Memory symlink already exists: $CLAUDE_MEMORY_DIR"
elif [ -d "$CLAUDE_MEMORY_DIR" ]; then
  echo "Warning: $CLAUDE_MEMORY_DIR exists as a real directory, skipping symlink."
  echo "  Remove it manually if you want shared memory: rm -rf $CLAUDE_MEMORY_DIR"
else
  mkdir -p "$(dirname "$CLAUDE_MEMORY_DIR")"
  ln -s "$CONFIG_DIR" "$CLAUDE_MEMORY_DIR"
  echo "Linked: $CLAUDE_MEMORY_DIR -> $CONFIG_DIR"
fi

# Trust workspace in Claude Code
if [ -f "$HOME/.claude/scripts/trust-workspace.sh" ]; then
  bash "$HOME/.claude/scripts/trust-workspace.sh" "$WORKSPACE_PATH"
fi

echo "Workspace ready: $WORKSPACE_PATH"

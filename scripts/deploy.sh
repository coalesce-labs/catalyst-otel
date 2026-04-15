#!/bin/bash
# deploy.sh — Deploy otel-stack to the home server
#
# Usage:
#   scripts/deploy.sh              # Deploy main (default)
#   scripts/deploy.sh test <branch> # Test a PR branch on the server
#   scripts/deploy.sh promote      # Deploy main after merging a PR
#   scripts/deploy.sh status       # Show what's running on the server
#   scripts/deploy.sh dashboards   # Push dashboards only (no git changes)
#
# Workflow:
#   1. Push changes to a branch, open a PR
#   2. scripts/deploy.sh test <branch>   — fetch + checkout on server to test
#   3. Verify at https://otel.rozich.com
#   4. Merge PR to main
#   5. scripts/deploy.sh promote         — switch server back to main

set -euo pipefail

SERVER="home"
REMOTE_DIR="/home/rozich/otel-stack"
GRAFANA_CONTAINER="otel-grafana"
CONFIG_FILES="docker-compose.yml collector-config.yaml prometheus.yml grafana-datasources.yml grafana-dashboards.yml"

cmd="${1:-deploy}"
shift 2>/dev/null || true

push_dashboards() {
  echo ""
  echo "==> Pushing dashboards via Grafana API..."
  ssh "$SERVER" "cd $REMOTE_DIR && for f in dashboards/*.json; do
    [ -f \"\$f\" ] || continue
    name=\$(basename \"\$f\")
    echo \"    \$name\"
    cat \"\$f\" | docker exec -i $GRAFANA_CONTAINER sh -c 'cat > /tmp/dash.json'
    docker exec $GRAFANA_CONTAINER curl -sf -u admin:admin -X POST \
      -H 'Content-Type: application/json' \
      'http://localhost:3000/api/dashboards/db' \
      -d @- <<PAYLOAD > /dev/null
{\\"dashboard\\": \$(docker exec $GRAFANA_CONTAINER cat /tmp/dash.json), \\"overwrite\\": true}
PAYLOAD
  done"
  echo "    Done."
}

apply_server_changes() {
  local before_sha="$1"
  local after_sha
  after_sha=$(ssh "$SERVER" "cd $REMOTE_DIR && git rev-parse HEAD")

  if [ "$before_sha" = "$after_sha" ]; then
    echo "    No changes (same commit)."
    return
  fi

  echo ""
  echo "==> Checking for service config changes ($before_sha..$after_sha)..."
  local changed
  changed=$(ssh "$SERVER" "cd $REMOTE_DIR && git diff ${before_sha}..${after_sha} --name-only -- $CONFIG_FILES 2>/dev/null || true")

  if [ -n "$changed" ]; then
    echo "    Changed: $(echo "$changed" | tr '\n' ' ')"
    echo "    Recreating containers..."
    ssh "$SERVER" "cd $REMOTE_DIR && docker compose up -d --force-recreate"
  else
    echo "    No service config changes — restarting Grafana only..."
    ssh "$SERVER" "cd $REMOTE_DIR && docker compose restart otel-grafana"
  fi

  push_dashboards
}

case "$cmd" in
  test)
    branch="${1:?Usage: deploy.sh test <branch>}"
    echo "==> Testing branch '$branch' on server..."
    before=$(ssh "$SERVER" "cd $REMOTE_DIR && git rev-parse HEAD")
    ssh "$SERVER" "cd $REMOTE_DIR && git fetch origin && git checkout '$branch' && git pull origin '$branch'"
    apply_server_changes "$before"
    echo ""
    echo "==> Server is now on branch '$branch' for testing."
    echo "    Verify at: https://otel.rozich.com"
    echo "    When done: merge PR, then run: scripts/deploy.sh promote"
    ssh "$SERVER" "cd $REMOTE_DIR && git log --oneline -1"
    ;;

  promote|deploy)
    echo "==> Deploying main to server..."
    before=$(ssh "$SERVER" "cd $REMOTE_DIR && git rev-parse HEAD")
    ssh "$SERVER" "cd $REMOTE_DIR && git fetch origin && git checkout main && git pull origin main"
    apply_server_changes "$before"
    echo ""
    echo "==> Deploy complete — server is on main."
    ssh "$SERVER" "cd $REMOTE_DIR && git log --oneline -1"
    ;;

  status)
    echo "==> Server status:"
    ssh "$SERVER" "cd $REMOTE_DIR && echo \"Branch: \$(git branch --show-current)\" && echo \"Commit: \$(git log --oneline -1)\" && echo '' && docker compose ps"
    ;;

  dashboards)
    push_dashboards
    ;;

  *)
    echo "Usage: scripts/deploy.sh [test <branch> | promote | status | dashboards]"
    exit 1
    ;;
esac

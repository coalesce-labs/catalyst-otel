#!/bin/bash
# deploy.sh — Pull latest from main and reload dashboards on the home server
# Usage: bash scripts/deploy.sh
#   Runs via SSH to the home server, pulls latest code, restarts services
#   if config files changed, and pushes all dashboards via the Grafana API
#   (bypassing the provisioner cache).

set -euo pipefail

SERVER="home"
REMOTE_DIR="/home/rozich/otel-stack"
GRAFANA_CONTAINER="otel-grafana"

echo "==> Pulling latest from origin/main..."
ssh "$SERVER" "cd $REMOTE_DIR && git pull origin main"

echo ""
echo "==> Checking if service configs changed..."
CHANGED=$(ssh "$SERVER" "cd $REMOTE_DIR && git diff HEAD~1 --name-only -- docker-compose.yml collector-config.yaml prometheus.yml grafana-datasources.yml grafana-dashboards.yml 2>/dev/null || true")

if [ -n "$CHANGED" ]; then
  echo "    Config files changed: $CHANGED"
  echo "    Restarting docker compose..."
  ssh "$SERVER" "cd $REMOTE_DIR && docker compose up -d"
else
  echo "    No service config changes — skipping restart."
fi

echo ""
echo "==> Pushing dashboards to Grafana API..."

# Push each dashboard JSON via the Grafana API
# This bypasses the file provisioner cache issue
ssh "$SERVER" "cd $REMOTE_DIR && for f in claude-code-dashboard.json dashboards/*.json; do
  [ -f \"\$f\" ] || continue
  name=\$(basename \"\$f\")
  echo \"    Pushing \$name...\"
  cat \"\$f\" | docker exec -i $GRAFANA_CONTAINER sh -c 'cat > /tmp/dash.json'
  docker exec $GRAFANA_CONTAINER curl -sf -u admin:admin -X POST \
    -H 'Content-Type: application/json' \
    'http://localhost:3000/api/dashboards/db' \
    -d @- <<PAYLOAD > /dev/null
{\"dashboard\": \$(docker exec $GRAFANA_CONTAINER cat /tmp/dash.json), \"overwrite\": true}
PAYLOAD
  echo \"    done.\"
done"

echo ""
echo "==> Deploy complete."
ssh "$SERVER" "cd $REMOTE_DIR && git log --oneline -1"

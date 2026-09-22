#!/bin/sh
# Push the laptop replica writer's freshness to the status page (CTC-3005, CTC-3008).
# Read-only: it stats the writer's lock file and reports. It never starts, stops or touches the writer.
# Run every 60 s by launchd (ai.coalesce.catalyst-status-replica-heartbeat.plist).
#
# Env: STATUS_URL (default http://100.90.80.62:8094), REPLICA_PUSH_TOKEN (required),
#      REPLICA_LOCK (default ~/.config/catalyst-cloud/replica.db.writer.lock), STALE_S (default 300).
set -u
STATUS_URL=${STATUS_URL:-http://100.90.80.62:8094}
LOCK=${REPLICA_LOCK:-$HOME/.config/catalyst-cloud/replica.db.writer.lock}
STALE_S=${STALE_S:-300}
: "${REPLICA_PUSH_TOKEN:?set REPLICA_PUSH_TOKEN}"

if [ ! -f "$LOCK" ]; then
  success=false; err="writer+lock+missing:+no+replica+writer+is+running"
else
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK") ))
  if [ "$age" -gt "$STALE_S" ]; then
    success=false; err="writer+lock+is+${age}s+old"
  else
    success=true; err=""
  fi
fi

q="success=${success}"
[ -n "$err" ] && q="${q}&error=${err}"
curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
  -H "Authorization: Bearer ${REPLICA_PUSH_TOKEN}" \
  "${STATUS_URL}/api/v1/endpoints/5-replica_laptop-writer/external?${q}"

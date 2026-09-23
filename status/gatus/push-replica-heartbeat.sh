#!/bin/sh
# Push the laptop replica writer's freshness to the status page (CTC-3005, CTC-3008).
# Read-only: it stats the writer's lock file and reports. It never starts, stops or touches the writer.
# Run every 60 s by launchd (ai.coalesce.catalyst-status-replica-heartbeat.plist).
#
# The page is reached through the Cloudflare Tunnel mini-status, behind Cloudflare Access, so the push
# carries the Access service token ops-status-heartbeat as well as Gatus's own bearer token.
#
# Env: STATUS_URL (default https://ops-status.catalystcloud.dev), REPLICA_PUSH_TOKEN (required),
#      CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET (required),
#      REPLICA_LOCK (default ~/.config/catalyst-cloud/replica.db.writer.lock), STALE_S (default 300).
set -u
STATUS_URL=${STATUS_URL:-https://ops-status.catalystcloud.dev}
LOCK=${REPLICA_LOCK:-$HOME/.config/catalyst-cloud/replica.db.writer.lock}
STALE_S=${STALE_S:-300}
: "${REPLICA_PUSH_TOKEN:?set REPLICA_PUSH_TOKEN}"
: "${CF_ACCESS_CLIENT_ID:?set CF_ACCESS_CLIENT_ID}"
: "${CF_ACCESS_CLIENT_SECRET:?set CF_ACCESS_CLIENT_SECRET}"

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
  -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
  -H "Authorization: Bearer ${REPLICA_PUSH_TOKEN}" \
  "${STATUS_URL}/api/v1/endpoints/5-replica_laptop-writer/external?${q}"

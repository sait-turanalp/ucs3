#!/bin/bash
# Build and roll out the site. The only supported way to deploy.
#
# Rollback is automatic: the running image is kept as ucs-web:previous, and if
# the new one does not become healthy within the timeout we put the old one
# back. A bad release costs a minute, not a night.
set -euo pipefail

OPS_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${OPS_DIR}/docker-compose.yml"
NOTIFY="${OPS_DIR}/notify.sh"
HEALTH_TIMEOUT=120

set -a
# shellcheck disable=SC1091
. /etc/ucs/ucs.env
set +a

# Keep the currently running image as the rollback target.
if docker image inspect ucs-web:current >/dev/null 2>&1; then
  docker tag ucs-web:current ucs-web:previous
  echo "rollback target saved: ucs-web:previous"
fi

echo "building..."
$COMPOSE build

echo "starting..."
$COMPOSE up -d --force-recreate

# Wait for the container's own healthcheck, not for a fixed sleep.
deadline=$((SECONDS + HEALTH_TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  state=$(docker inspect -f '{{.State.Health.Status}}' ucs-web 2>/dev/null || echo "missing")
  case "$state" in
    healthy)
      echo "OK: healthy in ${SECONDS}s"
      "$NOTIFY" "Site yayinda" "Yeni surum ${SECONDS} saniyede ayaga kalkti." "rocket" || true
      exit 0
      ;;
    unhealthy)
      break
      ;;
  esac
  sleep 3
done

echo "FAILED: new version did not become healthy — rolling back" >&2
if docker image inspect ucs-web:previous >/dev/null 2>&1; then
  docker tag ucs-web:previous ucs-web:current
  $COMPOSE up -d --force-recreate
  "$NOTIFY" "Surum geri alindi" "Yeni surum acilmadi, eski calisan surume donuldu. Site ayakta." "warning" "high" || true
else
  "$NOTIFY" "Deploy basarisiz" "Yeni surum acilmadi ve geri donulecek eski surum yok. Mudahale gerek." "rotating_light" "urgent" || true
fi
exit 1

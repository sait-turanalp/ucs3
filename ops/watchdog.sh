#!/bin/bash
# Site-level watchdog: checks the real public URL once a minute.
#
# The container restarts itself when the process dies; this layer catches the
# cases it cannot see — a wedged process that still holds the port, a broken
# proxy, a half-started container. Two consecutive misses before acting, so a
# single slow response never triggers a restart.
set -uo pipefail

URL="https://ucscogroup.com/"
OPS_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${OPS_DIR}/docker-compose.yml"
NOTIFY="${OPS_DIR}/notify.sh"

STATE_DIR=/var/lib/ucs
FAIL_FILE="${STATE_DIR}/watchdog.fails"
DOWN_SINCE="${STATE_DIR}/watchdog.down-since"
MUTE_FILE="${STATE_DIR}/watchdog.muted-until"
MUTE_SECONDS=1800

mkdir -p "$STATE_DIR"

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$URL" 2>/dev/null || echo 000)
fails=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)

if [ "$code" = "200" ]; then
  # Recovered: report how long it was actually down, then reset.
  if [ -f "$DOWN_SINCE" ]; then
    down_start=$(cat "$DOWN_SINCE")
    secs=$(( $(date +%s) - down_start ))
    "$NOTIFY" "Site geri geldi" "Site ${secs} saniye cevap vermedi, kendiliginden toparlandi." "white_check_mark" || true
    rm -f "$DOWN_SINCE" "$MUTE_FILE"
  fi
  echo 0 > "$FAIL_FILE"
  exit 0
fi

fails=$((fails + 1))
echo "$fails" > "$FAIL_FILE"
[ -f "$DOWN_SINCE" ] || date +%s > "$DOWN_SINCE"

# One miss can be a hiccup. Act on the second.
[ "$fails" -lt 2 ] && exit 0

echo "site down (HTTP ${code}), recreating container"
$COMPOSE up -d --force-recreate >/dev/null 2>&1

# Same problem, at most one message every 30 minutes.
now=$(date +%s)
muted_until=$(cat "$MUTE_FILE" 2>/dev/null || echo 0)
if [ "$now" -ge "$muted_until" ]; then
  "$NOTIFY" "Site cevap vermiyor" "HTTP ${code} alindi, site yeniden baslatildi. Geri gelince haber verecegim." "rotating_light" "high" || true
  echo $((now + MUTE_SECONDS)) > "$MUTE_FILE"
fi
exit 0

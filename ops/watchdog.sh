#!/bin/bash
# Site-level watchdog: checks the real public URL once a minute.
#
# The container restarts itself when the process dies; this layer catches what
# it cannot see — a wedged process that still holds the port, a broken proxy, a
# half-started container. Two consecutive misses before acting, so one slow
# response never triggers a restart.
set -uo pipefail

URL="https://ucscogroup.com/"
OPS_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${OPS_DIR}/docker-compose.yml"
NOTIFY="${OPS_DIR}/notify.sh"

STATE_DIR=/var/lib/ucs
FAIL_FILE="${STATE_DIR}/watchdog.fails"
DOWN_SINCE="${STATE_DIR}/watchdog.down-since"

mkdir -p "$STATE_DIR"

# One compose operation at a time. The command listener (the restart button on
# the phone) also runs compose, and during a manual restart containers briefly
# look missing. Without this lock the watchdog reads that as a crash and starts
# a second compose run — measured on the CMR host: the two raced, the stack
# broke, a service vanished, and a false alarm went out on top of it.
# A round that cannot take the lock skips silently and looks again in a minute.
exec 9>/var/lock/ucs-ops.lock
flock -n 9 || exit 0

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$URL" 2>/dev/null || echo 000)
fails=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)

if [ "$code" = "200" ]; then
  # Recovered: say how long it was actually down, in plain words, then reset.
  if [ -f "$DOWN_SINCE" ]; then
    secs=$(( $(date +%s) - $(cat "$DOWN_SINCE") ))
    sh "$NOTIFY" "Site geri geldi" \
       "Site ${secs} saniye cevap vermedi, kendiliğinden toparlandı." \
       "default" "white_check_mark"
    rm -f "$DOWN_SINCE"
  fi
  echo 0 > "$FAIL_FILE"
  exit 0
fi

fails=$((fails + 1))
echo "$fails" > "$FAIL_FILE"
[ -f "$DOWN_SINCE" ] || date +%s > "$DOWN_SINCE"

# One miss can be a hiccup. Act on the second.
[ "$fails" -lt 2 ] && exit 0

$COMPOSE up -d --force-recreate --remove-orphans >/dev/null 2>&1

# The buttons ride along: if the automatic recovery is not enough, the next step
# is one tap away instead of a laptop and an SSH session.
sh "$NOTIFY" "Site cevap vermiyor" \
   "Site ${fails} turdur cevap vermiyor (HTTP ${code}). Kendim yeniden başlattım.
Geri gelince haber vereceğim. Gelmezse aşağıdaki butonlar duruyor." \
   "urgent" "rotating_light" "site-down" "ops"
exit 0

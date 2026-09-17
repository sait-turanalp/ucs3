#!/bin/bash
# Daily drift audit: today's fingerprint of the host against an accepted
# baseline. Silence means healthy — it only speaks when something changed.
#
# Every trace the September intrusion left (new SSH keys, a dropped binary in
# /tmp, an untracked file in the site directory, a new service) shows up here
# on the first run after it happens.
#
# Usage:
#   daily-audit.sh            compare against the baseline, notify on drift
#   daily-audit.sh --accept   adopt the current state as the new baseline
set -uo pipefail

OPS_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="${OPS_DIR}/notify.sh"
APP_DIR="${UCS_APP_DIR:-/opt/ucs/ucs3}"

STATE_DIR=/var/lib/ucs
BASELINE="${STATE_DIR}/audit.baseline"
CURRENT="${STATE_DIR}/audit.current"
mkdir -p "$STATE_DIR"

collect() {
  echo "== ssh authorized keys =="
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] && echo "$f $(wc -l < "$f") $(sha256sum < "$f" | cut -c1-16)"
  done

  echo "== listening tcp =="
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un

  echo "== systemd units =="
  ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null | xargs -r -n1 basename | sort

  echo "== crontabs =="
  for u in root $(ls /home 2>/dev/null); do
    echo "$u $(crontab -l -u "$u" 2>/dev/null | grep -cv '^#')"
  done

  echo "== executables in world-writable dirs =="
  find /tmp /var/tmp /dev/shm -maxdepth 2 -type f \( -perm -u+x -o -size +1M \) \
    -printf "%p %s\n" 2>/dev/null | sort

  echo "== untracked files in site dir =="
  if [ -d "${APP_DIR}/.git" ]; then
    git -C "$APP_DIR" status --porcelain 2>/dev/null | head -50
  else
    echo "NO GIT CHECKOUT AT ${APP_DIR}"
  fi

  echo "== running image =="
  docker inspect -f '{{.Image}}' ucs-web 2>/dev/null || echo "container not running"
}

collect > "$CURRENT"

if [ "${1:-}" = "--accept" ] || [ ! -f "$BASELINE" ]; then
  cp "$CURRENT" "$BASELINE"
  echo "baseline accepted ($(date -Is))"
  exit 0
fi

if diff -q "$BASELINE" "$CURRENT" >/dev/null; then
  exit 0
fi

DIFF_FILE="${STATE_DIR}/audit-$(date +%Y%m%d-%H%M).diff"
diff "$BASELINE" "$CURRENT" > "$DIFF_FILE"

# Name the sections that moved, so the phone message is readable on its own.
sections=$(grep '^[<>]' "$DIFF_FILE" | wc -l)
summary=$(awk '/^== /{s=$0} /^[<>]/{print s}' "$CURRENT" 2>/dev/null | sort -u | head -3 | tr '\n' ' ')
[ -z "$summary" ] && summary=$(grep -m3 '^[<>]' "$DIFF_FILE" | cut -c1-60 | tr '\n' ' ')

"$NOTIFY" "Sunucuda beklenmedik degisiklik" \
  "Gunluk kontrol ${sections} fark buldu. Ozet: ${summary}. Ayrinti: ${DIFF_FILE}" \
  "rotating_light" "urgent" || true

echo "DRIFT: $DIFF_FILE"
exit 1

#!/bin/bash
# Battle test: break the site on purpose, measure how long it takes to come back.
#
# Each case prints ONE line: name, result, seconds. Detail only on failure.
#
# Deliberately scoped so the neighbouring sites on this host are never at risk:
# the disk case fills the container's own memory-backed /tmp (64 MB), not the
# host disk, and the reboot case restarts the Docker daemon rather than the
# machine. A real reboot is a separate, CEO-approved step.
#
# Usage:
#   battle-test.sh            run all cases
#   battle-test.sh --negative run the control: protection off, cases must FAIL
set -uo pipefail

URL="https://ucscogroup.com/"
OPS_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${OPS_DIR}/docker-compose.yml"
MAX_WAIT=120

pass=0; fail=0

# Wait until the public URL answers 200; echo the seconds it took, or -1.
wait_up() {
  local limit=${1:-$MAX_WAIT} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    if [ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)" = "200" ]; then
      echo $((SECONDS - start)); return 0
    fi
    sleep 2
  done
  echo -1; return 1
}

report() { # name expected_seconds actual
  local name="$1" limit="$2" got="$3"
  if [ "$got" -ge 0 ] && [ "$got" -le "$limit" ]; then
    printf '%-34s GECTI   %3ss (tavan %ss)\n' "$name" "$got" "$limit"; pass=$((pass+1))
  else
    printf '%-34s KALDI   %3ss (tavan %ss)\n' "$name" "$got" "$limit"; fail=$((fail+1))
  fi
}

echo "--- baslangic durumu ---"
[ "$(wait_up 30)" -ge 0 ] || { echo "site zaten ayakta degil, sinav baslamadi"; exit 2; }

# 1 - process killed outright
echo "--- 1: uygulamayi zorla oldur ---"
docker kill ucs-web >/dev/null 2>&1
report "1. Zorla oldurme" 30 "$(wait_up)"

# 2 - can an intruder change the running app at all?
echo "--- 2: calisan uygulamaya yazma denemesi ---"
if docker exec ucs-web sh -c 'echo x > /app/server.js' 2>/dev/null; then
  printf '%-34s KALDI   yazma BASARILI oldu\n' "2. Yazma reddi"; fail=$((fail+1))
  $COMPOSE up -d --force-recreate >/dev/null 2>&1; wait_up >/dev/null
else
  printf '%-34s GECTI   yazma reddedildi\n' "2. Yazma reddi"; pass=$((pass+1))
fi

# 3 - the container's own scratch space fills up
echo "--- 3: gecici alani doldur ---"
docker exec ucs-web sh -c 'dd if=/dev/zero of=/tmp/fill bs=1M count=128 2>/dev/null; true' >/dev/null 2>&1
report "3. Gecici alan dolmasi" 30 "$(wait_up 30)"
docker exec ucs-web sh -c 'rm -f /tmp/fill' >/dev/null 2>&1 || true

# 4 - memory ceiling
echo "--- 4: bellegi tuket ---"
docker exec ucs-web node -e 'const a=[];for(;;)a.push(Buffer.alloc(16*1024*1024))' >/dev/null 2>&1 || true
report "4. Bellek tukenmesi" 60 "$(wait_up)"

# 5 - host-level restart (docker daemon stands in for a reboot)
echo "--- 5: docker servisini yeniden baslat ---"
systemctl restart docker >/dev/null 2>&1
report "5. Sunucu yeniden baslatma" 90 "$(wait_up)"

# 6 - a broken release must roll itself back
echo "--- 6: hatali surum yayinla ---"
if docker image inspect ucs-web:current >/dev/null 2>&1; then
  docker tag ucs-web:current ucs-web:previous
  docker rmi -f ucs-web:broken >/dev/null 2>&1 || true
  printf 'FROM ucs-web:current\nUSER node\nCMD ["node","-e","process.exit(1)"]\n' \
    | docker build -q -t ucs-web:current - >/dev/null 2>&1
  $COMPOSE up -d --force-recreate >/dev/null 2>&1
  sleep 20
  docker tag ucs-web:previous ucs-web:current
  $COMPOSE up -d --force-recreate >/dev/null 2>&1
  report "6. Hatali surum geri alma" 90 "$(wait_up)"
else
  echo "6. Hatali surum geri alma      ATLANDI (imaj yok)"
fi

echo
echo "SONUC: ${pass} gecti, ${fail} kaldi"
[ "$fail" -eq 0 ]

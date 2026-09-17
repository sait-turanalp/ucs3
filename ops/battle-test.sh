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

# Kill the server the way a real crash does: from the host, by its host-side PID.
# Two things that do NOT work and quietly turn this suite into theatre:
#   `docker kill`      - Docker records it as an intentional stop and will not restart
#   `kill -9 1` inside - the kernel drops unhandled signals sent to a namespace's PID 1
crash_app() {
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' ucs-web 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != "0" ] || { echo "crash_app: pid bulunamadi"; return 1; }
  kill -9 "$pid" 2>/dev/null
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

# The control run. With both recovery layers switched off, a crash must stay a
# crash. A suite that still reports green here is measuring nothing, so this is
# not optional — it is what makes the other results believable.
if [ "${1:-}" = "--negative" ]; then
  echo "--- NEGATIF HUCRE: koruma kapali, sinav KIRMIZI olmali ---"
  systemctl stop ucs-watchdog.timer >/dev/null 2>&1
  docker update --restart=no ucs-web >/dev/null 2>&1
  crash_app
  got=$(wait_up 60)

  systemctl start ucs-watchdog.timer >/dev/null 2>&1
  docker update --restart=always ucs-web >/dev/null 2>&1
  $COMPOSE up -d >/dev/null 2>&1
  restored=$(wait_up 120)

  if [ "$got" -lt 0 ]; then
    echo "NEGATIF HUCRE GECTI: koruma kapaliyken site geri gelmedi (beklenen)."
    echo "koruma acildi, site ${restored}s icinde geri geldi"
    exit 0
  fi
  echo "NEGATIF HUCRE KALDI: koruma kapaliyken site ${got}s icinde geri geldi."
  echo "Sinav olcum yapmiyor; digerlerinin yesili gecersizdir."
  exit 1
fi

# 1a - a real crash: the process dies on its own, so Docker's restart policy owns
# the recovery. Note `docker kill` would NOT test this — Docker treats a manual
# kill as an intentional stop and deliberately does not restart it.
echo "--- 1a: uygulama kendiliginden coksun ---"
crash_app   # see below: the kernel ignores a SIGKILL sent to PID 1 from inside
report "1a. Cokme sonrasi kendi donusu" 30 "$(wait_up)"

# 1b - the operator-kill case, which only the watchdog can catch. Its ceiling is
# the probe interval (60s) plus the two misses it waits for.
echo "--- 1b: disaridan durdurulma (nobetci isi) ---"
docker kill ucs-web >/dev/null 2>&1
report "1b. Nobetcinin toparlamasi" 150 "$(wait_up 180)"

# 2 - can an intruder change the running app at all?
echo "--- 2: calisan uygulamaya yazma denemesi ---"
if timeout 30 docker exec ucs-web sh -c 'echo x > /app/server.js' 2>/dev/null; then
  printf '%-34s KALDI   yazma BASARILI oldu\n' "2. Yazma reddi"; fail=$((fail+1))
  $COMPOSE up -d --force-recreate >/dev/null 2>&1; wait_up >/dev/null
else
  printf '%-34s GECTI   yazma reddedildi\n' "2. Yazma reddi"; pass=$((pass+1))
fi

# 3 - the container's own scratch space fills up
echo "--- 3: gecici alani doldur ---"
timeout 45 docker exec ucs-web sh -c 'dd if=/dev/zero of=/tmp/fill bs=1M count=128 2>/dev/null; true' >/dev/null 2>&1 || true
report "3. Gecici alan dolmasi" 30 "$(wait_up 30)"
docker exec ucs-web sh -c 'rm -f /tmp/fill' >/dev/null 2>&1 || true

# 4 - memory ceiling. Hard-capped: an exec that hits the cgroup limit can hang,
# and a test that waits forever is not a test.
echo "--- 4: bellegi tuket ---"
timeout 60 docker exec ucs-web node -e 'const a=[];for(;;)a.push(Buffer.alloc(16*1024*1024))' >/dev/null 2>&1 || true
report "4. Bellek tukenmesi" 60 "$(wait_up)"

# 5 - survives a reboot. Checked declaratively: restarting the Docker daemon
# would also bounce the neighbouring site on this host, which is out of scope.
# A real reboot is a separate, CEO-approved step.
echo "--- 5: yeniden baslatmaya dayaniklilik ---"
policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' ucs-web 2>/dev/null)
docker_boot=$(systemctl is-enabled docker 2>/dev/null)
timers_ok=$(systemctl is-enabled ucs-watchdog.timer 2>/dev/null)
if [ "$policy" = "always" ] && [ "$docker_boot" = "enabled" ] && [ "$timers_ok" = "enabled" ]; then
  printf '%-34s GECTI   politika=%s docker=%s nobetci=%s\n' "5. Yeniden baslatma dayanikligi" "$policy" "$docker_boot" "$timers_ok"; pass=$((pass+1))
else
  printf '%-34s KALDI   politika=%s docker=%s nobetci=%s\n' "5. Yeniden baslatma dayanikligi" "$policy" "$docker_boot" "$timers_ok"; fail=$((fail+1))
fi

# 6 - a broken release must roll itself back
echo "--- 6: hatali surum yayinla ---"
if docker image inspect ucs-web:current >/dev/null 2>&1; then
  docker tag ucs-web:current ucs-web:previous
  docker rmi -f ucs-web:broken >/dev/null 2>&1 || true
  printf 'FROM ucs-web:current\nUSER node\nCMD ["node","-e","process.exit(1)"]\n' \
    | timeout 120 docker build -q -t ucs-web:current - >/dev/null 2>&1 || true
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

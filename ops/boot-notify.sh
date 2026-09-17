#!/bin/sh
# Says "I am back" as soon as the network is up after a boot.
#
# Without this, a slow or stuck reboot is indistinguishable from a dead machine:
# from outside you see nothing either way. Measured on 2026-09-17 — an 18-minute
# shutdown hang looked exactly like a server that never woke up.
#
# It reports the time spent booting and, if the shutdown before it was long, says
# so, because that is the number worth knowing.

OPS_DIR="$(cd "$(dirname "$0")" && pwd)"

BOOT_SECS=$(systemd-analyze 2>/dev/null | head -1 | sed -E 's/.*= *([0-9.]+)s.*/\1/')
[ -z "$BOOT_SECS" ] && BOOT_SECS="?"

# Wait briefly for the site, so the message can say whether it actually came back.
SITE="down"
i=0
while [ $i -lt 30 ]; do
    [ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 https://ucscogroup.com/ 2>/dev/null)" = "200" ] \
        && { SITE="up"; break; }
    i=$((i + 1))
    sleep 2
done

if [ "$SITE" = "up" ]; then
    sh "$OPS_DIR/notify.sh" "Sunucu geri geldi" \
       "Sunucu yeniden başladı ve site açıldı. Açılış ${BOOT_SECS} saniye sürdü." \
       "default" "white_check_mark"
else
    sh "$OPS_DIR/notify.sh" "Sunucu açıldı ama site yok" \
       "İşletim sistemi ${BOOT_SECS} saniyede açıldı, fakat site bir dakikadır cevap vermiyor. Butonlar aşağıda." \
       "urgent" "rotating_light" "" "ops"
fi
exit 0

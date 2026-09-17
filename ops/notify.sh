#!/bin/sh
# ntfy.sh notification. No account, no token.
#
# Usage: notify.sh <title> <body> [priority] [tags] [mute-key] [ops]
#
# A last argument of "ops" attaches the "Yeniden başlat" and "Sunucuyu resetle"
# buttons. Use it ONLY on problem messages — a reset button sitting on a healthy
# notification is an accidental-tap waiting to happen.
#
# Design decisions, all of them paid for on the CMR host:
# - The lock screen shows little beyond the first few words, so the TITLE has to
#   stand alone. The body is a short detail.
# - No "Click" header, so tapping opens the ntfy app on the message detail where
#   the buttons and full text live. Visiting the site has its own button.
# - Titles and button labels are RFC 2047 (base64) encoded: HTTP headers do not
#   carry raw UTF-8 reliably, and without this Turkish characters arrive as "?".
#   The body (-d) is fine as raw UTF-8.
# - No markdown: ntfy renders it in the web app only, so on iOS and Android the
#   **asterisks** show up literally.
# - Mute: one message per problem per 30 minutes. Without it a flapping service
#   bombards the phone every minute.
# - Command buttons publish to a SEPARATE, secret topic with "Cache: no", so the
#   command is not stored and cannot be replayed later. If the alert topic ever
#   leaks, nobody can restart the server with it.

ENV_FILE="${UCS_ENV:-/etc/ucs/ucs.env}"
if [ -f "$ENV_FILE" ]; then
    NTFY_TOPIC=$(grep -E '^NTFY_TOPIC=' "$ENV_FILE" | cut -d= -f2-)
    NTFY_CMD_TOPIC=$(grep -E '^NTFY_CMD_TOPIC=' "$ENV_FILE" | cut -d= -f2-)
fi
[ -z "$NTFY_TOPIC" ] && exit 0

SITE="${PUBLIC_URL:-https://ucscogroup.com}"
TITLE="${1:-UCS}"
BODY="${2:-}"
PRIO="${3:-default}"
TAGS="${4:-}"
MUTE_KEY="${5:-}"
OPS="${6:-}"

if [ -n "$MUTE_KEY" ]; then
    STAMP="/tmp/.ucs-notify-$(echo "$MUTE_KEY" | tr -c 'a-zA-Z0-9' '_')"
    if [ -f "$STAMP" ]; then
        AGE=$(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) ))
        [ "$AGE" -lt 1800 ] && exit 0
    fi
    touch "$STAMP"
fi

enc() { printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"; }

# Three buttons side by side wrap badly on a phone, and "open the site" is the
# least useful button on a message that says the site is down. Two, then.
if [ "$OPS" = "ops" ] && [ -n "$NTFY_CMD_TOPIC" ]; then
    CMD_URL="https://ntfy.sh/$NTFY_CMD_TOPIC"
    ACTIONS="http, Yeniden başlat, $CMD_URL, body=restart, headers.Cache=no, clear=true"
    ACTIONS="$ACTIONS; http, Sunucuyu resetle, $CMD_URL, body=reboot, headers.Cache=no, clear=true"
else
    ACTIONS="view, Siteyi aç, $SITE, clear=true"
fi

curl -fsS --max-time 8 \
     -H "Title: $(enc "$TITLE")" \
     -H "Priority: $PRIO" \
     ${TAGS:+-H "Tags: $TAGS"} \
     -H "Actions: $(enc "$ACTIONS")" \
     -d "$BODY" \
     "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
exit 0

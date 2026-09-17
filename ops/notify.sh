#!/bin/sh
# Push a one-line notification to the phone via ntfy.
# Usage: notify.sh "Title" "body" [tags] [priority]
# Titles stay ASCII on purpose: HTTP headers mangle non-ASCII on some clients.
# Sending never blocks the caller and never fails the caller.

[ -f /etc/ucs/ucs.env ] && . /etc/ucs/ucs.env

[ -z "${NTFY_TOPIC:-}" ] && exit 0

curl --max-time 8 -fsS \
  -H "Title: $1" \
  -H "Tags: ${3:-warning}" \
  -H "Priority: ${4:-default}" \
  -d "$2" \
  "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 || true

exit 0

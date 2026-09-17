# ucs3 — ucscogroup.com

Next.js 15 App Router marketing site for UCS Group (agriculture export/import),
served from a hardened container on a single VPS behind nginx.

## Where things live

| What | Where |
|---|---|
| Server | `31.42.127.172`, root over SSH key (`sait@vastai`) |
| Deployed checkout | `/opt/ucs/ucs3` — synced from this repo, must stay git-clean |
| Secrets | `/etc/ucs/ucs.env` (mode 600, root) — **never** in the repo or the app dir |
| Container | `ucs-web`, published on `127.0.0.1:3002`, nginx proxies to it |
| nginx vhost | `/etc/nginx/sites-enabled/ucscogroup.com.conf` |
| Watchdog / audit state | `/var/lib/ucs/` |
| Quarantined intrusion artifacts | `/root/quarantine-2026-09-17/` |

Page structure, component inventory and asset map: see `AGENTS.md`.

External dependencies: self-hosted Supabase (gallery + admin auth) and BunnyCDN
(images, with `/public` fallbacks). Mapbox powers the operation map.

## Operating it

```
ops/deploy.sh        build + roll out; auto-rolls back if the new image is unhealthy
ops/watchdog.sh      one probe of the public URL (systemd timer runs it every minute)
ops/daily-audit.sh   host drift report; --accept adopts the current state as baseline
ops/battle-test.sh   break it six ways and measure recovery; --negative is the control
```

Deploying is `rsync` of a clean checkout to `/opt/ucs/ucs3`, then `ops/deploy.sh`.
Never edit files directly on the server: `daily-audit.sh` reports any untracked
file under the deployed checkout, and an edit there is indistinguishable from an
intrusion.

## Foot-guns (each one cost us real time)

- **`docker kill` does not test the restart policy.** Docker records a manual kill
  as an intentional stop and deliberately will not restart the container. Only the
  watchdog catches that case. To simulate a real crash, kill the container's
  host-side PID (`ops/battle-test.sh:crash_app`).
- **`kill -9 1` inside a container is a no-op.** The kernel drops unhandled signals
  sent to a PID namespace's init. A test built on it reports green while testing
  nothing — this is exactly what the negative control caught.
- **The build needs `SUPABASE_SERVICE_ROLE_KEY` to exist.** `src/lib/authOptions.ts`
  creates the Supabase client at module scope, so page-data collection fails without
  it. The Dockerfile passes a placeholder on purpose; the real value arrives at run
  time from `/etc/ucs/ucs.env` and must never be baked into an image layer.
- **`NEXT_PUBLIC_*` values are inlined at build time.** Changing one means rebuilding
  the image, not just restarting the container.
- **Never trust the copy of this app that is on the server.** In 2026-09 it held four
  PHP webshells and a full XMRig tree. Rebuild from git, always.
- **Secrets used to be committed** (`.env.production`, `env.local`). They are untracked
  now and every value was rotated, but the old values remain in git history.
- **Do not add a second process manager.** A leftover pm2 setup and a `ucs-healthcheck`
  timer from an earlier cleanup kept resurrecting a dead systemd unit. One owner:
  compose for the container, one systemd timer for the watchdog.

## The 2026-09 intrusion, in one paragraph

Next.js 15.5.4 with React 19.0.0 is vulnerable to unauthenticated RCE through React
Server Components (CVE-2025-55182). Attackers had been in since at least 2026-07-05
(webshells dated Jul 5, Jul 16, Jul 20, Aug 5). On 2026-09-14 15:50 one of them
truncated the Node binary to zero bytes, at 16:37 planted 53 SSH keys in
`ucscogroup`'s `authorized_keys`, and dropped a miner into `/tmp`. The site 502'd
from 19:38 and systemd crash-looped 120 times because the binary it was told to
execute no longer existed. Patched runtime + read-only container + drift audit close
all three: the hole, the persistence, and the blindness.

## Verification matrix

| Claim | Command | Green means |
|---|---|---|
| Site serves | `curl -o /dev/null -w '%{http_code}' https://ucscogroup.com/` | `200` |
| Container healthy | `docker ps --filter name=ucs-web` | `(healthy)` |
| Recovers from a crash | `ops/battle-test.sh` | `SONUC: 7 gecti, 0 kaldi` |
| The suite actually measures | `ops/battle-test.sh --negative` | `NEGATIF HUCRE GECTI` |
| Host unchanged | `ops/daily-audit.sh` | exit 0, no output |
| No secret is tracked | `git ls-files \| grep -iE '^\.?env'` | empty |

A green battle test without a green negative control is not evidence.

## Resume protocol

1. `docker ps --filter name=ucs-web` and `curl` the site — is it actually up?
2. `ops/daily-audit.sh` — did anything on the host move?
3. `git -C /opt/ucs/ucs3 status --porcelain` — is the deployed checkout still clean?
4. Open items live in `docs/plans/` and in the session's plan file.

## Open items

- **Gallery is broken, and it was broken before the intrusion.** The self-hosted
  Supabase at `dbapi.we3design.net` resolves to `178.208.187.74`, the decommissioned
  old VPS, and its TLS handshake fails. `/api/gallery` returns 500 until that backend
  is moved or repointed.
- **Supabase and Mapbox keys are still the pre-intrusion ones.** Only `NEXTAUTH_SECRET`
  could be rotated locally; the other two need access to their own consoles.
- **swiper has an unpatched critical advisory** (prototype pollution). The fix is a
  major upgrade (11 → 14) that would churn the hero and gallery sliders, so it was
  deliberately deferred rather than rushed during an incident.
- Neighbouring sites on this host (`cmr`, `millersan`) were explicitly left untouched
  and have not been checked for the same compromise.

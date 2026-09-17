# syntax=docker/dockerfile:1
# Hardened image for ucscogroup.com.
# The runtime layer carries only the standalone server: no package manager,
# no build toolchain, non-root user, and a read-only filesystem at run time
# (enforced by compose). Nothing an intruder writes can survive a restart.

FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .

# NEXT_PUBLIC_* values are inlined at build time, so they must be present here.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN
ARG NEXT_PUBLIC_CDN_URL
ENV NEXT_TELEMETRY_DISABLED=1

# Page-data collection instantiates the Supabase client at module scope
# (src/lib/authOptions.ts), so the build needs *a* value. It is a placeholder on
# purpose: the real key must never end up in an image layer. At run time the
# module is evaluated again with the value from /etc/ucs/ucs.env.
ENV SUPABASE_SERVICE_ROLE_KEY=placeholder-build-only

RUN npm run build


FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static
COPY --from=builder --chown=node:node /app/public ./public

USER node
EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --start-period=25s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/ >/dev/null 2>&1 || exit 1

CMD ["node", "server.js"]

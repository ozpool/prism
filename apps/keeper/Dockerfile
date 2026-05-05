# PRISM keeper — production image.
#
# Two-stage build:
#   1. deps stage — installs pnpm + the workspace deps once, layer-cached
#      across rebuilds when only source changes.
#   2. runtime stage — minimal node:alpine with the built JS, runs the
#      keeper as a non-root user with a TINI init wrapper for proper
#      SIGTERM forwarding.
#
# Health probe: /health on $HEALTH_PORT (default 8080). The endpoint
# reports 503 until the first cycle completes, so a freshly-started
# container that can't reach the RPC fails the first probe and gets
# rescheduled rather than masquerading as healthy.

FROM node:20-alpine AS deps

WORKDIR /repo
RUN apk add --no-cache libc6-compat

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json ./
COPY apps/keeper/package.json ./apps/keeper/
COPY packages/shared/package.json ./packages/shared/
COPY packages/shared/ ./packages/shared/

RUN corepack enable && corepack prepare pnpm@10.18.0 --activate
RUN pnpm install --frozen-lockfile --filter @prism/keeper...

COPY apps/keeper/ ./apps/keeper/

RUN pnpm --filter @prism/keeper build

# -----------------------------------------------------------------------
FROM node:20-alpine AS runtime

WORKDIR /app

# tini ensures SIGTERM reaches the node process — without it docker stop
# escalates to SIGKILL after 10s and the in-flight cycle is lost.
RUN apk add --no-cache tini

# Copy the built keeper + its production dependency closure.
COPY --from=deps /repo/apps/keeper/dist ./dist
COPY --from=deps /repo/node_modules ./node_modules
COPY --from=deps /repo/apps/keeper/node_modules ./apps/keeper/node_modules
COPY --from=deps /repo/packages/shared ./packages/shared
COPY --from=deps /repo/apps/keeper/package.json ./apps/keeper/package.json

# Drop privileges. The default node:alpine "node" user has uid 1000.
USER node

# Health endpoint port (defaults to 8080 — overridable via HEALTH_PORT).
EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/index.js"]

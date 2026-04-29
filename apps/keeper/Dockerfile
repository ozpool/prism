# PRISM keeper — production image (alpha; #60 will harden lifecycle).
#
# Two-stage build:
#   1. deps stage — installs pnpm + the workspace deps once, layer-cached
#      across rebuilds when only source changes
#   2. runtime stage — minimal node:alpine with the built JS, runs the
#      keeper as a non-root user
#
# This Dockerfile is referenced by .github/workflows/keeper.yml (#63)
# for the docker-build smoke test on every PR. Image push lives in #66.
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

# Copy the built keeper + its production dependency closure.
COPY --from=deps /repo/apps/keeper/dist ./dist
COPY --from=deps /repo/node_modules ./node_modules
COPY --from=deps /repo/apps/keeper/node_modules ./apps/keeper/node_modules
COPY --from=deps /repo/packages/shared ./packages/shared
COPY --from=deps /repo/apps/keeper/package.json ./apps/keeper/package.json

# Drop privileges. The default node:alpine "node" user has uid 1000.
USER node

# Health endpoint port (planned in #60). Documented for ops.
EXPOSE 8080

CMD ["node", "dist/index.js"]

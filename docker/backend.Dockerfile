# syntax=docker/dockerfile:1.7
#
# SRI-KO LMS — API tier
#
# Three stages. The point of splitting them is that the image that ships
# contains production dependencies and application source, and nothing else:
# no npm cache, no dev dependencies, no build toolchain, no .env file that
# somebody copied in "just for testing".
#
# Build from the application repository root:
#   docker build -f infrastructure/docker/backend.Dockerfile --target runtime .
#
# The API source directory is a build argument because the organisation has two
# application repositories with different casing: SRI-KO_LMS_MERN uses
# `Backend/`, and `app` uses `backend/`. Hard-coding either one makes this file
# silently wrong for the other, and the error — "package.json not found" —
# gives no hint which of the two you are looking at.
#
#   docker build --build-arg BACKEND_DIR=backend ...

# ── Stage 1: dependencies ───────────────────────────────────────────────────
# Separated from the source copy so that a change to a route file does not
# invalidate the dependency layer. On a typical edit this saves the whole
# npm install.
FROM node:22-alpine AS deps

ARG BACKEND_DIR=Backend

WORKDIR /app

COPY ${BACKEND_DIR}/package.json ${BACKEND_DIR}/package-lock.json ./

# --omit=dev because nothing in devDependencies runs in production, and every
# package that is present is a package that can carry a vulnerability.
# The cache mount keeps the downloads out of the layer.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund

# ── Stage 2: source ─────────────────────────────────────────────────────────
FROM node:22-alpine AS build

ARG BACKEND_DIR=Backend

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY ${BACKEND_DIR}/ ./

# Configuration files that may carry real credentials never reach the runtime
# image. Configuration is supplied by the environment at run time (§7 secrets
# management); a config file baked into an image is a secret published to
# every host that pulls it.
RUN rm -f config.env config.production.env config.test.env .env .env.* \
 && rm -rf test-scripts docs uploads/* \
 && find . -name '*.test.js' -delete

# ── Stage 3: runtime ────────────────────────────────────────────────────────
FROM node:22-alpine AS runtime

# dumb-init reaps zombies and forwards signals. Without it, node runs as PID 1,
# ignores SIGTERM by default, and every deployment waits for the 10-second
# kill timeout before the old container dies.
RUN apk add --no-cache dumb-init \
 && rm -rf /var/cache/apk/*

ENV NODE_ENV=production \
    PORT=5001 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NODE_OPTIONS=--enable-source-maps

WORKDIR /app

# The node image ships an unprivileged `node` user. Running as root inside a
# container turns a code-execution bug into a container-escape starting point.
COPY --from=build --chown=node:node /app ./

# Uploads are written at run time. The directory is created here so the
# non-root user owns it; in production this path is a mounted volume or, better,
# object storage (see docs/DEPLOYMENT.md).
RUN mkdir -p /app/uploads && chown -R node:node /app/uploads

USER node

EXPOSE 5001

# The orchestrator needs to know the difference between "the process is alive"
# and "the service is answering". /health checks the database connection too.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "require('http').get({host:'127.0.0.1',port:process.env.PORT||5001,path:'/health',timeout:4000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "server.js"]

LABEL org.opencontainers.image.title="SRI-KO LMS API" \
      org.opencontainers.image.description="Express REST API for the SRI-KO Learning Management System" \
      org.opencontainers.image.vendor="TeamNova · University of Kelaniya" \
      org.opencontainers.image.source="https://github.com/TeamNova-SRI-KO-LMS" \
      org.opencontainers.image.licenses="UNLICENSED"

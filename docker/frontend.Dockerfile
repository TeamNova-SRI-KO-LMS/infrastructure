# syntax=docker/dockerfile:1.7
#
# SRI-KO LMS — web tier
#
# The React application is a static bundle once built, so the runtime image is
# nginx and the built assets. Node appears only in the build stage and is not
# in the shipped image at all — which removes the entire Node attack surface
# from the tier that faces the internet.
#
# Build from the application repository root:
#   docker build -f infrastructure/docker/frontend.Dockerfile \
#     --build-arg VITE_API_URL=https://api.example.com/api .
#
# FRONTEND_DIR is a build argument for the same reason as BACKEND_DIR: the
# organisation has two application repositories, one using `Frontend/` and one
# using `frontend/`.
#
#   docker build --build-arg FRONTEND_DIR=frontend ...

# ── Stage 1: dependencies ───────────────────────────────────────────────────
FROM node:22-alpine AS deps

ARG FRONTEND_DIR=Frontend

WORKDIR /app

COPY ${FRONTEND_DIR}/package.json ${FRONTEND_DIR}/package-lock.json ./

# devDependencies are required here: vite, tailwind and postcss are the build.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --include=dev --no-audit --no-fund

# ── Stage 2: build ──────────────────────────────────────────────────────────
FROM node:22-alpine AS build

ARG FRONTEND_DIR=Frontend

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY ${FRONTEND_DIR}/ ./

# Vite inlines VITE_* variables at build time, so they are baked into the
# bundle and shipped to every browser. Only non-secret values belong here —
# an API base URL and a public OAuth client id. A secret passed as a build
# argument is a secret published in the JavaScript.
ARG VITE_API_URL=http://localhost:5001/api
ARG VITE_GOOGLE_CLIENT_ID=""
ARG VITE_APP_NAME="SRI-KO Learning Management System"
ARG VITE_NODE_ENV=production

ENV VITE_API_URL=$VITE_API_URL \
    VITE_GOOGLE_CLIENT_ID=$VITE_GOOGLE_CLIENT_ID \
    VITE_APP_NAME=$VITE_APP_NAME \
    VITE_NODE_ENV=$VITE_NODE_ENV

RUN npm run build

# ── Stage 3: runtime ────────────────────────────────────────────────────────
# nginx-unprivileged runs as uid 101 and listens on 8080, so no capability to
# bind a privileged port is needed and the container has no root process.
FROM nginxinc/nginx-unprivileged:1.31-alpine AS runtime

# The nginx config lives in the infrastructure repository, and the build
# context is the *application* repository — so it is not reachable by a plain
# COPY. `--build-context infra=<path>` supplies it as a second named context.
#
#   docker build --build-context infra=../infrastructure ...
#
# Compose does this with `additional_contexts`, and build-push-action with
# `build-contexts`. Every call site in this repository passes it; a build that
# forgets fails immediately with "failed to resolve context: infra", which is
# a legible error rather than a container serving the stock nginx welcome page.
USER root
RUN rm -f /etc/nginx/conf.d/default.conf
COPY --from=infra docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html
USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=4s --start-period=10s --retries=3 \
  CMD wget --spider -q http://127.0.0.1:8080/healthz || exit 1

LABEL org.opencontainers.image.title="SRI-KO LMS Web" \
      org.opencontainers.image.description="React single-page frontend for the SRI-KO Learning Management System" \
      org.opencontainers.image.vendor="TeamNova · University of Kelaniya" \
      org.opencontainers.image.source="https://github.com/TeamNova-SRI-KO-LMS" \
      org.opencontainers.image.licenses="UNLICENSED"

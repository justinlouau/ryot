ARG NODE_BASE_IMAGE=node:24.22.1-bookworm-slim

# ---------------------------------------------------------
# Stage 1: Build the Rust backend from source
# ---------------------------------------------------------
FROM rust:bookworm AS backend-builder
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy all repository source files (including apps/backend, crates/, libs/, etc.)
COPY . .

# Build the release binary
RUN cargo build --release --bin backend

# ---------------------------------------------------------
# Stage 2: Prepare Frontend Build Base
# ---------------------------------------------------------
FROM $NODE_BASE_IMAGE AS frontend-build-base
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------
# Stage 3: Prune Monorepo for Frontend
# ---------------------------------------------------------
FROM frontend-build-base AS frontend-pruner
WORKDIR /app
RUN npm install -g turbo@2.8.10
COPY . .
RUN turbo prune @ryot/frontend --docker

# ---------------------------------------------------------
# Stage 4: Build Frontend Assets
# ---------------------------------------------------------
FROM frontend-build-base AS frontend-builder
WORKDIR /app
COPY --from=frontend-pruner /app/out/json/ .
RUN yarn install
COPY --from=frontend-pruner /app/out/full/ .
COPY --from=frontend-pruner /app/tsconfig.options.json .
RUN yarn turbo run build --filter=@ryot/frontend
RUN yarn workspaces focus @ryot/frontend --production

# ---------------------------------------------------------
# Stage 5: Final Production Container
# ---------------------------------------------------------
FROM $NODE_BASE_IMAGE
LABEL org.opencontainers.image.source="https://github.com/IgnisDa/ryot"
LABEL org.opencontainers.image.description="The only self hosted tracker you will ever need!"

ENV FRONTEND_UMAMI_SCRIPT_URL="https://umami.diptesh.me/script.js"
ENV FRONTEND_UMAMI_WEBSITE_ID="5ecd6915-d542-4fda-aa5f-70f09f04e2e0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    ca-certificates \
    procps \
    libc6 \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=caddy:2.9.1 /usr/bin/caddy /usr/local/bin/caddy
RUN npm install --global concurrently@9.1.2 && concurrently --version

RUN useradd -m -u 1001 ryot
WORKDIR /home/ryot

COPY ci/run-container.sh /usr/local/bin/run-container.sh
RUN chmod +x /usr/local/bin/run-container.sh
COPY ci/Caddyfile /etc/caddy/Caddyfile

# Copy frontend artifacts
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/node_modules ./node_modules
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/package.json ./package.json
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/server.mjs ./server.mjs
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/build ./build

# Copy compiled backend directly from the backend-builder stage
COPY --from=backend-builder --chown=ryot:ryot /app/target/release/backend /usr/local/bin/backend

# Verify dynamic linkage
RUN ldd /usr/local/bin/backend 2>&1 \
    | tee /tmp/backend-ldd \
    && ! grep -q "not found" /tmp/backend-ldd \
    && rm /tmp/backend-ldd

USER ryot
CMD ["/usr/local/bin/run-container.sh"]
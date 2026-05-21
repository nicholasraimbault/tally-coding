# Sprint 24: orchestrator container, deployed to a Phala CVM so closing
# the laptop doesn't stop the team. Same Phala-all-the-way-down posture
# as the workers — orchestrator runs in a TDX-attested VM, handles
# plaintext task descriptions / architect prompts / SQLite rows inside
# the encrypted enclave.

# Stage 1: build skytale_sdk Python wheel from master (matches the
# worker's pattern; the PyMlsEngine isn't published as a binary yet).
FROM python:3.12-slim AS skytale-builder

ARG SKYTALE_BRANCH=master

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates pkg-config libssl-dev build-essential \
    protobuf-compiler cmake \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

RUN pip install --no-cache-dir 'maturin[patchelf]'

RUN git clone --depth 1 --branch ${SKYTALE_BRANCH} \
    https://github.com/nicholasraimbault/skytale.git /skytale

WORKDIR /skytale/sdk
RUN maturin build --release --features python --compatibility linux -o /wheels

# Stage 2: orchestrator runtime.
FROM python:3.12-slim

LABEL org.opencontainers.image.source=https://github.com/nicholasraimbault/tally-coding
LABEL org.opencontainers.image.version=v27
LABEL org.opencontainers.image.description="Tally Coding orchestrator (Sprint 47: Discord-shaped chat foundation — workspaces, channels, messages, role overrides, WebSocket new_message)"

WORKDIR /app

# Runtime deps: git for occasional pulls inside agent workflows; nothing
# else heavy. The orchestrator itself is Python + httpx + sqlite (all
# in stdlib or pure wheels). Worker auto-provisioning needs the `phala`
# CLI (Node.js) when we re-enable it from inside the CVM — install
# pre-emptively so the future Sprint 24.5 doesn't need an image bump.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install --prefix /opt/phala -g phala \
    && ln -s /opt/phala/lib/node_modules/.bin/phala /usr/local/bin/phala \
    && rm -rf /var/lib/apt/lists/*

# uv.lock references skytale-sdk + tally-coding-core via local path
# sources (`../..` and `../../../skytale/sdk`) that don't exist in the
# container, so `uv sync` fails. Skip uv entirely and install deps
# explicitly with pip — wheel for skytale-sdk, path packages for the
# rest. The orchestrator dep list is short (5 PyPI deps) so this is
# straightforward and reproducible.

# Install runtime PyPI deps directly. `cryptography` + `python-dotenv` are
# transitive (tally-coding-core needs them); we list them inline because
# the `--no-deps` install of the core package below skips its declared
# deps (openhands-ai isn't needed for the orchestrator).
RUN pip install --no-cache-dir \
    "fastapi>=0.115.0" \
    "uvicorn[standard]>=0.32.0" \
    "httpx>=0.27.0" \
    "sse-starlette>=2.1.0" \
    "cryptography>=42.0" \
    "python-dotenv>=1.0.0" \
    "pyjwt[crypto]>=2.10.0" \
    "stripe>=11.0.0" \
    "websockets>=13.0"

# Install the skytale-sdk wheel from stage 1.
COPY --from=skytale-builder /wheels/skytale_sdk-*.whl /tmp/wheels/
RUN pip install --no-cache-dir /tmp/wheels/skytale_sdk-*.whl \
    && rm -rf /tmp/wheels

# tally_coding_core is a hatchling package defined by the REPO ROOT
# pyproject.toml (name = "tally-coding-core", source dir =
# tally_coding_core/). Copy both so pip can build the wheel; install
# --no-deps because the root pyproject lists openhands-ai (only the
# worker needs that), which would bloat the orchestrator image.
COPY pyproject.toml /app/core/pyproject.toml
COPY tally_coding_core /app/core/tally_coding_core
RUN pip install --no-cache-dir --no-deps /app/core

# Orchestrator source + install it as a package so console scripts
# (tally-orch) are on PATH.
COPY services/orchestrator/pyproject.toml /app/
COPY services/orchestrator/tally_orchestrator /app/tally_orchestrator
RUN pip install --no-cache-dir --no-deps /app

# Persistent state directory — Sprint 24 mounts a Phala volume here so
# SQLite + MLS sessions survive CVM restarts. Without the mount, /data
# is ephemeral (acceptable for dev, terrible for prod).
RUN mkdir -p /data
VOLUME /data

ENV HOST=0.0.0.0 \
    PORT=8080 \
    ORCH_DB_PATH=/data/tasks.db \
    ORCH_IDENTITY_PATH=/data/orchestrator.key \
    ORCH_MLS_STATE_DIR=/data/mls-state \
    TALLY_POOL_SIZE=1

EXPOSE 8080

CMD ["python", "-m", "tally_orchestrator.service"]

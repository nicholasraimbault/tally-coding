# Stage 1: build the skytale-sdk Python wheel from skytale master. PR #470
# (PyMlsEngine) is merged; the wheel still has to be built from source
# because PyMlsEngine isn't in any published binary release yet.
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

# Stage 2: actual worker runtime.
FROM python:3.12-slim

LABEL org.opencontainers.image.source=https://github.com/nicholasraimbault/tally-coding

WORKDIR /app

# Build deps for openhands-ai
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

# Install the skytale-sdk wheel built in stage 1 into the uv venv.
COPY --from=skytale-builder /wheels/skytale_sdk-*.whl /tmp/wheels/
RUN uv pip install --python /app/.venv/bin/python /tmp/wheels/skytale_sdk-*.whl \
    && rm -rf /tmp/wheels

COPY worker_spike.py /app/
COPY tally_coding_core /app/tally_coding_core

RUN mkdir -p /workspace

ENV WORKSPACE_DIR=/workspace

RUN useradd -m -u 1000 appuser \
    && chown -R appuser:appuser /app /workspace
USER appuser

CMD ["uv", "run", "python", "worker_spike.py"]

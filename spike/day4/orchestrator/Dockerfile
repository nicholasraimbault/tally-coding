# Stage 1: build the skytale-sdk Python wheel from the feat/py-mls-engine
# branch (PR #470). See worker/Dockerfile for the same comment.
FROM python:3.12-slim AS skytale-builder

ARG SKYTALE_BRANCH=feat/py-mls-engine

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

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

COPY --from=skytale-builder /wheels/skytale_sdk-*.whl /tmp/wheels/
RUN uv pip install --python /app/.venv/bin/python /tmp/wheels/skytale_sdk-*.whl \
    && rm -rf /tmp/wheels

COPY orchestrator_spike.py /app/
COPY tally_coding_core /app/tally_coding_core

RUN useradd -m -u 1000 appuser \
    && chown -R appuser:appuser /app
USER appuser

CMD ["uv", "run", "python", "orchestrator_spike.py"]

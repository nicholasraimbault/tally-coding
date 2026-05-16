FROM python:3.12-slim

WORKDIR /app

# Build deps for openhands-ai + git for repo cloning
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

# Copy the worker entrypoint + shared tally_coding_core
COPY worker_spike.py /app/
COPY tally_coding_core /app/tally_coding_core

# Workspace mount
RUN mkdir -p /workspace

ENV WORKSPACE_DIR=/workspace

# Create non-root user (TEE security hygiene)
RUN useradd -m -u 1000 appuser \
    && chown -R appuser:appuser /app /workspace
USER appuser

CMD ["uv", "run", "python", "worker_spike.py"]

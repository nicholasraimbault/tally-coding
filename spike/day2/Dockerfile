FROM python:3.12-slim

WORKDIR /app

# Install build deps for any native modules openhands-ai may pull
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Phala recommends pip but uv is faster + reproducible)
RUN pip install --no-cache-dir uv

# Copy project files
COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

# Copy spike script
COPY spike.py /app/

# Workspace for agent activity
RUN mkdir -p /workspace

ENV WORKSPACE_DIR=/workspace

# Create non-root user (TEE security hygiene)
RUN useradd -m -u 1000 appuser \
    && chown -R appuser:appuser /app /workspace
USER appuser

CMD ["uv", "run", "python", "spike.py"]

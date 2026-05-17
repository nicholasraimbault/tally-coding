FROM python:3.12-slim

LABEL org.opencontainers.image.source=https://github.com/nicholasraimbault/tally-coding

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

COPY orchestrator_spike.py /app/
COPY tally_coding_core /app/tally_coding_core

# Create non-root user (TEE security hygiene)
RUN useradd -m -u 1000 appuser \
    && chown -R appuser:appuser /app
USER appuser

CMD ["uv", "run", "python", "orchestrator_spike.py"]

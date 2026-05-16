FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

COPY orchestrator_spike.py /app/
COPY tally_coding_core /app/tally_coding_core

CMD ["uv", "run", "python", "orchestrator_spike.py"]

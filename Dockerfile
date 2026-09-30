# syntax=docker/dockerfile:1.7
FROM python:3.12-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/opt/venv/bin:$PATH

RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

FROM python:3.12-slim-bookworm

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/srv/app \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent app
COPY --from=builder /opt/venv /opt/venv
WORKDIR /srv/app
COPY --chown=app:app app/ ./app/

COPY <<'PY' /opt/wait-for-db.py
import os
import sys
import time

from sqlalchemy import create_engine
from sqlalchemy.exc import OperationalError

from app.config import load_settings


def main():
    settings = load_settings()
    deadline = time.monotonic() + int(os.getenv("DB_WAIT_TIMEOUT", "60"))
    engine = create_engine(
        settings.database_url,
        connect_args={"connect_timeout": 3},
    )
    try:
        while True:
            try:
                with engine.connect() as connection:
                    connection.exec_driver_sql("SELECT 1")
                break
            except OperationalError:
                if time.monotonic() >= deadline:
                    print("PostgreSQL is not ready before DB_WAIT_TIMEOUT", file=sys.stderr)
                    raise SystemExit(1)
                print("Waiting for PostgreSQL...")
                time.sleep(min(2, max(0, deadline - time.monotonic())))
    finally:
        engine.dispose()

    os.execvp(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()
PY

USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["python", "/opt/wait-for-db.py"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

#!/bin/bash
set -e -x

# Ensure svix database exists (idempotent)
echo 'Ensuring svix database...'
uv run python scripts/init/create_svix_db.py

# Init database
echo 'Applying migrations...'
uv run alembic upgrade head

# Initialize provider settings
echo 'Initializing provider settings...'
uv run python scripts/init_provider_settings.py

# Initialize device priority table
echo 'Initializing priorities...'
uv run python scripts/init_device_priorities.py

# Seed admin account
echo 'Seeding admin account...'
uv run python scripts/init/seed_admin.py

# Initialize series type definitions
echo 'Initializing series type definitions...'
uv run python scripts/init/seed_series_types.py

# Initialize archival settings
echo 'Initializing archival settings...'
uv run python scripts/init/seed_archival_settings.py

# Register webhook event types with Svix (non-fatal)
echo 'Registering webhook event types...'
for i in 1 2 3; do
    uv run python scripts/init/seed_webhook_event_types.py && break
    echo "Svix not ready yet, retrying in 5s... (attempt ${i}/3)"
    sleep 5
done || echo "Warning: Could not register webhook event types with Svix."

# ── Start Celery worker in background ────────────────────────────────────────
echo 'Starting Celery worker...'
uv run celery -A app.main:celery_app worker --loglevel=info --pool=threads -Q default,sdk_sync,garmin_sync &
WORKER_PID=$!

# ── Start Celery beat in background ──────────────────────────────────────────
echo 'Starting Celery beat...'
rm -f './celerybeat.pid'
uv run celery -A app.main:celery_app beat -l info &
BEAT_PID=$!

# ── Start FastAPI (foreground — mantém o container vivo) ─────────────────────
echo 'Starting FastAPI...'
uv run fastapi run app/main.py --host 0.0.0.0 --port 8000 &
APP_PID=$!

# Se qualquer processo morrer, mata os outros e sai
wait_and_exit() {
    echo "Um processo encerrou. Encerrando os demais..."
    kill $WORKER_PID $BEAT_PID $APP_PID 2>/dev/null
    exit 1
}

trap wait_and_exit SIGTERM SIGINT

# Aguarda todos os processos
wait $APP_PID $WORKER_PID $BEAT_PID
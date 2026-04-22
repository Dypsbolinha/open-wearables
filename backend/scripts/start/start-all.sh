#!/bin/bash
set -e -x

# Entra na pasta correta onde o módulo 'app' existe
cd /opt/render/project/src/backend

# Ativa o virtualenv diretamente (evita conflito com uv)
source /opt/render/project/src/.venv/bin/activate

# Init database
echo 'Applying migrations...'
alembic upgrade head

# Initialize provider settings
echo 'Initializing provider settings...'
python scripts/init_provider_settings.py

# Initialize device priority table
echo 'Initializing priorities...'
python scripts/init_device_priorities.py

# Seed admin account
echo 'Seeding admin account...'
python scripts/init/seed_admin.py

# Initialize series type definitions
echo 'Initializing series type definitions...'
python scripts/init/seed_series_types.py

# Initialize archival settings
echo 'Initializing archival settings...'
python scripts/init/seed_archival_settings.py

# Register webhook event types with Svix (non-fatal)
echo 'Registering webhook event types...'
for i in 1 2 3; do
    python scripts/init/seed_webhook_event_types.py && break
    echo "Svix not ready yet, retrying in 5s... (attempt ${i}/3)"
    sleep 5
done || echo "Warning: Could not register webhook event types with Svix."

# ── Start Celery worker in background ────────────────────────────────────────
echo 'Starting Celery worker...'
celery -A app.main:celery_app worker --loglevel=info --pool=threads -Q default,sdk_sync,garmin_sync &
WORKER_PID=$!

# ── Start Celery beat in background ──────────────────────────────────────────
echo 'Starting Celery beat...'
rm -f './celerybeat.pid'
celery -A app.main:celery_app beat -l info &
BEAT_PID=$!

# ── Start uvicorn (foreground) ────────────────────────────────────────────────
echo 'Starting uvicorn...'
uvicorn app.main:api --host 0.0.0.0 --port 8000 &
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
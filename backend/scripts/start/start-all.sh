#!/bin/bash
set -x

# Entra na pasta correta onde o módulo 'app' e o alembic.ini existem
cd /opt/render/project/src/backend

# Ativa o virtualenv
source /opt/render/project/src/.venv/bin/activate

# Exporta PYTHONPATH para garantir que 'app' seja encontrado
export PYTHONPATH=/opt/render/project/src/backend

# Init database
echo 'Applying migrations...'
uv run --active alembic upgrade head || echo "Warning: migrations failed or already up to date."

# Initialize provider settings
echo 'Initializing provider settings...'
uv run --active python scripts/init_provider_settings.py || echo "Warning: init_provider_settings failed."

# Initialize device priority table
echo 'Initializing priorities...'
uv run --active python scripts/init_device_priorities.py || echo "Warning: init_device_priorities failed."

# Seed admin account
echo 'Seeding admin account...'
uv run --active python scripts/init/seed_admin.py || echo "Warning: seed_admin failed."

# Initialize series type definitions
echo 'Initializing series type definitions...'
uv run --active python scripts/init/seed_series_types.py || echo "Warning: seed_series_types failed."

# Initialize archival settings
echo 'Initializing archival settings...'
uv run --active python scripts/init/seed_archival_settings.py || echo "Warning: seed_archival_settings failed."

# Register webhook event types with Svix (non-fatal)
echo 'Registering webhook event types...'
for i in 1 2 3; do
    uv run --active python scripts/init/seed_webhook_event_types.py && break
    echo "Svix not ready yet, retrying in 5s... (attempt ${i}/3)"
    sleep 5
done || echo "Warning: Could not register webhook event types with Svix."

# ── Start Celery worker com concurrency 1 para economizar memória ─────────────
# Beat removido — o WhoopLike já faz polling a cada hora
echo 'Starting Celery worker (concurrency=1)...'
uv run --active celery -A app.main:celery_app worker \
    --loglevel=info \
    --pool=threads \
    --concurrency=1 \
    -Q default,sdk_sync,garmin_sync &
WORKER_PID=$!

# ── Start uvicorn ─────────────────────────────────────────────────────────────
echo 'Starting uvicorn...'
uv run --active uvicorn app.main:api --host 0.0.0.0 --port 8000 &
APP_PID=$!

# Se qualquer processo morrer, mata os outros e sai
wait_and_exit() {
    echo "Um processo encerrou. Encerrando os demais..."
    kill $WORKER_PID $APP_PID 2>/dev/null
    exit 1
}

trap wait_and_exit SIGTERM SIGINT

# Aguarda todos os processos
wait $APP_PID $WORKER_PID
#!/bin/bash
set -x

cd /opt/render/project/src/backend
source /opt/render/project/src/.venv/bin/activate
export PYTHONPATH=/opt/render/project/src/backend

echo 'Applying migrations...'
uv run --active alembic upgrade head || echo "Warning: migrations failed or already up to date."

echo 'Initializing provider settings...'
uv run --active python scripts/init_provider_settings.py || echo "Warning: init_provider_settings failed."

echo 'Initializing priorities...'
uv run --active python scripts/init_device_priorities.py || echo "Warning: init_device_priorities failed."

echo 'Seeding admin account...'
uv run --active python scripts/init/seed_admin.py || echo "Warning: seed_admin failed."

echo 'Initializing series type definitions...'
uv run --active python scripts/init/seed_series_types.py || echo "Warning: seed_series_types failed."

echo 'Initializing archival settings...'
uv run --active python scripts/init/seed_archival_settings.py || echo "Warning: seed_archival_settings failed."

# Svix: só tenta se a variável estiver configurada
if [ -n "$SVIX_SERVER_URL" ] && [ -n "$SVIX_AUTH_TOKEN" ]; then
    echo 'Registering webhook event types...'
    for i in 1 2 3; do
        uv run --active python scripts/init/seed_webhook_event_types.py && break
        echo "Svix not ready yet, retrying in 5s... (attempt ${i}/3)"
        sleep 5
    done || echo "Warning: Could not register webhook event types with Svix."
else
    echo 'Svix not configured — skipping webhook event type registration.'
fi

# ─── Celery worker ────────────────────────────────────────────────────────────
# IMPORTANTE: --pool=prefork (padrão) em vez de --pool=threads.
# Com threads, --max-tasks-per-child e --max-memory-per-child são ignorados
# silenciosamente — o processo nunca reinicia e a memória acumula até OOM.
# Com prefork + concurrency=1, o único worker process é reciclado após
# 10 tasks OU se ultrapassar 200MB, mantendo o uso estável no free tier (512MB).
# ─────────────────────────────────────────────────────────────────────────────
echo 'Starting Celery worker (prefork, concurrency=1, max-tasks=10, max-mem=200MB)...'
uv run --active celery -A app.main:celery_app worker \
    --loglevel=warning \
    --pool=prefork \
    --concurrency=1 \
    --max-tasks-per-child=10 \
    --max-memory-per-child=200000 \
    -Q default,sdk_sync,garmin_sync &
WORKER_PID=$!

echo 'Starting uvicorn...'
uv run --active uvicorn app.main:api \
    --host 0.0.0.0 \
    --port 8000 \
    --workers 1 \
    --log-level warning &
APP_PID=$!

wait_and_exit() {
    echo "Um processo encerrou. Encerrando os demais..."
    kill $WORKER_PID $APP_PID 2>/dev/null
    exit 1
}

trap wait_and_exit SIGTERM SIGINT

wait $APP_PID $WORKER_PID
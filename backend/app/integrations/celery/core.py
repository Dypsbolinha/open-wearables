import logging
import sys
from logging import Formatter, LogRecord, StreamHandler, getLogger

from app.config import settings
from app.services import raw_payload_storage
from celery import Celery, signals
from celery import current_app as current_celery_app

_WEBHOOK_TASK = "emit_webhook_event_task.emit_webhook_event"


class _WebhookTraceFilter(logging.Filter):
    """Drop celery.app.trace success/retry records for the webhook emit task.

    Failures (ERROR and above) are always passed through.
    """

    def filter(self, record: LogRecord) -> bool:
        if record.levelno >= logging.ERROR:
            return True
        msg = record.getMessage()
        return _WEBHOOK_TASK not in msg


@signals.setup_logging.connect
def setup_celery_logging(**kwargs) -> None:
    celery_logger = getLogger("celery")
    celery_logger.handlers.clear()

    stdout_handler = StreamHandler(sys.stdout)
    stdout_handler.setFormatter(
        Formatter(
            "[%(asctime)s - %(name)s] (%(levelname)s) %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )

    celery_logger.addHandler(stdout_handler)
    celery_logger.setLevel(logging.WARNING)  # WARNING em vez de INFO — menos ruído e memória
    celery_logger.propagate = False

    getLogger("celery.app.trace").addFilter(_WebhookTraceFilter())


@signals.worker_init.connect
def init_raw_payload_storage(**kwargs) -> None:
    """Initialize raw payload storage in celery workers."""
    raw_payload_storage.configure(
        settings.raw_payload_storage,
        settings.raw_payload_max_size_bytes,
        s3_bucket=settings.raw_payload_s3_bucket or settings.aws_bucket_name,
        s3_prefix=settings.raw_payload_s3_prefix,
        s3_endpoint_url=settings.raw_payload_s3_endpoint_url,
    )


def create_celery() -> Celery:
    celery_app: Celery = current_celery_app  # type: ignore[assignment]
    celery_app.conf.update(
        broker_url=settings.redis_url,
        result_backend=settings.redis_url,
        task_serializer="json",
        accept_content=["json"],
        result_serializer="json",
        timezone="UTC",
        enable_utc=True,
        task_default_queue="default",
        task_default_exchange="default",
        result_expires=3 * 24 * 3600,
        control_queue_ttl=300,
        control_queue_expires=300,
        # Limita memória: descarta resultados de tasks que não precisam de retorno
        task_ignore_result=True,
        # Evita que o worker pré-busque muitas tasks de uma vez
        worker_prefetch_multiplier=1,
        task_queues={
            "default": {},
            "sdk_sync": {},
            "garmin_sync": {},
        },
        task_routes={
            "app.integrations.celery.tasks.process_sdk_upload_task.process_sdk_upload": {"queue": "sdk_sync"},
            "app.integrations.celery.tasks.garmin_webhook_task.process_push": {"queue": "garmin_sync"},
        },
    )

    celery_app.autodiscover_tasks(["app.integrations.celery.tasks"])

    # NOTA: beat_schedule removido intencionalmente.
    # O Celery Beat não está sendo iniciado no start-all.sh (economiza ~80MB).
    # As tasks periódicas (sync, sleep scores, etc.) são acionadas pelo
    # polling do WhoopLike a cada 1h, conforme descrito no README.
    # Se precisar reativar o Beat no futuro, adicione aqui e suba um
    # segundo serviço no Render dedicado ao Beat.

    return celery_app

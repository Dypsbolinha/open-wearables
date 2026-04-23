import logging
import sys
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from logging import INFO, StreamHandler, basicConfig
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.staticfiles import StaticFiles

from app.api import head_router
from app.config import settings
from app.integrations.celery import create_celery
from app.integrations.sentry import init_sentry
from app.middlewares import add_cors_middleware
from app.services import raw_payload_storage
from app.services.outgoing_webhooks import svix as svix_service
from app.utils.exceptions import DatetimeParseError, handle_exception

basicConfig(
    level=INFO,
    format="[%(asctime)s - %(name)s] (%(levelname)s) %(message)s",
    handlers=[StreamHandler(sys.stdout)],
)

for _name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
    _logger = logging.getLogger(_name)
    _logger.handlers.clear()
    _logger.propagate = True


@asynccontextmanager
async def _lifespan(_: FastAPI) -> AsyncGenerator[None, None]:
    # Só registra event types se o Svix estiver configurado,
    # evitando dezenas de erros de conexão no boot quando não há credenciais.
    if svix_service.is_enabled():
        svix_service.register_event_types()
    else:
        logging.getLogger(__name__).info(
            "Svix not configured — skipping webhook event type registration on startup."
        )
    yield


api = FastAPI(title=settings.api_name, lifespan=_lifespan)
celery_app = create_celery()
init_sentry()
raw_payload_storage.configure(
    settings.raw_payload_storage,
    settings.raw_payload_max_size_bytes,
    s3_bucket=settings.raw_payload_s3_bucket or settings.aws_bucket_name,
    s3_prefix=settings.raw_payload_s3_prefix,
    s3_endpoint_url=settings.raw_payload_s3_endpoint_url,
)

add_cors_middleware(api)

static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    api.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


@api.get("/")
async def root() -> dict[str, str]:
    return {"message": "Server is running!"}


@api.exception_handler(RequestValidationError)
async def request_validation_exception_handler(_: Request, exc: RequestValidationError) -> None:
    raise handle_exception(exc, "")


@api.exception_handler(DatetimeParseError)
async def datetime_parse_exception_handler(_: Request, exc: DatetimeParseError) -> None:
    raise handle_exception(exc, "")


api.include_router(head_router)

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = BACKEND_DIR.parent

# Support both repository-root .env and backend/.env. backend/.env wins if both exist.
load_dotenv(REPO_ROOT / ".env")
load_dotenv(BACKEND_DIR / ".env", override=True)


@dataclass(frozen=True)
class Settings:
    database_url: str
    aws_region: str
    s3_bucket: str
    jwt_secret: str
    varco_api_key: Optional[str]
    mock_varco: bool
    access_token_expire_hours: int = 24
    upload_url_expire_seconds: int = 900
    download_url_expire_seconds: int = 3600
    worker_poll_seconds: int = 5
    varco_poll_seconds: int = 10
    varco_poll_timeout_seconds: int = 3600


def _bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _int_env(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None or value.strip() == "":
        return default
    return int(value)


def get_settings() -> Settings:
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        raise RuntimeError("DATABASE_URL is required")

    s3_bucket = os.getenv("S3_BUCKET")
    if not s3_bucket:
        raise RuntimeError("S3_BUCKET is required")

    jwt_secret = os.getenv("JWT_SECRET")
    if not jwt_secret:
        raise RuntimeError("JWT_SECRET is required")

    return Settings(
        database_url=database_url,
        aws_region=os.getenv("AWS_REGION", "us-east-1"),
        s3_bucket=s3_bucket,
        jwt_secret=jwt_secret,
        varco_api_key=os.getenv("VARCO_API_KEY"),
        mock_varco=_bool_env("MOCK_VARCO", default=False),
        access_token_expire_hours=_int_env("ACCESS_TOKEN_EXPIRE_HOURS", 24),
        upload_url_expire_seconds=_int_env("UPLOAD_URL_EXPIRE_SECONDS", 900),
        download_url_expire_seconds=_int_env("DOWNLOAD_URL_EXPIRE_SECONDS", 3600),
        worker_poll_seconds=_int_env("WORKER_POLL_SECONDS", 5),
        varco_poll_seconds=_int_env("VARCO_POLL_SECONDS", 10),
        varco_poll_timeout_seconds=_int_env("VARCO_POLL_TIMEOUT_SECONDS", 3600),
    )


settings = get_settings()

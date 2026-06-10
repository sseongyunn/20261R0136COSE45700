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
    varco_api_key_header: str
    varco_submit_url: str
    varco_result_url_template: str
    varco_target_face_type: str
    varco_target_face_num: int
    varco_generate_texture: bool
    varco_seed: int
    varco_convert_image_to_png: bool
    hunyuan_base_url: str
    hunyuan_request_timeout_seconds: int
    hunyuan_remove_background: bool
    hunyuan_texture: bool
    hunyuan_seed: int
    hunyuan_octree_resolution: int
    hunyuan_num_inference_steps: int
    hunyuan_guidance_scale: float
    hunyuan_num_chunks: int
    hunyuan_face_count: int
    preprocess_images: bool
    preprocess_target_luminance: float
    preprocess_min_exposure_gain: float
    preprocess_max_exposure_gain: float
    preprocess_saturation_gain: float
    preprocess_contrast_gain: float
    mock_varco: bool
    access_token_expire_hours: int = 24
    upload_url_expire_seconds: int = 900
    download_url_expire_seconds: int = 3600
    worker_poll_seconds: int = 5
    varco_poll_seconds: int = 10
    varco_poll_timeout_seconds: int = 3600
    generation_jobs_per_hour: int = 3
    generation_jobs_per_day: int = 15


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


def _float_env(name: str, default: float) -> float:
    value = os.getenv(name)
    if value is None or value.strip() == "":
        return default
    return float(value)


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
        varco_api_key=os.getenv("VARCO_API_KEY") or os.getenv("OPENAPI_KEY"),
        varco_api_key_header=os.getenv("VARCO_API_KEY_HEADER", "OPENAPI_KEY"),
        varco_submit_url=os.getenv(
            "VARCO_SUBMIT_URL",
            "https://openapi.ai.nc.com/3d/varco/v1/image-to-3d",
        ),
        varco_result_url_template=os.getenv(
            "VARCO_RESULT_URL_TEMPLATE",
            "https://openapi.ai.nc.com/inference/result/{request_id}",
        ),
        varco_target_face_type=os.getenv("VARCO_TARGET_FACE_TYPE", "tri"),
        varco_target_face_num=_int_env("VARCO_TARGET_FACE_NUM", 300000),
        varco_generate_texture=_bool_env("VARCO_GENERATE_TEXTURE", default=True),
        varco_seed=_int_env("VARCO_SEED", -1),
        varco_convert_image_to_png=_bool_env("VARCO_CONVERT_IMAGE_TO_PNG", default=True),
        hunyuan_base_url=os.getenv("HUNYUAN_BASE_URL", "http://172.31.91.251:5173"),
        hunyuan_request_timeout_seconds=_int_env("HUNYUAN_REQUEST_TIMEOUT_SECONDS", 1800),
        hunyuan_remove_background=_bool_env("HUNYUAN_REMOVE_BACKGROUND", default=True),
        hunyuan_texture=_bool_env("HUNYUAN_TEXTURE", default=False),
        hunyuan_seed=_int_env("HUNYUAN_SEED", 1234),
        hunyuan_octree_resolution=_int_env("HUNYUAN_OCTREE_RESOLUTION", 512),
        hunyuan_num_inference_steps=_int_env("HUNYUAN_NUM_INFERENCE_STEPS", 40),
        hunyuan_guidance_scale=_float_env("HUNYUAN_GUIDANCE_SCALE", 5.0),
        hunyuan_num_chunks=_int_env("HUNYUAN_NUM_CHUNKS", 8000),
        hunyuan_face_count=_int_env("HUNYUAN_FACE_COUNT", 1000000),
        preprocess_images=_bool_env("PREPROCESS_IMAGES", default=True),
        preprocess_target_luminance=_float_env("PREPROCESS_TARGET_LUMINANCE", 0.58),
        preprocess_min_exposure_gain=_float_env("PREPROCESS_MIN_EXPOSURE_GAIN", 0.82),
        preprocess_max_exposure_gain=_float_env("PREPROCESS_MAX_EXPOSURE_GAIN", 1.75),
        preprocess_saturation_gain=_float_env("PREPROCESS_SATURATION_GAIN", 1.10),
        preprocess_contrast_gain=_float_env("PREPROCESS_CONTRAST_GAIN", 1.04),
        mock_varco=_bool_env("MOCK_VARCO", default=False),
        access_token_expire_hours=_int_env("ACCESS_TOKEN_EXPIRE_HOURS", 24),
        upload_url_expire_seconds=_int_env("UPLOAD_URL_EXPIRE_SECONDS", 900),
        download_url_expire_seconds=_int_env("DOWNLOAD_URL_EXPIRE_SECONDS", 3600),
        worker_poll_seconds=_int_env("WORKER_POLL_SECONDS", 5),
        varco_poll_seconds=_int_env("VARCO_POLL_SECONDS", 10),
        varco_poll_timeout_seconds=_int_env("VARCO_POLL_TIMEOUT_SECONDS", 3600),
        generation_jobs_per_hour=_int_env("GENERATION_JOBS_PER_HOUR", 3),
        generation_jobs_per_day=_int_env("GENERATION_JOBS_PER_DAY", 15),
    )


settings = get_settings()

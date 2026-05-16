from __future__ import annotations

import logging
import sys
import time
from pathlib import Path
from typing import Optional
from uuid import uuid4

from sqlalchemy import text


BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.config import settings
from app.database import SessionLocal
from app.services import hunyuan_service, varco_service
from app.services.s3_service import (
    download_object_bytes,
    furniture_asset_model_key,
    upload_model_bytes,
)


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("generation-worker")

SUCCESS_STATUSES = {"succeeded", "success", "completed", "complete", "done"}
FAILED_STATUSES = {"failed", "failure", "error", "cancelled", "canceled"}
IN_PROGRESS_STATUSES = {"queued", "submitted", "processing", "running", "pending"}


def claim_queued_job() -> Optional[dict]:
    with SessionLocal() as db:
        with db.begin():
            row = db.execute(
                text(
                    """
                    SELECT
                        j.id,
                        j.user_id,
                        j.source_image_id,
                        j.source_back_image_id,
                        j.source_left_image_id,
                        j.source_right_image_id,
                        j.provider,
                        j.generation_mode,
                        j.requested_name,
                        j.requested_category,
                        j.requested_width_cm,
                        j.requested_height_cm,
                        j.requested_depth_cm,
                        si.s3_bucket AS source_s3_bucket,
                        si.s3_key AS source_s3_key,
                        back_si.s3_bucket AS back_s3_bucket,
                        back_si.s3_key AS back_s3_key,
                        left_si.s3_bucket AS left_s3_bucket,
                        left_si.s3_key AS left_s3_key,
                        right_si.s3_bucket AS right_s3_bucket,
                        right_si.s3_key AS right_s3_key
                    FROM generation_jobs j
                    JOIN source_images si ON si.id = j.source_image_id
                    LEFT JOIN source_images back_si ON back_si.id = j.source_back_image_id
                    LEFT JOIN source_images left_si ON left_si.id = j.source_left_image_id
                    LEFT JOIN source_images right_si ON right_si.id = j.source_right_image_id
                    WHERE j.status = 'queued'
                    ORDER BY j.queued_at ASC
                    LIMIT 1
                    FOR UPDATE OF j SKIP LOCKED
                    """
                )
            ).mappings().first()

            if row is None:
                return None

            db.execute(
                text(
                    """
                    UPDATE generation_jobs
                    SET status = 'processing', started_at = now()
                    WHERE id = :job_id
                    """
                ),
                {"job_id": str(row["id"])},
            )
            return dict(row)


def update_provider_request_id(job_id: str, provider_request_id: str) -> None:
    with SessionLocal() as db:
        db.execute(
            text(
                """
                UPDATE generation_jobs
                SET provider_request_id = :provider_request_id
                WHERE id = :job_id
                """
            ),
            {"job_id": job_id, "provider_request_id": provider_request_id},
        )
        db.commit()


def update_job_status(job_id: str, status: str) -> None:
    with SessionLocal() as db:
        db.execute(
            text("UPDATE generation_jobs SET status = :status WHERE id = :job_id"),
            {"job_id": job_id, "status": status},
        )
        db.commit()


def mark_job_failed(job_id: str, reason: str) -> None:
    with SessionLocal() as db:
        db.execute(
            text(
                """
                UPDATE generation_jobs
                SET status = 'failed', failed_at = now(), failure_reason = :reason
                WHERE id = :job_id
                """
            ),
            {"job_id": job_id, "reason": reason[:4000]},
        )
        db.commit()


def complete_job_with_asset(job: dict, asset_id: str, model_key: str) -> None:
    with SessionLocal() as db:
        with db.begin():
            db.execute(
                text(
                    """
                    INSERT INTO furniture_assets (
                        id,
                        user_id,
                        generation_job_id,
                        name,
                        category,
                        width_cm,
                        height_cm,
                        depth_cm,
                        model_s3_bucket,
                        model_s3_key
                    )
                    VALUES (
                        :asset_id,
                        :user_id,
                        :job_id,
                        :name,
                        :category,
                        :width_cm,
                        :height_cm,
                        :depth_cm,
                        :bucket,
                        :key
                    )
                    """
                ),
                {
                    "asset_id": asset_id,
                    "user_id": str(job["user_id"]),
                    "job_id": str(job["id"]),
                    "name": job["requested_name"],
                    "category": job["requested_category"],
                    "width_cm": job["requested_width_cm"],
                    "height_cm": job["requested_height_cm"],
                    "depth_cm": job["requested_depth_cm"],
                    "bucket": settings.s3_bucket,
                    "key": model_key,
                },
            )
            db.execute(
                text(
                    """
                    UPDATE generation_jobs
                    SET status = 'succeeded', completed_at = now()
                    WHERE id = :job_id
                    """
                ),
                {"job_id": str(job["id"])},
            )


def create_mock_glb() -> bytes:
    # Minimal GLB 2.0 container with an empty JSON scene. Useful for validating
    # the app flow before VARCO endpoint details are finalized.
    json_chunk = b'{"asset":{"version":"2.0"},"scenes":[{"nodes":[]}],"scene":0}'
    padding = (4 - (len(json_chunk) % 4)) % 4
    json_chunk += b" " * padding
    total_length = 12 + 8 + len(json_chunk)
    header = b"glTF" + (2).to_bytes(4, "little") + total_length.to_bytes(4, "little")
    chunk_header = len(json_chunk).to_bytes(4, "little") + b"JSON"
    return header + chunk_header + json_chunk


def wait_for_varco_model(provider_request_id: str) -> str:
    deadline = time.monotonic() + settings.varco_poll_timeout_seconds
    while time.monotonic() < deadline:
        result = varco_service.get_generation_result(provider_request_id)
        provider_status = varco_service.extract_status(result)
        logger.info("VARCO request %s status: %s", provider_request_id, provider_status)

        if provider_status in SUCCESS_STATUSES:
            model_url = varco_service.extract_model_url(result)
            if not model_url:
                raise RuntimeError(f"VARCO result succeeded without model URL: {result}")
            return model_url

        if provider_status in FAILED_STATUSES:
            raise RuntimeError(f"VARCO generation failed: {result}")

        model_url = varco_service.extract_model_url(result)
        if model_url and provider_status not in IN_PROGRESS_STATUSES:
            return model_url

        time.sleep(settings.varco_poll_seconds)

    raise TimeoutError(f"VARCO request timed out after {settings.varco_poll_timeout_seconds}s")


def _download_hunyuan_multiview_images(job: dict) -> dict[str, bytes]:
    sources = {
        "front": ("source_s3_bucket", "source_s3_key"),
        "back": ("back_s3_bucket", "back_s3_key"),
        "left": ("left_s3_bucket", "left_s3_key"),
        "right": ("right_s3_bucket", "right_s3_key"),
    }
    images: dict[str, bytes] = {}
    for view, (bucket_key, object_key) in sources.items():
        bucket = job.get(bucket_key)
        key = job.get(object_key)
        if not bucket or not key:
            raise RuntimeError(f"Missing {view} source image for Hunyuan multiview job")
        images[view] = download_object_bytes(bucket=bucket, key=key)
    return images


def process_job(job: dict) -> None:
    job_id = str(job["id"])
    provider = str(job.get("provider") or "varco").lower()
    generation_mode = str(job.get("generation_mode") or "single").lower()
    logger.info(
        "Processing generation job %s provider=%s mode=%s",
        job_id,
        provider,
        generation_mode,
    )

    if settings.mock_varco:
        provider_request_id = f"mock-{provider}-{job_id}"
        update_provider_request_id(job_id, provider_request_id)
        model_bytes = create_mock_glb()
        logger.info("MOCK_VARCO enabled. Created mock model for job %s", job_id)
    elif provider == "hunyuan" or generation_mode == "multiview":
        provider_request_id = f"hunyuan-{job_id}"
        update_provider_request_id(job_id, provider_request_id)
        update_job_status(job_id, "submitted")
        images = _download_hunyuan_multiview_images(job)
        model_bytes = hunyuan_service.generate_multiview_model(images)
        update_job_status(job_id, "processing")
    else:
        source_image_bytes = download_object_bytes(
            bucket=job["source_s3_bucket"],
            key=job["source_s3_key"],
        )
        image_bytes, filename, content_type = varco_service.prepare_image_for_submission(
            source_image_bytes,
            job["source_s3_key"],
        )
        provider_request_id = varco_service.submit_image_to_3d(
            image_bytes,
            filename=filename,
            content_type=content_type,
        )
        update_provider_request_id(job_id, provider_request_id)
        update_job_status(job_id, "submitted")

        model_url = wait_for_varco_model(provider_request_id)
        update_job_status(job_id, "processing")
        model_bytes = varco_service.download_file(model_url)

    asset_id = str(uuid4())
    model_key = furniture_asset_model_key(str(job["user_id"]), asset_id)
    upload_model_bytes(settings.s3_bucket, model_key, model_bytes)
    complete_job_with_asset(job, asset_id, model_key)
    logger.info("Generation job %s succeeded with asset %s", job_id, asset_id)


def run_forever() -> None:
    logger.info("Worker started. MOCK_VARCO=%s", settings.mock_varco)
    while True:
        job = None
        try:
            job = claim_queued_job()
            if job is None:
                time.sleep(settings.worker_poll_seconds)
                continue
            process_job(job)
        except Exception as exc:
            logger.exception("Worker failed while processing job")
            if job is not None:
                mark_job_failed(str(job["id"]), str(exc))
            time.sleep(settings.worker_poll_seconds)


if __name__ == "__main__":
    run_forever()

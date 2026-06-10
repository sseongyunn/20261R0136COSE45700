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
from app.services.image_preprocess_service import ProcessedImage, preprocess_image_group
from app.services.render_profile_service import analyze_render_profile
from app.services.s3_service import (
    download_object_bytes,
    furniture_asset_model_key,
    processed_source_image_key,
    upload_image_bytes,
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

RENDER_PROFILE_INPUT_COLUMNS = {
    "source_profile_id": None,
    "source_original_mean_r": None,
    "source_original_mean_g": None,
    "source_original_mean_b": None,
    "source_original_luminance_mean": None,
    "source_original_saturation_mean": None,
    "source_processed_mean_r": None,
    "source_processed_mean_g": None,
    "source_processed_mean_b": None,
    "source_processed_luminance_mean": None,
    "source_processed_saturation_mean": None,
    "preprocess_target_luminance": None,
    "preprocess_exposure_gain": None,
    "preprocess_gamma": None,
    "preprocess_saturation_gain": None,
    "preprocess_contrast_gain": None,
    "preprocess_red_gain": None,
    "preprocess_green_gain": None,
    "preprocess_blue_gain": None,
}


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


def complete_job_with_asset(
    job: dict,
    asset_id: str,
    model_key: str,
    render_profile: Optional[dict] = None,
) -> None:
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
            if render_profile is not None:
                db.execute(
                    text(
                        """
                        INSERT INTO asset_render_profiles (
                            asset_id,
                            user_id,
                            source_profile_id,
                            profile_version,
                            source,
                            albedo_mean_r,
                            albedo_mean_g,
                            albedo_mean_b,
                            texture_luminance_mean,
                            texture_saturation_mean,
                            roughness_mean,
                            metallic_mean,
                            source_original_mean_r,
                            source_original_mean_g,
                            source_original_mean_b,
                            source_original_luminance_mean,
                            source_original_saturation_mean,
                            source_processed_mean_r,
                            source_processed_mean_g,
                            source_processed_mean_b,
                            source_processed_luminance_mean,
                            source_processed_saturation_mean,
                            preprocess_target_luminance,
                            preprocess_exposure_gain,
                            preprocess_gamma,
                            preprocess_saturation_gain,
                            preprocess_contrast_gain,
                            preprocess_red_gain,
                            preprocess_green_gain,
                            preprocess_blue_gain,
                            suggested_exposure_gain,
                            suggested_emissive_lift,
                            has_embedded_textures,
                            has_external_textures,
                            has_normal_map,
                            has_occlusion_map,
                            has_emissive,
                            material_count,
                            texture_count,
                            notes
                        )
                        VALUES (
                            :asset_id,
                            :user_id,
                            :source_profile_id,
                            :profile_version,
                            :source,
                            :albedo_mean_r,
                            :albedo_mean_g,
                            :albedo_mean_b,
                            :texture_luminance_mean,
                            :texture_saturation_mean,
                            :roughness_mean,
                            :metallic_mean,
                            :source_original_mean_r,
                            :source_original_mean_g,
                            :source_original_mean_b,
                            :source_original_luminance_mean,
                            :source_original_saturation_mean,
                            :source_processed_mean_r,
                            :source_processed_mean_g,
                            :source_processed_mean_b,
                            :source_processed_luminance_mean,
                            :source_processed_saturation_mean,
                            :preprocess_target_luminance,
                            :preprocess_exposure_gain,
                            :preprocess_gamma,
                            :preprocess_saturation_gain,
                            :preprocess_contrast_gain,
                            :preprocess_red_gain,
                            :preprocess_green_gain,
                            :preprocess_blue_gain,
                            :suggested_exposure_gain,
                            :suggested_emissive_lift,
                            :has_embedded_textures,
                            :has_external_textures,
                            :has_normal_map,
                            :has_occlusion_map,
                            :has_emissive,
                            :material_count,
                            :texture_count,
                            :notes
                        )
                        ON CONFLICT (asset_id) DO UPDATE SET
                            source_profile_id = EXCLUDED.source_profile_id,
                            profile_version = EXCLUDED.profile_version,
                            source = EXCLUDED.source,
                            albedo_mean_r = EXCLUDED.albedo_mean_r,
                            albedo_mean_g = EXCLUDED.albedo_mean_g,
                            albedo_mean_b = EXCLUDED.albedo_mean_b,
                            texture_luminance_mean = EXCLUDED.texture_luminance_mean,
                            texture_saturation_mean = EXCLUDED.texture_saturation_mean,
                            roughness_mean = EXCLUDED.roughness_mean,
                            metallic_mean = EXCLUDED.metallic_mean,
                            source_original_mean_r = EXCLUDED.source_original_mean_r,
                            source_original_mean_g = EXCLUDED.source_original_mean_g,
                            source_original_mean_b = EXCLUDED.source_original_mean_b,
                            source_original_luminance_mean = EXCLUDED.source_original_luminance_mean,
                            source_original_saturation_mean = EXCLUDED.source_original_saturation_mean,
                            source_processed_mean_r = EXCLUDED.source_processed_mean_r,
                            source_processed_mean_g = EXCLUDED.source_processed_mean_g,
                            source_processed_mean_b = EXCLUDED.source_processed_mean_b,
                            source_processed_luminance_mean = EXCLUDED.source_processed_luminance_mean,
                            source_processed_saturation_mean = EXCLUDED.source_processed_saturation_mean,
                            preprocess_target_luminance = EXCLUDED.preprocess_target_luminance,
                            preprocess_exposure_gain = EXCLUDED.preprocess_exposure_gain,
                            preprocess_gamma = EXCLUDED.preprocess_gamma,
                            preprocess_saturation_gain = EXCLUDED.preprocess_saturation_gain,
                            preprocess_contrast_gain = EXCLUDED.preprocess_contrast_gain,
                            preprocess_red_gain = EXCLUDED.preprocess_red_gain,
                            preprocess_green_gain = EXCLUDED.preprocess_green_gain,
                            preprocess_blue_gain = EXCLUDED.preprocess_blue_gain,
                            suggested_exposure_gain = EXCLUDED.suggested_exposure_gain,
                            suggested_emissive_lift = EXCLUDED.suggested_emissive_lift,
                            has_embedded_textures = EXCLUDED.has_embedded_textures,
                            has_external_textures = EXCLUDED.has_external_textures,
                            has_normal_map = EXCLUDED.has_normal_map,
                            has_occlusion_map = EXCLUDED.has_occlusion_map,
                            has_emissive = EXCLUDED.has_emissive,
                            material_count = EXCLUDED.material_count,
                            texture_count = EXCLUDED.texture_count,
                            notes = EXCLUDED.notes,
                            updated_at = now()
                        """
                    ),
                    {
                        **RENDER_PROFILE_INPUT_COLUMNS,
                        **render_profile,
                        "asset_id": asset_id,
                        "user_id": str(job["user_id"]),
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


def _stats_columns(prefix: str, stats) -> dict[str, Optional[float]]:
    return {
        f"{prefix}_mean_r": stats.mean_r if stats else None,
        f"{prefix}_mean_g": stats.mean_g if stats else None,
        f"{prefix}_mean_b": stats.mean_b if stats else None,
        f"{prefix}_luminance_mean": stats.luminance if stats else None,
        f"{prefix}_saturation_mean": stats.saturation if stats else None,
    }


def _input_profile_payload(profile_id: str, processed: ProcessedImage) -> dict[str, object]:
    transform = processed.transform
    return {
        "source_profile_id": profile_id,
        **_stats_columns("source_original", processed.original_stats),
        **_stats_columns("source_processed", processed.processed_stats),
        "preprocess_target_luminance": transform.target_luminance,
        "preprocess_exposure_gain": transform.exposure_gain,
        "preprocess_gamma": transform.gamma,
        "preprocess_saturation_gain": transform.saturation_gain,
        "preprocess_contrast_gain": transform.contrast_gain,
        "preprocess_red_gain": transform.red_gain,
        "preprocess_green_gain": transform.green_gain,
        "preprocess_blue_gain": transform.blue_gain,
    }


def save_source_preprocess_profile(
    *,
    job: dict,
    source_image_id: str,
    view_label: str,
    original_bucket: str,
    original_key: str,
    processed_key: str,
    processed: ProcessedImage,
) -> str:
    transform = processed.transform
    params = {
        "user_id": str(job["user_id"]),
        "source_image_id": source_image_id,
        "job_id": str(job["id"]),
        "view_label": view_label,
        "preprocess_version": 1,
        "original_s3_bucket": original_bucket,
        "original_s3_key": original_key,
        "processed_s3_bucket": settings.s3_bucket,
        "processed_s3_key": processed_key,
        **_stats_columns("original", processed.original_stats),
        **_stats_columns("processed", processed.processed_stats),
        "target_luminance": transform.target_luminance,
        "exposure_gain": transform.exposure_gain,
        "gamma": transform.gamma,
        "saturation_gain": transform.saturation_gain,
        "contrast_gain": transform.contrast_gain,
        "red_gain": transform.red_gain,
        "green_gain": transform.green_gain,
        "blue_gain": transform.blue_gain,
        "notes": processed.notes,
    }
    with SessionLocal() as db:
        row = db.execute(
            text(
                """
                INSERT INTO source_image_preprocess_profiles (
                    user_id,
                    source_image_id,
                    generation_job_id,
                    view_label,
                    preprocess_version,
                    original_s3_bucket,
                    original_s3_key,
                    processed_s3_bucket,
                    processed_s3_key,
                    original_mean_r,
                    original_mean_g,
                    original_mean_b,
                    original_luminance_mean,
                    original_saturation_mean,
                    processed_mean_r,
                    processed_mean_g,
                    processed_mean_b,
                    processed_luminance_mean,
                    processed_saturation_mean,
                    target_luminance,
                    exposure_gain,
                    gamma,
                    saturation_gain,
                    contrast_gain,
                    red_gain,
                    green_gain,
                    blue_gain,
                    notes
                )
                VALUES (
                    :user_id,
                    :source_image_id,
                    :job_id,
                    :view_label,
                    :preprocess_version,
                    :original_s3_bucket,
                    :original_s3_key,
                    :processed_s3_bucket,
                    :processed_s3_key,
                    :original_mean_r,
                    :original_mean_g,
                    :original_mean_b,
                    :original_luminance_mean,
                    :original_saturation_mean,
                    :processed_mean_r,
                    :processed_mean_g,
                    :processed_mean_b,
                    :processed_luminance_mean,
                    :processed_saturation_mean,
                    :target_luminance,
                    :exposure_gain,
                    :gamma,
                    :saturation_gain,
                    :contrast_gain,
                    :red_gain,
                    :green_gain,
                    :blue_gain,
                    :notes
                )
                ON CONFLICT (generation_job_id, source_image_id, view_label)
                DO UPDATE SET
                    preprocess_version = EXCLUDED.preprocess_version,
                    original_s3_bucket = EXCLUDED.original_s3_bucket,
                    original_s3_key = EXCLUDED.original_s3_key,
                    processed_s3_bucket = EXCLUDED.processed_s3_bucket,
                    processed_s3_key = EXCLUDED.processed_s3_key,
                    original_mean_r = EXCLUDED.original_mean_r,
                    original_mean_g = EXCLUDED.original_mean_g,
                    original_mean_b = EXCLUDED.original_mean_b,
                    original_luminance_mean = EXCLUDED.original_luminance_mean,
                    original_saturation_mean = EXCLUDED.original_saturation_mean,
                    processed_mean_r = EXCLUDED.processed_mean_r,
                    processed_mean_g = EXCLUDED.processed_mean_g,
                    processed_mean_b = EXCLUDED.processed_mean_b,
                    processed_luminance_mean = EXCLUDED.processed_luminance_mean,
                    processed_saturation_mean = EXCLUDED.processed_saturation_mean,
                    target_luminance = EXCLUDED.target_luminance,
                    exposure_gain = EXCLUDED.exposure_gain,
                    gamma = EXCLUDED.gamma,
                    saturation_gain = EXCLUDED.saturation_gain,
                    contrast_gain = EXCLUDED.contrast_gain,
                    red_gain = EXCLUDED.red_gain,
                    green_gain = EXCLUDED.green_gain,
                    blue_gain = EXCLUDED.blue_gain,
                    notes = EXCLUDED.notes,
                    updated_at = now()
                RETURNING id
                """
            ),
            params,
        ).mappings().one()
        db.commit()
        return str(row["id"])


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


def _front_source(job: dict, image_bytes: bytes) -> dict[str, object]:
    return {
        "source_image_id": str(job["source_image_id"]),
        "bucket": job["source_s3_bucket"],
        "key": job["source_s3_key"],
        "bytes": image_bytes,
    }


def _hunyuan_sources(job: dict) -> dict[str, dict[str, object]]:
    with SessionLocal() as db:
        rows = db.execute(
            text(
                """
                SELECT
                    gjsi.source_image_id,
                    gjsi.view_label,
                    si.s3_bucket,
                    si.s3_key
                FROM generation_job_source_images gjsi
                JOIN source_images si ON si.id = gjsi.source_image_id
                WHERE gjsi.generation_job_id = :job_id
                ORDER BY gjsi.sort_order ASC, gjsi.created_at ASC
                """
            ),
            {"job_id": str(job["id"])},
        ).mappings().all()

    if rows:
        sources: dict[str, dict[str, object]] = {}
        for index, row in enumerate(rows):
            view = str(row["view_label"] or "unknown")
            if view in sources:
                view = f"{view}_{index}"
            bucket = row["s3_bucket"]
            key = row["s3_key"]
            sources[view] = {
                "source_image_id": str(row["source_image_id"]),
                "bucket": bucket,
                "key": key,
                "bytes": download_object_bytes(bucket=bucket, key=key),
            }
        return sources

    mapping = {
        "front": ("source_image_id", "source_s3_bucket", "source_s3_key"),
        "back": ("source_back_image_id", "back_s3_bucket", "back_s3_key"),
        "left": ("source_left_image_id", "left_s3_bucket", "left_s3_key"),
        "right": ("source_right_image_id", "right_s3_bucket", "right_s3_key"),
    }
    sources: dict[str, dict[str, object]] = {}
    for view, (id_key, bucket_key, object_key) in mapping.items():
        source_image_id = job.get(id_key)
        bucket = job.get(bucket_key)
        key = job.get(object_key)
        if not source_image_id or not bucket or not key:
            continue
        sources[view] = {
            "source_image_id": str(source_image_id),
            "bucket": bucket,
            "key": key,
            "bytes": download_object_bytes(bucket=bucket, key=key),
        }
    if not sources:
        raise RuntimeError("Missing source images for Hunyuan multiview job")
    return sources


def _preprocess_and_store_sources(
    job: dict,
    sources: dict[str, dict[str, object]],
) -> dict[str, dict[str, object]]:
    if not settings.preprocess_images:
        return {
            view: {
                **source,
                "processed_bytes": source["bytes"],
                "processed": None,
                "profile_id": None,
            }
            for view, source in sources.items()
        }

    raw_images = {
        view: source["bytes"]
        for view, source in sources.items()
        if isinstance(source.get("bytes"), bytes)
    }
    processed_images = preprocess_image_group(raw_images)
    output: dict[str, dict[str, object]] = {}

    for view, source in sources.items():
        processed = processed_images[view]
        source_image_id = str(source["source_image_id"])
        processed_key = processed_source_image_key(
            str(job["user_id"]),
            source_image_id,
            view,
        )
        upload_image_bytes(settings.s3_bucket, processed_key, processed.image_bytes)
        profile_id = save_source_preprocess_profile(
            job=job,
            source_image_id=source_image_id,
            view_label=view,
            original_bucket=str(source["bucket"]),
            original_key=str(source["key"]),
            processed_key=processed_key,
            processed=processed,
        )
        output[view] = {
            **source,
            "processed_bytes": processed.image_bytes,
            "processed": processed,
            "profile_id": profile_id,
            "processed_key": processed_key,
        }

    return output


def _render_input_profile(source: Optional[dict[str, object]]) -> Optional[dict[str, object]]:
    if not source:
        return None
    processed = source.get("processed")
    profile_id = source.get("profile_id")
    if not isinstance(processed, ProcessedImage) or not isinstance(profile_id, str):
        return None
    return _input_profile_payload(profile_id, processed)


def process_job(job: dict) -> None:
    job_id = str(job["id"])
    provider = str(job.get("provider") or "varco").lower()
    generation_mode = str(job.get("generation_mode") or "single").lower()
    profile_source_image_bytes: Optional[bytes] = None
    input_color_profile: Optional[dict[str, object]] = None
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
        try:
            source_image_bytes = download_object_bytes(
                bucket=job["source_s3_bucket"],
                key=job["source_s3_key"],
            )
            sources = _preprocess_and_store_sources(
                job,
                {"front": _front_source(job, source_image_bytes)},
            )
            profile_source_image_bytes = sources["front"]["processed_bytes"]
            input_color_profile = _render_input_profile(sources["front"])
        except Exception:
            logger.warning("Could not load source image for mock render profile", exc_info=True)
        logger.info("MOCK_VARCO enabled. Created mock model for job %s", job_id)
    elif provider == "hunyuan" or generation_mode == "multiview":
        provider_request_id = f"hunyuan-{job_id}"
        update_provider_request_id(job_id, provider_request_id)
        update_job_status(job_id, "submitted")
        sources = _preprocess_and_store_sources(job, _hunyuan_sources(job))
        view_images = [
            {
                "source_image_id": source["source_image_id"],
                "view": view,
                "image": source["processed_bytes"],
            }
            for view, source in sources.items()
            if isinstance(source.get("processed_bytes"), bytes)
        ]
        profile_source_image_bytes = next(
            (
                item["image"]
                for item in view_images
                if item["view"] == "front" and isinstance(item.get("image"), bytes)
            ),
            view_images[0]["image"] if view_images else None,
        )
        profile_source = sources.get("front") or next(iter(sources.values()), None)
        input_color_profile = _render_input_profile(profile_source)
        model_bytes = hunyuan_service.generate_multiview_model(view_images)
        update_job_status(job_id, "processing")
    else:
        source_image_bytes = download_object_bytes(
            bucket=job["source_s3_bucket"],
            key=job["source_s3_key"],
        )
        sources = _preprocess_and_store_sources(
            job,
            {"front": _front_source(job, source_image_bytes)},
        )
        profile_source_image_bytes = sources["front"]["processed_bytes"]
        input_color_profile = _render_input_profile(sources["front"])
        image_bytes, filename, content_type = varco_service.prepare_image_for_submission(
            profile_source_image_bytes,
            "normalized-front.png",
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
    render_profile = analyze_render_profile(
        model_bytes,
        source_image_bytes=profile_source_image_bytes,
        input_color_profile=input_color_profile,
    )
    upload_model_bytes(settings.s3_bucket, model_key, model_bytes)
    complete_job_with_asset(job, asset_id, model_key, render_profile=render_profile)
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

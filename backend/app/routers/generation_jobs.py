from __future__ import annotations

from datetime import datetime
from typing import Annotated, List, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import settings
from app.database import get_db
from app.deps import get_current_user


router = APIRouter(prefix="/generation-jobs", tags=["generation-jobs"])

CANONICAL_VIEWS = {"front", "back", "left", "right"}
SUPPORTED_VIEW_LABELS = CANONICAL_VIEWS | {
    "front_left",
    "front_right",
    "back_left",
    "back_right",
    "left_front",
    "right_front",
    "left_back",
    "right_back",
    "side_left",
    "side_right",
    "top",
    "bottom",
    "detail",
    "extra",
    "unknown",
}


class GenerationJobSourceImageRequest(BaseModel):
    sourceImageId: str
    view: str = Field(default="unknown", max_length=50)


class CreateGenerationJobRequest(BaseModel):
    sourceImageId: str
    generationMode: Literal["single", "multiview"] = "single"
    backSourceImageId: Optional[str] = None
    leftSourceImageId: Optional[str] = None
    rightSourceImageId: Optional[str] = None
    viewImages: Optional[List[GenerationJobSourceImageRequest]] = None
    name: Optional[str] = Field(default=None, max_length=200)
    category: Optional[str] = Field(default=None, max_length=100)
    widthCm: Optional[float] = Field(default=None, gt=0)
    heightCm: Optional[float] = Field(default=None, gt=0)
    depthCm: Optional[float] = Field(default=None, gt=0)


class CreateGenerationJobResponse(BaseModel):
    jobId: str
    status: str


class GenerationJobResponse(BaseModel):
    jobId: str
    status: str
    provider: Optional[str] = None
    generationMode: Optional[str] = None
    providerRequestId: Optional[str]
    assetId: Optional[str]
    requestedName: Optional[str] = None
    requestedCategory: Optional[str] = None
    failureReason: Optional[str] = None
    queuedAt: Optional[str] = None
    startedAt: Optional[str] = None
    completedAt: Optional[str] = None
    failedAt: Optional[str] = None


def _iso(value: Optional[datetime]) -> Optional[str]:
    return value.isoformat() if value else None


def _numeric(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    return float(value)


def _normalize_view_label(value: Optional[str]) -> str:
    view = (value or "unknown").strip().lower().replace("-", "_")
    if view not in SUPPORTED_VIEW_LABELS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported view label: {value}",
        )
    return view


def _canonical_view_for_label(view_label: str) -> Optional[str]:
    if view_label in CANONICAL_VIEWS:
        return view_label
    return None


def _require_owned_source_image(db: Session, source_image_id: str, user_id: str) -> None:
    row = db.execute(
        text(
            """
            SELECT id
            FROM source_images
            WHERE id = :source_image_id AND user_id = :user_id
            """
        ),
        {"source_image_id": source_image_id, "user_id": user_id},
    ).mappings().first()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Source image not found")


def _enforce_generation_job_quota(db: Session, user_id: str) -> None:
    db.execute(
        text("SELECT pg_advisory_xact_lock(457, hashtext(:user_id))"),
        {"user_id": user_id},
    )
    row = db.execute(
        text(
            """
            SELECT
                COUNT(*) FILTER (
                    WHERE queued_at >= now() - interval '1 hour'
                ) AS jobs_last_hour,
                COUNT(*) AS jobs_last_day
            FROM generation_jobs
            WHERE user_id = :user_id
              AND queued_at >= now() - interval '1 day'
            """
        ),
        {"user_id": user_id},
    ).mappings().one()

    jobs_last_hour = int(row["jobs_last_hour"] or 0)
    jobs_last_day = int(row["jobs_last_day"] or 0)

    if (
        settings.generation_jobs_per_hour > 0
        and jobs_last_hour >= settings.generation_jobs_per_hour
    ):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=(
                "Generation quota exceeded: "
                f"maximum {settings.generation_jobs_per_hour} jobs per hour per user"
            ),
        )

    if (
        settings.generation_jobs_per_day > 0
        and jobs_last_day >= settings.generation_jobs_per_day
    ):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=(
                "Generation quota exceeded: "
                f"maximum {settings.generation_jobs_per_day} jobs per day per user"
            ),
        )


def _build_multiview_sources(payload: CreateGenerationJobRequest) -> list[dict]:
    if payload.viewImages:
        sources = [
            {
                "source_image_id": image.sourceImageId,
                "view_label": _normalize_view_label(image.view),
                "is_primary": False,
            }
            for image in payload.viewImages
        ]
        if not any(item["source_image_id"] == payload.sourceImageId for item in sources):
            sources.insert(
                0,
                {
                    "source_image_id": payload.sourceImageId,
                    "view_label": "unknown",
                    "is_primary": True,
                },
            )
        else:
            for item in sources:
                if item["source_image_id"] == payload.sourceImageId:
                    item["is_primary"] = True
                    break
    else:
        legacy_sources = {
            "front": payload.sourceImageId,
            "back": payload.backSourceImageId,
            "left": payload.leftSourceImageId,
            "right": payload.rightSourceImageId,
        }
        missing = [view for view, source_image_id in legacy_sources.items() if not source_image_id]
        if missing:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Missing multiview source images: {', '.join(missing)}",
            )
        sources = [
            {
                "source_image_id": source_image_id,
                "view_label": view,
                "is_primary": view == "front",
            }
            for view, source_image_id in legacy_sources.items()
            if source_image_id
        ]

    if not sources:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="At least one multiview source image is required.",
        )

    seen = set()
    unique_sources = []
    for item in sources:
        key = (item["source_image_id"], item["view_label"])
        if key in seen:
            continue
        seen.add(key)
        unique_sources.append(item)
    return unique_sources


@router.post("", response_model=CreateGenerationJobResponse)
def create_generation_job(
    payload: CreateGenerationJobRequest,
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> CreateGenerationJobResponse:
    _enforce_generation_job_quota(db, current_user["id"])
    _require_owned_source_image(db, payload.sourceImageId, current_user["id"])

    provider = "varco"
    back_source_image_id = None
    left_source_image_id = None
    right_source_image_id = None
    multiview_sources: list[dict] = []

    if payload.generationMode == "multiview":
        multiview_sources = _build_multiview_sources(payload)
        source_by_view = {
            item["view_label"]: item["source_image_id"]
            for item in multiview_sources
            if item["view_label"] in CANONICAL_VIEWS
        }
        back_source_image_id = payload.backSourceImageId
        left_source_image_id = payload.leftSourceImageId
        right_source_image_id = payload.rightSourceImageId
        if payload.viewImages:
            back_source_image_id = source_by_view.get("back")
            left_source_image_id = source_by_view.get("left")
            right_source_image_id = source_by_view.get("right")

        for source_image_id in {item["source_image_id"] for item in multiview_sources}:
            _require_owned_source_image(db, source_image_id, current_user["id"])
        provider = "hunyuan"

    row = db.execute(
        text(
            """
            INSERT INTO generation_jobs (
                user_id,
                source_image_id,
                source_back_image_id,
                source_left_image_id,
                source_right_image_id,
                generation_mode,
                provider,
                status,
                requested_name,
                requested_category,
                requested_width_cm,
                requested_height_cm,
                requested_depth_cm
            )
            VALUES (
                :user_id,
                :source_image_id,
                :source_back_image_id,
                :source_left_image_id,
                :source_right_image_id,
                :generation_mode,
                :provider,
                'queued',
                :name,
                :category,
                :width_cm,
                :height_cm,
                :depth_cm
            )
            RETURNING id, status
            """
        ),
        {
            "user_id": current_user["id"],
            "source_image_id": payload.sourceImageId,
            "source_back_image_id": back_source_image_id,
            "source_left_image_id": left_source_image_id,
            "source_right_image_id": right_source_image_id,
            "generation_mode": payload.generationMode,
            "provider": provider,
            "name": payload.name,
            "category": payload.category,
            "width_cm": _numeric(payload.widthCm),
            "height_cm": _numeric(payload.heightCm),
            "depth_cm": _numeric(payload.depthCm),
        },
    ).mappings().one()

    if multiview_sources:
        for sort_order, item in enumerate(multiview_sources):
            db.execute(
                text(
                    """
                    INSERT INTO generation_job_source_images (
                        generation_job_id,
                        source_image_id,
                        view_label,
                        sort_order,
                        is_primary
                    )
                    VALUES (
                        :job_id,
                        :source_image_id,
                        :view_label,
                        :sort_order,
                        :is_primary
                    )
                    ON CONFLICT (generation_job_id, source_image_id, view_label)
                    DO NOTHING
                    """
                ),
                {
                    "job_id": str(row["id"]),
                    "source_image_id": item["source_image_id"],
                    "view_label": item["view_label"],
                    "sort_order": sort_order,
                    "is_primary": item["is_primary"],
                },
            )
    db.commit()

    return CreateGenerationJobResponse(jobId=str(row["id"]), status=row["status"])


@router.get("/{job_id}", response_model=GenerationJobResponse)
def get_generation_job(
    job_id: str,
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> GenerationJobResponse:
    row = db.execute(
        text(
            """
            SELECT
                j.id,
                j.status,
                j.provider,
                j.generation_mode,
                j.provider_request_id,
                j.requested_name,
                j.requested_category,
                j.failure_reason,
                j.queued_at,
                j.started_at,
                j.completed_at,
                j.failed_at,
                a.id AS asset_id
            FROM generation_jobs j
            LEFT JOIN furniture_assets a ON a.generation_job_id = j.id
            WHERE j.id = :job_id AND j.user_id = :user_id
            """
        ),
        {"job_id": job_id, "user_id": current_user["id"]},
    ).mappings().first()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Generation job not found")

    return GenerationJobResponse(
        jobId=str(row["id"]),
        status=row["status"],
        provider=row["provider"],
        generationMode=row["generation_mode"],
        providerRequestId=row["provider_request_id"],
        assetId=str(row["asset_id"]) if row["asset_id"] else None,
        requestedName=row["requested_name"],
        requestedCategory=row["requested_category"],
        failureReason=row["failure_reason"],
        queuedAt=_iso(row["queued_at"]),
        startedAt=_iso(row["started_at"]),
        completedAt=_iso(row["completed_at"]),
        failedAt=_iso(row["failed_at"]),
    )

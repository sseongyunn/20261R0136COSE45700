from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.database import get_db
from app.deps import get_current_user


router = APIRouter(prefix="/generation-jobs", tags=["generation-jobs"])


class CreateGenerationJobRequest(BaseModel):
    sourceImageId: str
    generationMode: Literal["single", "multiview"] = "single"
    backSourceImageId: Optional[str] = None
    leftSourceImageId: Optional[str] = None
    rightSourceImageId: Optional[str] = None
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


@router.post("", response_model=CreateGenerationJobResponse)
def create_generation_job(
    payload: CreateGenerationJobRequest,
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> CreateGenerationJobResponse:
    _require_owned_source_image(db, payload.sourceImageId, current_user["id"])

    provider = "varco"
    back_source_image_id = None
    left_source_image_id = None
    right_source_image_id = None

    if payload.generationMode == "multiview":
        required_views = {
            "backSourceImageId": payload.backSourceImageId,
            "leftSourceImageId": payload.leftSourceImageId,
            "rightSourceImageId": payload.rightSourceImageId,
        }
        missing = [name for name, value in required_views.items() if not value]
        if missing:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Missing multiview source images: {', '.join(missing)}",
            )
        back_source_image_id = payload.backSourceImageId
        left_source_image_id = payload.leftSourceImageId
        right_source_image_id = payload.rightSourceImageId
        for source_image_id in (
            back_source_image_id,
            left_source_image_id,
            right_source_image_id,
        ):
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

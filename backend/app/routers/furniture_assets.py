from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Annotated, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import settings
from app.database import get_db
from app.deps import get_current_user
from app.services.s3_service import create_presigned_download_url


router = APIRouter(prefix="/furniture-assets", tags=["furniture-assets"])


class FurnitureAssetResponse(BaseModel):
    assetId: str
    generationJobId: str
    name: Optional[str]
    category: Optional[str]
    widthCm: Optional[float]
    heightCm: Optional[float]
    depthCm: Optional[float]
    modelS3Bucket: str
    modelS3Key: str
    createdAt: str
    updatedAt: str


class ModelUrlResponse(BaseModel):
    modelUrl: str


def _to_float(value: Optional[Decimal]) -> Optional[float]:
    return float(value) if value is not None else None


def _iso(value: datetime) -> str:
    return value.isoformat()


def _asset_response(row: dict) -> FurnitureAssetResponse:
    return FurnitureAssetResponse(
        assetId=str(row["id"]),
        generationJobId=str(row["generation_job_id"]),
        name=row["name"],
        category=row["category"],
        widthCm=_to_float(row["width_cm"]),
        heightCm=_to_float(row["height_cm"]),
        depthCm=_to_float(row["depth_cm"]),
        modelS3Bucket=row["model_s3_bucket"],
        modelS3Key=row["model_s3_key"],
        createdAt=_iso(row["created_at"]),
        updatedAt=_iso(row["updated_at"]),
    )


@router.get("", response_model=List[FurnitureAssetResponse])
def list_furniture_assets(
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> List[FurnitureAssetResponse]:
    rows = db.execute(
        text(
            """
            SELECT
                id,
                generation_job_id,
                name,
                category,
                width_cm,
                height_cm,
                depth_cm,
                model_s3_bucket,
                model_s3_key,
                created_at,
                updated_at
            FROM furniture_assets
            WHERE user_id = :user_id
            ORDER BY created_at DESC
            """
        ),
        {"user_id": current_user["id"]},
    ).mappings().all()

    return [_asset_response(dict(row)) for row in rows]


@router.get("/{asset_id}/model-url", response_model=ModelUrlResponse)
def get_model_url(
    asset_id: str,
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> ModelUrlResponse:
    row = db.execute(
        text(
            """
            SELECT model_s3_bucket, model_s3_key
            FROM furniture_assets
            WHERE id = :asset_id AND user_id = :user_id
            """
        ),
        {"asset_id": asset_id, "user_id": current_user["id"]},
    ).mappings().first()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Furniture asset not found")

    model_url = create_presigned_download_url(
        bucket=row["model_s3_bucket"],
        key=row["model_s3_key"],
        expires_in=settings.download_url_expire_seconds,
    )
    return ModelUrlResponse(modelUrl=model_url)

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from botocore.exceptions import ClientError
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.config import settings
from app.database import get_db
from app.deps import get_current_user
from app.services.s3_service import head_object_metadata


router = APIRouter(prefix="/source-images", tags=["source-images"])

ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp"}


class SourceImageCompleteRequest(BaseModel):
    sourceImageId: str
    s3Bucket: str
    s3Key: str


class SourceImageCompleteResponse(BaseModel):
    sourceImageId: str
    status: str


@router.post("/complete", response_model=SourceImageCompleteResponse)
def complete_source_image_upload(
    payload: SourceImageCompleteRequest,
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> SourceImageCompleteResponse:
    expected_prefix = f"users/{current_user['id']}/source-images/{payload.sourceImageId}/"
    if payload.s3Bucket != settings.s3_bucket:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid S3 bucket")
    if not payload.s3Key.startswith(expected_prefix):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid S3 key")

    try:
        metadata = head_object_metadata(payload.s3Bucket, payload.s3Key)
    except FileNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Uploaded source image was not found in S3",
        ) from exc
    except ClientError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Could not verify uploaded source image",
        ) from exc

    if int(metadata.get("ContentLength") or 0) <= 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Uploaded image is empty")

    content_type = str(metadata.get("ContentType") or "").split(";", 1)[0].lower()
    if content_type not in ALLOWED_CONTENT_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Uploaded object is not a supported image type",
        )

    existing = db.execute(
        text(
            """
            SELECT id, user_id
            FROM source_images
            WHERE id = :id OR (s3_bucket = :bucket AND s3_key = :key)
            """
        ),
        {"id": payload.sourceImageId, "bucket": payload.s3Bucket, "key": payload.s3Key},
    ).mappings().first()

    if existing is not None:
        if str(existing["user_id"]) != current_user["id"]:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not allowed")
        return SourceImageCompleteResponse(sourceImageId=str(existing["id"]), status="completed")

    try:
        db.execute(
            text(
                """
                INSERT INTO source_images (id, user_id, s3_bucket, s3_key)
                VALUES (:id, :user_id, :bucket, :key)
                """
            ),
            {
                "id": payload.sourceImageId,
                "user_id": current_user["id"],
                "bucket": payload.s3Bucket,
                "key": payload.s3Key,
            },
        )
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Source image already exists",
        ) from exc

    return SourceImageCompleteResponse(sourceImageId=payload.sourceImageId, status="completed")

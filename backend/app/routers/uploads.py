from __future__ import annotations

from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.config import settings
from app.deps import get_current_user
from app.services.s3_service import create_presigned_upload_url, source_image_key


router = APIRouter(prefix="/uploads", tags=["uploads"])

ALLOWED_EXTENSIONS = {"jpg", "jpeg", "png", "webp"}
ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp"}


class SourceImageUploadUrlRequest(BaseModel):
    extension: str
    contentType: str


class SourceImageUploadUrlResponse(BaseModel):
    sourceImageId: str
    uploadUrl: str
    s3Bucket: str
    s3Key: str


@router.post("/source-image-url", response_model=SourceImageUploadUrlResponse)
def create_source_image_upload_url(
    payload: SourceImageUploadUrlRequest,
    current_user: Annotated[dict, Depends(get_current_user)],
) -> SourceImageUploadUrlResponse:
    extension = payload.extension.lower().strip().lstrip(".")
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Unsupported image extension",
        )
    if payload.contentType not in ALLOWED_CONTENT_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Unsupported image content type",
        )

    source_image_id = str(uuid4())
    key = source_image_key(current_user["id"], source_image_id, extension)
    upload_url = create_presigned_upload_url(
        bucket=settings.s3_bucket,
        key=key,
        content_type=payload.contentType,
    )
    return SourceImageUploadUrlResponse(
        sourceImageId=source_image_id,
        uploadUrl=upload_url,
        s3Bucket=settings.s3_bucket,
        s3Key=key,
    )

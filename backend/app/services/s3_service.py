from __future__ import annotations

from functools import lru_cache
from typing import Optional

import boto3

from app.config import settings


@lru_cache(maxsize=1)
def s3_client():
    # No explicit credentials are configured here. On EC2, boto3 will use the
    # IAM instance profile attached to the instance.
    return boto3.client("s3", region_name=settings.aws_region)


def source_image_key(user_id: str, source_image_id: str, extension: str) -> str:
    clean_extension = extension.lower().strip().lstrip(".")
    return f"users/{user_id}/source-images/{source_image_id}/input.{clean_extension}"


def processed_source_image_key(user_id: str, source_image_id: str, view_label: str) -> str:
    clean_view = "".join(
        char for char in view_label.lower().strip() if char.isalnum() or char in {"-", "_"}
    )
    if not clean_view:
        clean_view = "front"
    return f"users/{user_id}/source-images/{source_image_id}/normalized-{clean_view}.png"


def furniture_asset_model_key(user_id: str, asset_id: str) -> str:
    return f"users/{user_id}/furniture-assets/{asset_id}/model.glb"


def create_presigned_upload_url(
    bucket: str,
    key: str,
    content_type: str,
    expires_in: Optional[int] = None,
) -> str:
    return s3_client().generate_presigned_url(
        "put_object",
        Params={"Bucket": bucket, "Key": key, "ContentType": content_type},
        ExpiresIn=expires_in or settings.upload_url_expire_seconds,
    )


def create_presigned_download_url(
    bucket: str,
    key: str,
    expires_in: Optional[int] = None,
) -> str:
    return s3_client().generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=expires_in or settings.download_url_expire_seconds,
    )


def upload_model_bytes(bucket: str, key: str, data: bytes) -> None:
    s3_client().put_object(
        Bucket=bucket,
        Key=key,
        Body=data,
        ContentType="model/gltf-binary",
    )


def upload_image_bytes(bucket: str, key: str, data: bytes, content_type: str = "image/png") -> None:
    s3_client().put_object(
        Bucket=bucket,
        Key=key,
        Body=data,
        ContentType=content_type,
    )


def download_object_bytes(bucket: str, key: str) -> bytes:
    response = s3_client().get_object(Bucket=bucket, Key=key)
    return response["Body"].read()

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


class SourceColorProfileResponse(BaseModel):
    sourceProfileId: Optional[str] = None
    originalMeanR: Optional[float] = None
    originalMeanG: Optional[float] = None
    originalMeanB: Optional[float] = None
    originalLuminanceMean: Optional[float] = None
    originalSaturationMean: Optional[float] = None
    processedMeanR: Optional[float] = None
    processedMeanG: Optional[float] = None
    processedMeanB: Optional[float] = None
    processedLuminanceMean: Optional[float] = None
    processedSaturationMean: Optional[float] = None
    targetLuminance: Optional[float] = None
    exposureGain: Optional[float] = None
    gamma: Optional[float] = None
    saturationGain: Optional[float] = None
    contrastGain: Optional[float] = None
    redGain: Optional[float] = None
    greenGain: Optional[float] = None
    blueGain: Optional[float] = None


class AssetRenderProfileResponse(BaseModel):
    profileVersion: int
    source: str
    albedoMeanR: Optional[float] = None
    albedoMeanG: Optional[float] = None
    albedoMeanB: Optional[float] = None
    textureLuminanceMean: Optional[float] = None
    textureSaturationMean: Optional[float] = None
    roughnessMean: Optional[float] = None
    metallicMean: Optional[float] = None
    suggestedExposureGain: float
    suggestedEmissiveLift: float
    hasEmbeddedTextures: bool
    hasExternalTextures: bool
    hasNormalMap: bool
    hasOcclusionMap: bool
    hasEmissive: bool
    materialCount: int
    textureCount: int
    notes: Optional[str] = None
    inputColorProfile: Optional[SourceColorProfileResponse] = None


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
    renderProfile: Optional[AssetRenderProfileResponse] = None


class ModelUrlResponse(BaseModel):
    modelUrl: str


def _to_float(value: Optional[Decimal]) -> Optional[float]:
    return float(value) if value is not None else None


def _iso(value: datetime) -> str:
    return value.isoformat()


def _render_profile_response(row: dict) -> Optional[AssetRenderProfileResponse]:
    if row.get("profile_asset_id") is None:
        return None
    input_color_profile = None
    if row.get("source_profile_id") is not None:
        input_color_profile = SourceColorProfileResponse(
            sourceProfileId=str(row["source_profile_id"]),
            originalMeanR=_to_float(row["source_original_mean_r"]),
            originalMeanG=_to_float(row["source_original_mean_g"]),
            originalMeanB=_to_float(row["source_original_mean_b"]),
            originalLuminanceMean=_to_float(row["source_original_luminance_mean"]),
            originalSaturationMean=_to_float(row["source_original_saturation_mean"]),
            processedMeanR=_to_float(row["source_processed_mean_r"]),
            processedMeanG=_to_float(row["source_processed_mean_g"]),
            processedMeanB=_to_float(row["source_processed_mean_b"]),
            processedLuminanceMean=_to_float(row["source_processed_luminance_mean"]),
            processedSaturationMean=_to_float(row["source_processed_saturation_mean"]),
            targetLuminance=_to_float(row["preprocess_target_luminance"]),
            exposureGain=_to_float(row["preprocess_exposure_gain"]),
            gamma=_to_float(row["preprocess_gamma"]),
            saturationGain=_to_float(row["preprocess_saturation_gain"]),
            contrastGain=_to_float(row["preprocess_contrast_gain"]),
            redGain=_to_float(row["preprocess_red_gain"]),
            greenGain=_to_float(row["preprocess_green_gain"]),
            blueGain=_to_float(row["preprocess_blue_gain"]),
        )
    return AssetRenderProfileResponse(
        profileVersion=int(row["profile_version"]),
        source=row["profile_source"],
        albedoMeanR=_to_float(row["albedo_mean_r"]),
        albedoMeanG=_to_float(row["albedo_mean_g"]),
        albedoMeanB=_to_float(row["albedo_mean_b"]),
        textureLuminanceMean=_to_float(row["texture_luminance_mean"]),
        textureSaturationMean=_to_float(row["texture_saturation_mean"]),
        roughnessMean=_to_float(row["roughness_mean"]),
        metallicMean=_to_float(row["metallic_mean"]),
        suggestedExposureGain=float(row["suggested_exposure_gain"]),
        suggestedEmissiveLift=float(row["suggested_emissive_lift"]),
        hasEmbeddedTextures=bool(row["has_embedded_textures"]),
        hasExternalTextures=bool(row["has_external_textures"]),
        hasNormalMap=bool(row["has_normal_map"]),
        hasOcclusionMap=bool(row["has_occlusion_map"]),
        hasEmissive=bool(row["has_emissive"]),
        materialCount=int(row["material_count"]),
        textureCount=int(row["texture_count"]),
        notes=row["profile_notes"],
        inputColorProfile=input_color_profile,
    )


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
        renderProfile=_render_profile_response(row),
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
                fa.id,
                fa.generation_job_id,
                fa.name,
                fa.category,
                fa.width_cm,
                fa.height_cm,
                fa.depth_cm,
                fa.model_s3_bucket,
                fa.model_s3_key,
                fa.created_at,
                fa.updated_at,
                rp.asset_id AS profile_asset_id,
                rp.source_profile_id,
                rp.profile_version,
                rp.source AS profile_source,
                rp.albedo_mean_r,
                rp.albedo_mean_g,
                rp.albedo_mean_b,
                rp.texture_luminance_mean,
                rp.texture_saturation_mean,
                rp.roughness_mean,
                rp.metallic_mean,
                rp.source_original_mean_r,
                rp.source_original_mean_g,
                rp.source_original_mean_b,
                rp.source_original_luminance_mean,
                rp.source_original_saturation_mean,
                rp.source_processed_mean_r,
                rp.source_processed_mean_g,
                rp.source_processed_mean_b,
                rp.source_processed_luminance_mean,
                rp.source_processed_saturation_mean,
                rp.preprocess_target_luminance,
                rp.preprocess_exposure_gain,
                rp.preprocess_gamma,
                rp.preprocess_saturation_gain,
                rp.preprocess_contrast_gain,
                rp.preprocess_red_gain,
                rp.preprocess_green_gain,
                rp.preprocess_blue_gain,
                rp.suggested_exposure_gain,
                rp.suggested_emissive_lift,
                rp.has_embedded_textures,
                rp.has_external_textures,
                rp.has_normal_map,
                rp.has_occlusion_map,
                rp.has_emissive,
                rp.material_count,
                rp.texture_count,
                rp.notes AS profile_notes
            FROM furniture_assets fa
            LEFT JOIN asset_render_profiles rp ON rp.asset_id = fa.id
            WHERE fa.user_id = :user_id
            ORDER BY fa.created_at DESC
            """
        ),
        {"user_id": current_user["id"]},
    ).mappings().all()

    return [_asset_response(dict(row)) for row in rows]


@router.get("/{asset_id}/render-profile", response_model=AssetRenderProfileResponse)
def get_asset_render_profile(
    asset_id: str,
    current_user: Annotated[dict, Depends(get_current_user)],
    db: Session = Depends(get_db),
) -> AssetRenderProfileResponse:
    row = db.execute(
        text(
            """
            SELECT
                rp.asset_id AS profile_asset_id,
                rp.source_profile_id,
                rp.profile_version,
                rp.source AS profile_source,
                rp.albedo_mean_r,
                rp.albedo_mean_g,
                rp.albedo_mean_b,
                rp.texture_luminance_mean,
                rp.texture_saturation_mean,
                rp.roughness_mean,
                rp.metallic_mean,
                rp.source_original_mean_r,
                rp.source_original_mean_g,
                rp.source_original_mean_b,
                rp.source_original_luminance_mean,
                rp.source_original_saturation_mean,
                rp.source_processed_mean_r,
                rp.source_processed_mean_g,
                rp.source_processed_mean_b,
                rp.source_processed_luminance_mean,
                rp.source_processed_saturation_mean,
                rp.preprocess_target_luminance,
                rp.preprocess_exposure_gain,
                rp.preprocess_gamma,
                rp.preprocess_saturation_gain,
                rp.preprocess_contrast_gain,
                rp.preprocess_red_gain,
                rp.preprocess_green_gain,
                rp.preprocess_blue_gain,
                rp.suggested_exposure_gain,
                rp.suggested_emissive_lift,
                rp.has_embedded_textures,
                rp.has_external_textures,
                rp.has_normal_map,
                rp.has_occlusion_map,
                rp.has_emissive,
                rp.material_count,
                rp.texture_count,
                rp.notes AS profile_notes
            FROM asset_render_profiles rp
            JOIN furniture_assets fa ON fa.id = rp.asset_id
            WHERE rp.asset_id = :asset_id AND fa.user_id = :user_id
            """
        ),
        {"asset_id": asset_id, "user_id": current_user["id"]},
    ).mappings().first()
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Render profile not found")

    profile = _render_profile_response(dict(row))
    if profile is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Render profile not found")
    return profile


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

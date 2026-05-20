#!/usr/bin/env python3
"""
Stage 2: 리뷰 사진 전처리 & 특징 추출

사용자 리뷰 사진은 배경이 복잡하고, 조명이 제각각이며,
가구 이외의 물체도 함께 찍혀 있습니다.
이 단계에서 MASt3R가 처리하기 좋은 형태로 정리합니다.
"""
from __future__ import annotations

import base64
import io
import logging
from dataclasses import dataclass, field
from typing import Optional

import cv2
import numpy as np
from PIL import Image

logger = logging.getLogger("mast3r-pipeline.stage2")

REVIEW_MAX_SIZE = 512
MIN_SHARPNESS = 50.0
MIN_FURNITURE_RATIO = 0.10


@dataclass
class ProcessedReviewImage:
    original_index: int
    pil_image: Image.Image
    np_image: np.ndarray
    sharpness_score: float
    furniture_mask: np.ndarray
    estimated_view: str
    quality_score: float


@dataclass
class Stage2Result:
    valid_images: list[ProcessedReviewImage]
    rejected_indices: list[int]
    summary: dict = field(default_factory=dict)


def _pil_to_np(img: Image.Image) -> np.ndarray:
    return np.array(img.convert("RGB"))


def _compute_sharpness(img_np: np.ndarray) -> float:
    gray = cv2.cvtColor(img_np, cv2.COLOR_RGB2GRAY)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def _remove_background(img_np: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    try:
        import rembg
        rgba = rembg.remove(img_np)
        mask = rgba[:, :, 3] > 127
        return rgba, mask
    except ImportError:
        logger.warning("rembg 미설치 → GrabCut fallback 사용")
        mask = _grabcut_mask(img_np)
        rgba = np.dstack([img_np, (mask * 255).astype(np.uint8)])
        return rgba, mask


def _grabcut_mask(img_np: np.ndarray) -> np.ndarray:
    h, w = img_np.shape[:2]
    bgd_model = np.zeros((1, 65), np.float64)
    fgd_model = np.zeros((1, 65), np.float64)
    rect = (w // 8, h // 8, w * 6 // 8, h * 6 // 8)
    img_bgr = cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR)
    mask = np.zeros((h, w), np.uint8)
    cv2.grabCut(img_bgr, mask, rect, bgd_model, fgd_model, 5, cv2.GC_INIT_WITH_RECT)
    return (mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)


def _estimate_view_angle(img_np: np.ndarray, mask: np.ndarray) -> str:
    coords = np.argwhere(mask)
    if len(coords) == 0:
        return "unknown"
    h_span = coords[:, 0].max() - coords[:, 0].min()
    w_span = coords[:, 1].max() - coords[:, 1].min()
    ratio = w_span / (h_span + 1e-6)
    if ratio > 1.8:
        return "top"
    elif ratio < 0.6:
        return "side_narrow"
    else:
        return "front_or_side"


def _resize_for_mast3r(img: Image.Image, max_size: int = REVIEW_MAX_SIZE) -> Image.Image:
    w, h = img.size
    scale = max_size / max(w, h)
    if scale < 1.0:
        img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
    return img


def run(
    review_images: list[dict],
    min_sharpness: float = MIN_SHARPNESS,
    min_furniture_ratio: float = MIN_FURNITURE_RATIO,
) -> Stage2Result:
    """
    Stage 2 실행: 리뷰 이미지 전처리

    Args:
        review_images: [{"image": bytes|str(base64), "source": "review"}, ...]
        min_sharpness: 최소 선명도 임계값
        min_furniture_ratio: 최소 가구 면적 비율

    Returns:
        Stage2Result (유효 이미지 목록 + 폐기 목록)
    """
    logger.info("Stage 2 시작: 리뷰 이미지 %d장 전처리", len(review_images))
    valid: list[ProcessedReviewImage] = []
    rejected: list[int] = []

    for idx, item in enumerate(review_images):
        raw = item.get("image")
        if isinstance(raw, str):
            raw = base64.b64decode(raw)

        try:
            pil = Image.open(io.BytesIO(raw)).convert("RGB")
            img_np = _pil_to_np(pil)

            sharpness = _compute_sharpness(img_np)
            if sharpness < min_sharpness:
                logger.info("이미지 %d 폐기 (흐림: sharpness=%.1f)", idx, sharpness)
                rejected.append(idx)
                continue

            rgba_np, furniture_mask = _remove_background(img_np)
            furniture_ratio = furniture_mask.mean()

            if furniture_ratio < min_furniture_ratio:
                logger.info("이미지 %d 폐기 (가구 면적 부족: %.1f%%)", idx, furniture_ratio * 100)
                rejected.append(idx)
                continue

            pil_resized = _resize_for_mast3r(
                Image.fromarray(rgba_np[:, :, :3]), REVIEW_MAX_SIZE
            )
            img_np_resized = _pil_to_np(pil_resized)
            estimated_view = _estimate_view_angle(img_np_resized, furniture_mask)

            sharpness_score = min(sharpness / 300.0, 1.0)
            quality = (sharpness_score * 0.6) + (furniture_ratio * 0.4)

            valid.append(
                ProcessedReviewImage(
                    original_index=idx,
                    pil_image=pil_resized,
                    np_image=img_np_resized,
                    sharpness_score=sharpness,
                    furniture_mask=furniture_mask,
                    estimated_view=estimated_view,
                    quality_score=float(quality),
                )
            )
        except Exception as exc:
            logger.warning("이미지 %d 처리 실패: %s", idx, exc)
            rejected.append(idx)

    valid.sort(key=lambda x: x.quality_score, reverse=True)

    result = Stage2Result(
        valid_images=valid,
        rejected_indices=rejected,
        summary={
            "total": len(review_images),
            "valid": len(valid),
            "rejected": len(rejected),
            "avg_quality": float(np.mean([v.quality_score for v in valid])) if valid else 0.0,
        },
    )
    logger.info("Stage 2 완료: 유효=%d/%d, 폐기=%d", len(valid), len(review_images), len(rejected))
    return result

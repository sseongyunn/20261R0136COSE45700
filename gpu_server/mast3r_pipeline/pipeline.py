#!/usr/bin/env python3
"""
MASt3R Pipeline 메인 오케스트레이터

5단계 파이프라인을 순서대로 실행하고 각 단계의 결과를 다음 단계로 전달합니다.
"""
from __future__ import annotations

import base64
import logging
import time
from typing import Optional

from stages import stage1_base, stage2_review, stage3_mast3r, stage4_complete, stage5_post
from stages.stage5_post import PostprocessConfig

logger = logging.getLogger("mast3r-pipeline")


def run_pipeline(
    official_images: list[dict],
    review_images: list[dict],
    remove_background: bool = True,
    target_faces: int = 50_000,
    texture_size: int = 2048,
    octree_resolution: int = 256,
    num_inference_steps: int = 75,
) -> dict:
    """
    전체 5단계 파이프라인을 실행합니다.

    Args:
        official_images: 공식 상품 이미지 목록
            [{"image": bytes|base64str, "view": "front|back|left|right|..."}, ...]
        review_images: 사용자 리뷰 사진 목록
            [{"image": bytes|base64str, "source": "review"}, ...]
        remove_background: 배경 제거 여부
        target_faces: 최종 메쉬 최대 폴리곤 수
        texture_size: 텍스처 해상도 (px)
        octree_resolution: InstantMesh 메쉬 해상도
        num_inference_steps: InstantMesh 추론 스텝 수

    Returns:
        {
            "glb": bytes,
            "stage_times": dict,
            "stage3_summary": dict,
            "warnings": list[str],
        }
    """
    stage_times: dict[str, float] = {}
    warnings: list[str] = []
    t0 = time.monotonic()

    # ── Stage 1: 공식 이미지 → base 3D 메쉬 ────────────────────────────────────
    logger.info("=" * 60)
    logger.info("[Stage 1] 공식 이미지로 기본 3D 자산 생성")
    t1 = time.monotonic()
    base_glb = stage1_base.run(
        official_images=official_images,
        remove_background=remove_background,
        octree_resolution=octree_resolution,
        num_inference_steps=num_inference_steps,
    )
    stage_times["stage1_base"] = time.monotonic() - t1
    logger.info("[Stage 1] 완료 (%.1fs)", stage_times["stage1_base"])

    primary_official_bytes: Optional[bytes] = None
    if official_images:
        raw = official_images[0]["image"]
        primary_official_bytes = base64.b64decode(raw) if isinstance(raw, str) else raw

    # ── Stage 2: 리뷰 사진 전처리 ───────────────────────────────────────────────
    logger.info("=" * 60)
    logger.info("[Stage 2] 리뷰 사진 전처리 (%d장)", len(review_images))
    t2 = time.monotonic()
    stage2_result = stage2_review.run(review_images=review_images)
    stage_times["stage2_review"] = time.monotonic() - t2
    logger.info("[Stage 2] 완료 (%.1fs): 유효=%d/%d",
                stage_times["stage2_review"], len(stage2_result.valid_images), len(review_images))

    if not stage2_result.valid_images:
        warnings.append("유효한 리뷰 이미지가 없습니다. base 메쉬만 후처리 후 반환합니다.")
        logger.warning("리뷰 이미지 없음 → Stage 3/4 건너뜀")
        import numpy as np
        stage3_result = stage3_mast3r.GeometryAnalysis(
            point_cloud=np.zeros((0, 3)),
            point_colors=np.zeros((0, 3)),
            camera_poses=[],
            confidence_maps=[],
            missing_regions=[],
            coverage_ratio=0.0,
            is_reliable=False,
            num_valid_images=0,
        )
        completed_glb = base_glb
    else:
        # ── Stage 3: MASt3R geometry consistency ─────────────────────────────────
        logger.info("=" * 60)
        logger.info("[Stage 3] MASt3R geometry 분석 (%d장)", len(stage2_result.valid_images))
        t3 = time.monotonic()
        stage3_result = stage3_mast3r.run(
            review_images=stage2_result.valid_images,
            base_mesh_glb=base_glb,
        )
        stage_times["stage3_mast3r"] = time.monotonic() - t3
        logger.info("[Stage 3] 완료 (%.1fs): coverage=%.1f%%, %d포인트",
                    stage_times["stage3_mast3r"], stage3_result.coverage_ratio * 100,
                    len(stage3_result.point_cloud))

        if not stage3_result.is_reliable:
            warnings.append(
                f"MASt3R 결과 신뢰도가 낮습니다 "
                f"(포인트 수={len(stage3_result.point_cloud)}, "
                f"이미지={stage3_result.num_valid_images}장). base 메쉬를 기반으로 후처리합니다."
            )

        # ── Stage 4: 누락 부분 보완 ──────────────────────────────────────────────
        logger.info("=" * 60)
        logger.info("[Stage 4] 누락 부분 보완 (coverage=%.1f%%, 누락=%d곳)",
                    stage3_result.coverage_ratio * 100, len(stage3_result.missing_regions))
        t4 = time.monotonic()
        completed_glb = stage4_complete.run(
            base_mesh_glb=base_glb,
            geometry=stage3_result,
            primary_image_bytes=primary_official_bytes,
        )
        stage_times["stage4_complete"] = time.monotonic() - t4
        logger.info("[Stage 4] 완료 (%.1fs)", stage_times["stage4_complete"])

    # ── Stage 5: 최종 후처리 ────────────────────────────────────────────────────
    logger.info("=" * 60)
    logger.info("[Stage 5] 최종 mesh/texture 후처리")
    t5 = time.monotonic()
    final_glb = stage5_post.run(
        mesh_glb=completed_glb,
        config=PostprocessConfig(target_faces=target_faces, texture_size=texture_size),
    )
    stage_times["stage5_post"] = time.monotonic() - t5
    logger.info("[Stage 5] 완료 (%.1fs)", stage_times["stage5_post"])

    total_time = time.monotonic() - t0
    stage_times["total"] = total_time
    logger.info("=" * 60)
    logger.info("파이프라인 완료: 총 %.1f초, 최종 GLB=%d bytes", total_time, len(final_glb))

    return {
        "glb": final_glb,
        "stage_times": stage_times,
        "stage3_summary": stage3_result.summary if hasattr(stage3_result, "summary") else {},
        "warnings": warnings,
    }

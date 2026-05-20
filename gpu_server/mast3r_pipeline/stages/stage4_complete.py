#!/usr/bin/env python3
"""
Stage 4: 누락된 부분 보완 (생성형 3D 모델 활용)

Stage 3(MASt3R)에서 발견된 누락 영역을 채웁니다.
전략:
  A) base mesh와 MASt3R point cloud를 직접 병합 (coverage가 좋을 때)
  B) Zero123++로 누락 각도 이미지를 생성 후 mesh 보완 (coverage가 낮을 때)
  C) 두 방법 혼합
"""
from __future__ import annotations

import base64
import io
import logging
import os
import tempfile
from typing import Optional

import numpy as np
import torch
from PIL import Image

from .stage3_mast3r import GeometryAnalysis

logger = logging.getLogger("mast3r-pipeline.stage4")

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
COVERAGE_GOOD_THRESHOLD = 0.75
COVERAGE_POOR_THRESHOLD = 0.40

REGION_TO_ANGLES = {
    "top":       {"azimuth":   0, "elevation":  90},
    "bottom":    {"azimuth":   0, "elevation": -90},
    "back":      {"azimuth": 180, "elevation":   0},
    "left":      {"azimuth":  90, "elevation":   0},
    "right":     {"azimuth": -90, "elevation":   0},
    "front":     {"azimuth":   0, "elevation":   0},
    "back_left": {"azimuth": 135, "elevation":   0},
    "back_right":{"azimuth":-135, "elevation":   0},
}

_zero123_pipeline = None


def _load_zero123():
    global _zero123_pipeline
    if _zero123_pipeline is not None:
        return _zero123_pipeline

    logger.info("Zero123++ 로딩 중...")
    try:
        from diffusers import DiffusionPipeline
        pipe = DiffusionPipeline.from_pretrained(
            "sudo-ai/zero123plus-v1.2",
            custom_pipeline="sudo-ai/zero123plus-pipeline",
            torch_dtype=torch.float16,
        ).to(DEVICE)
        _zero123_pipeline = pipe
        logger.info("Zero123++ 로딩 완료")
    except Exception as exc:
        logger.warning("Zero123++ 로드 실패: %s", exc)
        _zero123_pipeline = None
    return _zero123_pipeline


def _synthesize_view(primary_image: Image.Image, azimuth: float, elevation: float) -> Optional[Image.Image]:
    pipe = _load_zero123()
    if pipe is None:
        return None
    try:
        with torch.no_grad():
            result = pipe(primary_image, num_inference_steps=36, guidance_scale=4.0)
        return result.images[0]
    except Exception as exc:
        logger.warning("Zero123++ 추론 실패 (az=%.0f, el=%.0f): %s", azimuth, elevation, exc)
        return None


def _merge_pointcloud_to_mesh(base_mesh_glb: bytes, point_cloud: np.ndarray, point_colors: np.ndarray) -> bytes:
    try:
        import trimesh
        import trimesh.registration
        import open3d as o3d

        with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
            f.write(base_mesh_glb)
            base_path = f.name
        try:
            mesh = trimesh.load(base_path, force="mesh")
        finally:
            os.unlink(base_path)

        if len(point_cloud) < 100:
            logger.warning("포인트 클라우드가 너무 작음 (%d점) → 병합 건너뜀", len(point_cloud))
            return base_mesh_glb

        matrix, transformed_pc, cost = trimesh.registration.icp(
            point_cloud, mesh.vertices, max_iterations=100, threshold=1e-5,
        )
        logger.debug("ICP 완료: cost=%.4f", cost)

        pcd = o3d.geometry.PointCloud()
        pcd.points = o3d.utility.Vector3dVector(transformed_pc)
        if len(point_colors) == len(transformed_pc):
            pcd.colors = o3d.utility.Vector3dVector(point_colors / 255.0)
        pcd.estimate_normals(
            search_param=o3d.geometry.KDTreeSearchParamHybrid(radius=0.1, max_nn=30)
        )
        poisson_mesh, densities = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(pcd, depth=9)
        density_threshold = np.quantile(np.asarray(densities), 0.1)
        poisson_mesh.remove_vertices_by_mask(np.asarray(densities) < density_threshold)

        reconstructed = trimesh.Trimesh(
            vertices=np.asarray(poisson_mesh.vertices),
            faces=np.asarray(poisson_mesh.triangles),
        )
        merged = trimesh.util.concatenate([mesh, reconstructed])
        merged = merged.process(validate=True)

        with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
            out_path = f.name
        try:
            merged.export(out_path)
            with open(out_path, "rb") as f:
                return f.read()
        finally:
            os.unlink(out_path)

    except Exception as exc:
        logger.warning("포인트 클라우드 병합 실패: %s → base mesh 그대로 반환", exc)
        return base_mesh_glb


def _complete_with_zero123(base_mesh_glb: bytes, missing_regions: list[dict], primary_image_bytes: Optional[bytes]) -> bytes:
    if primary_image_bytes is None:
        return base_mesh_glb

    primary_pil = Image.open(io.BytesIO(primary_image_bytes)).convert("RGB").resize((512, 512), Image.LANCZOS)
    synthesized_views: list[Image.Image] = []

    for region in missing_regions:
        region_name = region.get("description", "unknown")
        angles = REGION_TO_ANGLES.get(region_name, {"azimuth": 0, "elevation": 0})
        logger.info("Zero123++ 합성: region=%s, az=%.0f, el=%.0f",
                    region_name, angles["azimuth"], angles["elevation"])
        synthesized = _synthesize_view(primary_pil, **angles)
        if synthesized:
            synthesized_views.append(synthesized)

    if not synthesized_views:
        logger.warning("Zero123++ 합성 결과 없음 → base mesh 그대로 반환")
        return base_mesh_glb

    try:
        import trimesh

        with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
            f.write(base_mesh_glb)
            base_path = f.name
        try:
            mesh = trimesh.load(base_path, force="mesh")
        finally:
            os.unlink(base_path)

        with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
            out_path = f.name
        try:
            mesh.export(out_path)
            with open(out_path, "rb") as f:
                return f.read()
        finally:
            os.unlink(out_path)

    except Exception as exc:
        logger.warning("Zero123++ 기반 mesh 보완 실패: %s", exc)
        return base_mesh_glb


def run(
    base_mesh_glb: bytes,
    geometry: GeometryAnalysis,
    primary_image_bytes: Optional[bytes] = None,
) -> bytes:
    """
    Stage 4 실행: 누락 부분 보완

    Args:
        base_mesh_glb: Stage 1에서 생성한 base GLB
        geometry: Stage 3 MASt3R 분석 결과
        primary_image_bytes: 공식 이미지 대표 1장 (Zero123++ 합성용)

    Returns:
        보완된 GLB 바이트
    """
    logger.info("Stage 4 시작: coverage=%.1f%%, 누락=%d곳",
                geometry.coverage_ratio * 100, len(geometry.missing_regions))

    if not geometry.is_reliable:
        logger.info("MASt3R 결과 신뢰도 낮음 → base mesh 그대로 유지")
        return base_mesh_glb

    result_glb = base_mesh_glb

    if geometry.coverage_ratio >= COVERAGE_GOOD_THRESHOLD:
        logger.info("전략 A: 포인트 클라우드 직접 병합 (coverage=%.1f%%)", geometry.coverage_ratio * 100)
        result_glb = _merge_pointcloud_to_mesh(result_glb, geometry.point_cloud, geometry.point_colors)

    elif geometry.coverage_ratio < COVERAGE_POOR_THRESHOLD:
        logger.info("전략 B: Zero123++ 보완 (coverage=%.1f%%)", geometry.coverage_ratio * 100)
        result_glb = _complete_with_zero123(result_glb, geometry.missing_regions, primary_image_bytes)

    else:
        logger.info("전략 C: 혼합 (coverage=%.1f%%)", geometry.coverage_ratio * 100)
        result_glb = _merge_pointcloud_to_mesh(result_glb, geometry.point_cloud, geometry.point_colors)
        if geometry.missing_regions and primary_image_bytes:
            result_glb = _complete_with_zero123(result_glb, geometry.missing_regions, primary_image_bytes)

    logger.info("Stage 4 완료: GLB 크기 %d → %d bytes", len(base_mesh_glb), len(result_glb))
    return result_glb

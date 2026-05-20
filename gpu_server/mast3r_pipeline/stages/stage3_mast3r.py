#!/usr/bin/env python3
"""
Stage 3: MASt3R로 리뷰 사진 간 Geometry Consistency 분석

MASt3R(Matching And Stereo 3D Reconstruction)를 사용하여:
1. 리뷰 사진들 사이의 카메라 포즈를 추정합니다.
2. 실제 3D 포인트 클라우드를 복원합니다.
3. 포인트 클라우드를 Stage 1의 base mesh와 비교합니다.
4. 불일치 영역(missing parts, geometry error)을 찾아냅니다.
"""
from __future__ import annotations

import logging
import os
import tempfile
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import torch

from .stage2_review import ProcessedReviewImage

logger = logging.getLogger("mast3r-pipeline.stage3")

MAST3R_MODEL_NAME = os.getenv(
    "MAST3R_MODEL_NAME",
    "naver/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric",
)
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
GLOBAL_ALIGN_NITER = 300
ALIGN_SCHEDULE = "cosine"
ALIGN_LR = 0.01
COVERAGE_DISTANCE_THRESHOLD = 0.05
MIN_VALID_POINTS = 500


@dataclass
class GeometryAnalysis:
    point_cloud: np.ndarray
    point_colors: np.ndarray
    camera_poses: list[np.ndarray]
    confidence_maps: list[np.ndarray]
    missing_regions: list[dict]
    coverage_ratio: float
    is_reliable: bool
    num_valid_images: int
    summary: dict = field(default_factory=dict)


_mast3r_model = None


def _load_mast3r():
    global _mast3r_model
    if _mast3r_model is not None:
        return _mast3r_model

    logger.info("MASt3R 모델 로딩 중: %s", MAST3R_MODEL_NAME)
    try:
        from mast3r.model import AsymmetricMASt3R
        _mast3r_model = AsymmetricMASt3R.from_pretrained(MAST3R_MODEL_NAME).to(DEVICE)
        _mast3r_model.eval()
        logger.info("MASt3R 로딩 완료 (device=%s)", DEVICE)
    except ImportError:
        logger.error("mast3r 패키지를 찾을 수 없습니다. setup_mast3r_env.sh를 실행하세요.")
        _mast3r_model = None
    return _mast3r_model


def _save_temp_images(images: list[ProcessedReviewImage]) -> list[str]:
    paths = []
    for img in images:
        f = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        img.pil_image.convert("RGB").save(f.name, "JPEG", quality=95)
        paths.append(f.name)
    return paths


def _run_mast3r_inference(model, image_paths: list[str]):
    from dust3r.image_pairs import make_pairs
    from dust3r.inference import inference
    from dust3r.cloud_opt import GlobalAlignerMode, global_aligner
    from dust3r.utils.image import load_images

    imgs = load_images(image_paths, size=512, verbose=False)
    pairs = make_pairs(imgs, scene_graph="complete", prefilter=None, symmetrize=True)
    output = inference(pairs, model, DEVICE, batch_size=1, verbose=False)

    scene = global_aligner(
        output,
        device=DEVICE,
        mode=GlobalAlignerMode.PointCloudOptimizer,
        verbose=False,
    )
    scene.compute_global_alignment(
        init="mst",
        niter=GLOBAL_ALIGN_NITER,
        schedule=ALIGN_SCHEDULE,
        lr=ALIGN_LR,
    )

    pts3d = scene.get_pts3d()
    masks = scene.get_masks()
    imgs_out = scene.imgs
    poses = scene.get_im_poses()
    confs = [scene.get_conf(i).cpu().numpy() for i in range(len(image_paths))]

    all_pts, all_colors = [], []
    for pts, msk, im in zip(pts3d, masks, imgs_out):
        p = pts.cpu().numpy()[msk.cpu().numpy()]
        c = (im.cpu().numpy()[msk.cpu().numpy()] * 255).astype(np.uint8)
        all_pts.append(p)
        all_colors.append(c)

    point_cloud = np.concatenate(all_pts, axis=0) if all_pts else np.zeros((0, 3))
    colors = np.concatenate(all_colors, axis=0) if all_colors else np.zeros((0, 3))
    cam_poses = [poses[i].cpu().numpy() for i in range(len(image_paths))]

    return point_cloud, colors, cam_poses, confs


def _compare_with_base_mesh(point_cloud: np.ndarray, base_mesh_glb: Optional[bytes]):
    if base_mesh_glb is None or len(point_cloud) == 0:
        return 0.0, []

    try:
        import trimesh
        import trimesh.proximity

        with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
            f.write(base_mesh_glb)
            tmp_path = f.name

        try:
            mesh = trimesh.load(tmp_path, force="mesh")
        finally:
            os.unlink(tmp_path)

        if not isinstance(mesh, trimesh.Trimesh):
            return 0.5, []

        mesh_pts = mesh.vertices
        dists_from_mesh, _, _ = trimesh.proximity.closest_point_naive(
            trimesh.points.PointCloud(point_cloud), mesh_pts
        )

        covered = (dists_from_mesh < COVERAGE_DISTANCE_THRESHOLD).mean()
        uncovered_pts = mesh_pts[dists_from_mesh >= COVERAGE_DISTANCE_THRESHOLD]
        missing_regions = []
        if len(uncovered_pts) > 0:
            bbox_min = uncovered_pts.min(axis=0)
            bbox_max = uncovered_pts.max(axis=0)
            center = (bbox_min + bbox_max) / 2.0
            mesh_center = mesh.centroid
            parts = []
            if center[2] > mesh_center[2] + 0.1:
                parts.append("top")
            elif center[2] < mesh_center[2] - 0.1:
                parts.append("bottom")
            if center[0] > mesh_center[0] + 0.1:
                parts.append("right")
            elif center[0] < mesh_center[0] - 0.1:
                parts.append("left")
            if center[1] > mesh_center[1] + 0.1:
                parts.append("back")
            elif center[1] < mesh_center[1] - 0.1:
                parts.append("front")
            missing_regions.append({
                "bbox_min": bbox_min.tolist(),
                "bbox_max": bbox_max.tolist(),
                "uncovered_vertex_count": len(uncovered_pts),
                "description": "_".join(parts) if parts else "center",
            })

        return float(covered), missing_regions

    except Exception as exc:
        logger.warning("base mesh 비교 실패: %s", exc)
        return 0.5, []


def run(
    review_images: list[ProcessedReviewImage],
    base_mesh_glb: Optional[bytes] = None,
    max_images: int = 20,
) -> GeometryAnalysis:
    """
    Stage 3 실행: MASt3R geometry 분석

    Args:
        review_images: Stage 2에서 전처리된 리뷰 이미지 목록
        base_mesh_glb: Stage 1에서 생성한 base GLB (비교용, 선택적)
        max_images: MASt3R에 넘길 최대 이미지 수

    Returns:
        GeometryAnalysis
    """
    if not review_images:
        logger.warning("Stage 3: 리뷰 이미지 없음 → 건너뜀")
        return GeometryAnalysis(
            point_cloud=np.zeros((0, 3)),
            point_colors=np.zeros((0, 3)),
            camera_poses=[],
            confidence_maps=[],
            missing_regions=[],
            coverage_ratio=0.0,
            is_reliable=False,
            num_valid_images=0,
        )

    logger.info("Stage 3 시작: MASt3R 분석 (%d장)", len(review_images))
    selected = review_images[:max_images]

    model = _load_mast3r()
    if model is None:
        logger.error("MASt3R 모델 로드 실패 → geometry 분석 건너뜀")
        return GeometryAnalysis(
            point_cloud=np.zeros((0, 3)),
            point_colors=np.zeros((0, 3)),
            camera_poses=[],
            confidence_maps=[],
            missing_regions=[],
            coverage_ratio=0.0,
            is_reliable=False,
            num_valid_images=0,
        )

    tmp_paths = _save_temp_images(selected)
    try:
        with torch.no_grad():
            point_cloud, colors, cam_poses, confs = _run_mast3r_inference(model, tmp_paths)

        logger.info("MASt3R 추론 완료: %d 포인트", len(point_cloud))
        coverage_ratio, missing_regions = _compare_with_base_mesh(point_cloud, base_mesh_glb)
        logger.info("base mesh 커버리지: %.1f%%, 누락 영역: %d곳",
                    coverage_ratio * 100, len(missing_regions))

        is_reliable = len(point_cloud) >= MIN_VALID_POINTS and len(selected) >= 2

        return GeometryAnalysis(
            point_cloud=point_cloud,
            point_colors=colors,
            camera_poses=cam_poses,
            confidence_maps=confs,
            missing_regions=missing_regions,
            coverage_ratio=coverage_ratio,
            is_reliable=is_reliable,
            num_valid_images=len(selected),
            summary={
                "num_points": len(point_cloud),
                "num_cameras": len(cam_poses),
                "coverage_pct": round(coverage_ratio * 100, 1),
                "missing_region_count": len(missing_regions),
            },
        )
    finally:
        for path in tmp_paths:
            try:
                os.unlink(path)
            except OSError:
                pass

#!/usr/bin/env python3
"""
Stage 5: 최종 Mesh/Texture 후처리

AR 앱에서 사용하기 적합한 최종 GLB를 만들기 위해:
1. 메쉬 단순화 (폴리곤 수 줄이기)
2. Watertight 처리 (구멍 메우기)
3. UV 언래핑 (텍스처 좌표 생성)
4. 텍스처 베이킹
5. 최종 GLB 패키징
"""
from __future__ import annotations

import logging
import os
import tempfile
from dataclasses import dataclass
from typing import Optional

import numpy as np

logger = logging.getLogger("mast3r-pipeline.stage5")

DEFAULT_TARGET_FACES = 50_000
DEFAULT_TEXTURE_SIZE = 2048
MIN_FACES = 1_000


@dataclass
class PostprocessConfig:
    target_faces: int = DEFAULT_TARGET_FACES
    texture_size: int = DEFAULT_TEXTURE_SIZE
    fill_holes: bool = True
    smooth_normals: bool = True
    remove_duplicate_vertices: bool = True
    merge_close_vertices: bool = True
    merge_threshold: float = 1e-5


def _load_mesh(glb_bytes: bytes):
    import trimesh
    with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
        f.write(glb_bytes)
        tmp_path = f.name
    try:
        loaded = trimesh.load(tmp_path, force="mesh")
        if isinstance(loaded, trimesh.Scene):
            meshes = list(loaded.geometry.values())
            loaded = trimesh.util.concatenate(meshes) if meshes else trimesh.Trimesh()
        return loaded
    finally:
        os.unlink(tmp_path)


def _save_mesh_to_glb(mesh) -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
        out_path = f.name
    try:
        mesh.export(out_path)
        with open(out_path, "rb") as f:
            return f.read()
    finally:
        os.unlink(out_path)


def _simplify_mesh(mesh, target_faces: int):
    current_faces = len(mesh.faces)
    if current_faces <= target_faces or current_faces <= MIN_FACES:
        return mesh

    logger.info("메쉬 단순화: %d → %d faces", current_faces, target_faces)
    try:
        import open3d as o3d
        o3d_mesh = o3d.geometry.TriangleMesh(
            vertices=o3d.utility.Vector3dVector(mesh.vertices),
            triangles=o3d.utility.Vector3iVector(mesh.faces),
        )
        simplified = o3d_mesh.simplify_quadric_decimation(target_faces)
        import trimesh
        result = trimesh.Trimesh(
            vertices=np.asarray(simplified.vertices),
            faces=np.asarray(simplified.triangles),
        )
        logger.info("단순화 완료: %d → %d faces", current_faces, len(result.faces))
        return result
    except ImportError:
        pass

    try:
        result = mesh.simplify_quadratic_decimation(target_faces)
        logger.info("단순화 완료: %d → %d faces", current_faces, len(result.faces))
        return result
    except Exception as exc:
        logger.warning("단순화 실패: %s → 원본 유지", exc)
        return mesh


def _fill_holes(mesh):
    try:
        import trimesh.repair
        trimesh.repair.fill_holes(mesh)
    except Exception as exc:
        logger.warning("구멍 메우기 실패: %s", exc)
    return mesh


def _unwrap_uv(mesh, texture_size: int):
    if mesh.visual is not None and hasattr(mesh.visual, "uv") and mesh.visual.uv is not None:
        return mesh
    try:
        import xatlas
        import trimesh
        import trimesh.visual
        vmapping, indices, uvs = xatlas.parametrize(mesh.vertices, mesh.faces)
        mesh = trimesh.Trimesh(
            vertices=mesh.vertices[vmapping],
            faces=indices,
            visual=trimesh.visual.TextureVisuals(uv=uvs),
            process=False,
        )
        logger.debug("UV 언래핑 완료: %d UV 좌표", len(uvs))
    except ImportError:
        logger.warning("xatlas 미설치 → UV 언래핑 건너뜀 (pip install xatlas)")
    except Exception as exc:
        logger.warning("UV 언래핑 실패: %s", exc)
    return mesh


def _center_and_normalize(mesh):
    mesh.apply_translation(-mesh.centroid)
    extents = mesh.extents
    max_extent = extents.max()
    if max_extent > 0:
        mesh.apply_scale(1.0 / max_extent)
    return mesh


def run(
    mesh_glb: bytes,
    config: Optional[PostprocessConfig] = None,
) -> bytes:
    """
    Stage 5 실행: 최종 후처리

    Args:
        mesh_glb: Stage 4에서 보완된 GLB
        config: 후처리 설정 (None이면 기본값 사용)

    Returns:
        AR 최적화된 최종 GLB 바이트
    """
    if config is None:
        config = PostprocessConfig()

    logger.info("Stage 5 시작: target_faces=%d, texture=%dx%d",
                config.target_faces, config.texture_size, config.texture_size)

    try:
        import trimesh
    except ImportError:
        logger.error("trimesh 미설치 → 후처리 건너뜀 (pip install trimesh)")
        return mesh_glb

    mesh = _load_mesh(mesh_glb)
    initial_faces = len(mesh.faces)
    logger.info("메쉬 로드: %d vertices, %d faces", len(mesh.vertices), initial_faces)

    if config.remove_duplicate_vertices:
        mesh.merge_vertices()

    if config.merge_close_vertices:
        mesh = mesh.process(merge_norm=False)

    if config.fill_holes:
        mesh = _fill_holes(mesh)

    if config.smooth_normals:
        try:
            mesh.fix_normals()
        except Exception:
            pass

    mesh = _simplify_mesh(mesh, config.target_faces)
    mesh = _unwrap_uv(mesh, config.texture_size)
    mesh = _center_and_normalize(mesh)

    final_glb = _save_mesh_to_glb(mesh)
    logger.info("Stage 5 완료: %d → %d faces, GLB %d → %d bytes",
                initial_faces, len(mesh.faces), len(mesh_glb), len(final_glb))
    return final_glb

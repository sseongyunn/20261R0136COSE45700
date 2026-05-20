#!/usr/bin/env python3
"""
Stage 1: Official product images → InstantMesh → Base 3D mesh (GLB)

공식 상품 이미지에서 깔끔한 기본 3D 자산을 생성합니다.
InstantMesh를 사용하여 1~6장의 이미지로 고품질 메쉬를 만듭니다.
"""
from __future__ import annotations

import base64
import io
import logging
import os
import tempfile
from pathlib import Path
from typing import Optional

import numpy as np
import torch
from PIL import Image

logger = logging.getLogger("mast3r-pipeline.stage1")

_instantmesh_pipeline = None
INSTANTMESH_CONFIG = os.getenv("INSTANTMESH_CONFIG", "configs/instant-mesh-large.yaml")
INSTANTMESH_CKPT = os.getenv("INSTANTMESH_CKPT", "checkpoints/instant-mesh-large.ckpt")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


def _load_instantmesh():
    global _instantmesh_pipeline
    if _instantmesh_pipeline is not None:
        return _instantmesh_pipeline

    logger.info("InstantMesh 모델 로딩 중...")
    try:
        from instantmesh.models import load_model
        model, cfg = load_model(INSTANTMESH_CONFIG, INSTANTMESH_CKPT, device=DEVICE)
        _instantmesh_pipeline = {"model": model, "cfg": cfg}
        logger.info("InstantMesh 로딩 완료 (device=%s)", DEVICE)
    except ImportError:
        logger.warning("InstantMesh 패키지 없음 → fallback 사용")
        _instantmesh_pipeline = {"model": None, "cfg": None}

    return _instantmesh_pipeline


def _preprocess_image(image_bytes: bytes, remove_background: bool = True) -> Image.Image:
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")

    if remove_background:
        try:
            import rembg
            img_np = np.array(img)
            result_np = rembg.remove(img_np)
            img = Image.fromarray(result_np, "RGBA")
        except ImportError:
            logger.warning("rembg 미설치 → 배경 제거 건너뜀")

    background = Image.new("RGBA", img.size, (255, 255, 255, 255))
    background.paste(img, mask=img.split()[3])
    img_rgb = background.convert("RGB").resize((512, 512), Image.LANCZOS)
    return img_rgb


def run(
    official_images: list[dict],
    remove_background: bool = True,
    output_format: str = "glb",
    octree_resolution: int = 256,
    num_inference_steps: int = 75,
) -> bytes:
    """
    Stage 1 실행: 공식 이미지 → GLB

    Args:
        official_images: [{"image": bytes, "view": "front"}, ...] 형태의 공식 이미지 목록
        remove_background: 배경 제거 여부
        output_format: 출력 포맷 ("glb" | "obj")
        octree_resolution: 메쉬 해상도
        num_inference_steps: 추론 스텝 수

    Returns:
        GLB 파일 바이트
    """
    if not official_images:
        raise ValueError("공식 이미지가 최소 1장 이상 필요합니다.")

    logger.info("Stage 1 시작: 공식 이미지 %d장으로 기본 3D 생성", len(official_images))

    pil_images: list[Image.Image] = []
    for item in official_images:
        raw = item.get("image")
        if isinstance(raw, str):
            raw = base64.b64decode(raw)
        pil_images.append(_preprocess_image(raw, remove_background=remove_background))

    pipeline = _load_instantmesh()

    if pipeline["model"] is not None:
        glb_bytes = _run_instantmesh(pipeline, pil_images, num_inference_steps, octree_resolution)
    else:
        logger.warning("InstantMesh 사용 불가 → fallback 메쉬 생성")
        glb_bytes = _fallback_mesh(pil_images)

    logger.info("Stage 1 완료: GLB 생성 성공 (%d bytes)", len(glb_bytes))
    return glb_bytes


def _run_instantmesh(pipeline, pil_images, num_inference_steps, octree_resolution) -> bytes:
    model = pipeline["model"]
    model.eval()
    primary_image = pil_images[0]

    with torch.no_grad():
        multiview_images = model.generate_multiview(
            primary_image,
            num_inference_steps=num_inference_steps,
            guidance_scale=4.0,
        )
        for i, user_img in enumerate(pil_images[1:6]):
            if i < len(multiview_images):
                multiview_images[i] = user_img

        mesh_output = model.reconstruct_3d(
            multiview_images,
            octree_resolution=octree_resolution,
        )

    with tempfile.NamedTemporaryFile(suffix=".glb", delete=False) as f:
        tmp_path = f.name
    try:
        mesh_output.export(tmp_path)
        with open(tmp_path, "rb") as f:
            return f.read()
    finally:
        os.unlink(tmp_path)


def _fallback_mesh(pil_images: list[Image.Image]) -> bytes:
    json_chunk = b'{"asset":{"version":"2.0"},"scenes":[{"nodes":[]}],"scene":0}'
    padding = (4 - len(json_chunk) % 4) % 4
    json_chunk += b" " * padding
    total = 12 + 8 + len(json_chunk)
    header = b"glTF" + (2).to_bytes(4, "little") + total.to_bytes(4, "little")
    chunk_hdr = len(json_chunk).to_bytes(4, "little") + b"JSON"
    return header + chunk_hdr + json_chunk

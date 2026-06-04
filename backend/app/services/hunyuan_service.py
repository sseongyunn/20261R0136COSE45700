from __future__ import annotations

import base64
from typing import Sequence

import requests

from app.config import settings


def _base64_image(image_bytes: bytes) -> str:
    return base64.b64encode(image_bytes).decode("utf-8")


def generate_multiview_model(view_images: Sequence[dict]) -> bytes:
    """Generate a GLB from multiview images using Hunyuan3D-2mv.

    The GPU server accepts arbitrary uploaded views, selects the best canonical
    front/back/left/right images, and can synthesize missing views before
    calling the underlying Hunyuan3D-2mv model.
    """
    payload = {
        "views": [
            {
                "id": str(item.get("source_image_id") or item.get("id") or ""),
                "view": str(item.get("view") or "unknown"),
                "image": _base64_image(item["image"]),
                "source_image_id": str(item.get("source_image_id") or ""),
                "source": str(item.get("source") or "real"),
            }
            for item in view_images
            if item.get("image")
        ],
        "auto_fill_missing_views": True,
        "remove_background": settings.hunyuan_remove_background,
        "texture": settings.hunyuan_texture,
        "texture_use_delight": True,
        "preserve_texture_color": True,
        "texture_color_match_strength": 0.75,
        "file_type": "glb",
        "type": "glb",
        "seed": settings.hunyuan_seed,
        "octree_resolution": settings.hunyuan_octree_resolution,
        "num_inference_steps": settings.hunyuan_num_inference_steps,
        "guidance_scale": settings.hunyuan_guidance_scale,
        "num_chunks": settings.hunyuan_num_chunks,
        "face_count": settings.hunyuan_face_count,
        "target_face_num": settings.hunyuan_face_count,
    }
    if not payload["views"]:
        raise RuntimeError("Hunyuan multiview generation requires at least one source image")

    url = f"{settings.hunyuan_base_url.rstrip('/')}/generate"
    response = requests.post(
        url,
        json=payload,
        timeout=settings.hunyuan_request_timeout_seconds,
    )

    content_type = response.headers.get("content-type", "")
    if response.status_code < 200 or response.status_code >= 300:
        raise RuntimeError(
            f"Hunyuan generation failed with HTTP {response.status_code}: "
            f"{response.text[:1000]}"
        )
    if "application/json" in content_type:
        raise RuntimeError(f"Hunyuan returned JSON instead of a GLB: {response.text[:1000]}")
    if not response.content:
        raise RuntimeError("Hunyuan returned an empty model response")

    return response.content

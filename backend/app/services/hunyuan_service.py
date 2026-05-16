from __future__ import annotations

import base64
from typing import Dict

import requests

from app.config import settings


def _base64_image(image_bytes: bytes) -> str:
    return base64.b64encode(image_bytes).decode("utf-8")


def generate_multiview_model(images: Dict[str, bytes]) -> bytes:
    """Generate a GLB from front/back/left/right images using Hunyuan3D-2mv.

    The current GPU server (`gpu_server/Hunyuan3D-2/api_server.py`) accepts a
    JSON body with base64 values under `front`, `back`, `left`, and `right`, and
    returns the generated model file directly from `POST /generate`.
    """
    missing = [view for view in ("front", "back", "left", "right") if not images.get(view)]
    if missing:
        raise RuntimeError(f"Hunyuan multiview generation requires: {', '.join(missing)}")

    payload = {
        "front": _base64_image(images["front"]),
        "back": _base64_image(images["back"]),
        "left": _base64_image(images["left"]),
        "right": _base64_image(images["right"]),
        "remove_background": settings.hunyuan_remove_background,
        "texture": settings.hunyuan_texture,
        "file_type": "glb",
        "type": "glb",
        "seed": settings.hunyuan_seed,
        "octree_resolution": settings.hunyuan_octree_resolution,
        "num_inference_steps": settings.hunyuan_num_inference_steps,
        "guidance_scale": settings.hunyuan_guidance_scale,
        "num_chunks": settings.hunyuan_num_chunks,
    }
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

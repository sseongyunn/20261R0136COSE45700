from __future__ import annotations

from io import BytesIO
from pathlib import PurePosixPath
from typing import Dict, Optional, Tuple

import requests

from app.config import settings


def _headers() -> Dict[str, str]:
    if not settings.varco_api_key:
        raise RuntimeError("VARCO_API_KEY is required unless MOCK_VARCO=true")
    return {settings.varco_api_key_header: settings.varco_api_key}


def _raise_for_status(response: requests.Response) -> None:
    try:
        response.raise_for_status()
    except requests.HTTPError as exc:
        raise requests.HTTPError(
            f"{exc}. Response body: {response.text[:1000]}",
            response=response,
        ) from exc


def prepare_image_for_submission(
    image_bytes: bytes,
    source_key: str,
) -> Tuple[bytes, str, str]:
    """Return bytes, filename, and content type suitable for VARCO.

    VARCO Image to 3D currently documents PNG input. For MVP ergonomics, the
    worker converts uploaded JPG/HEIC-derived files to PNG before submission.
    """
    if not settings.varco_convert_image_to_png:
        filename = PurePosixPath(source_key).name or "input.png"
        return image_bytes, filename, "application/octet-stream"

    try:
        from PIL import Image
    except ImportError as exc:
        raise RuntimeError(
            "Pillow is required when VARCO_CONVERT_IMAGE_TO_PNG=true. "
            "Run: pip install -r requirements.txt"
        ) from exc

    input_buffer = BytesIO(image_bytes)
    output_buffer = BytesIO()
    with Image.open(input_buffer) as image:
        image.convert("RGBA").save(output_buffer, format="PNG")
    return output_buffer.getvalue(), "input.png", "image/png"


def submit_image_to_3d(
    image_bytes: bytes,
    *,
    filename: str = "input.png",
    content_type: str = "image/png",
) -> str:
    """Submit an image file to VARCO and return the provider request id."""
    response = requests.post(
        settings.varco_submit_url,
        headers=_headers(),
        files={"image": (filename, image_bytes, content_type)},
        data={
            "target_face_type": settings.varco_target_face_type,
            "target_face_num": str(settings.varco_target_face_num),
            "generate_texture": str(settings.varco_generate_texture).lower(),
            "seed": str(settings.varco_seed),
        },
        timeout=60,
    )
    _raise_for_status(response)
    payload = response.json()
    request_id = (
        payload.get("requestId")
        or payload.get("request_id")
        or payload.get("provider_request_id")
        or payload.get("id")
    )
    if not request_id:
        raise RuntimeError(f"VARCO submit response did not include a request id: {payload}")
    return str(request_id)


def get_generation_result(request_id: str) -> dict:
    """Fetch generation status/result from VARCO."""
    url = settings.varco_result_url_template.format(request_id=request_id)
    response = requests.get(url, headers=_headers(), timeout=60)
    _raise_for_status(response)
    return response.json()


def download_file(url: str) -> bytes:
    response = requests.get(url, timeout=300)
    response.raise_for_status()
    return response.content


def extract_status(result: dict) -> Optional[str]:
    value = (
        result.get("status")
        or result.get("state")
        or result.get("phase")
        or result.get("result", {}).get("status")
    )
    return str(value).lower() if value else None


def extract_model_url(result: dict) -> Optional[str]:
    return (
        result.get("model_url")
        or result.get("modelUrl")
        or result.get("glb_url")
        or result.get("glbUrl")
        or result.get("result", {}).get("model_url")
        or result.get("result", {}).get("glb_url")
        or result.get("output", {}).get("model_url")
        or result.get("output", {}).get("glb_url")
    )

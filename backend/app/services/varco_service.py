from __future__ import annotations

import os
from typing import Dict, Optional

import requests

from app.config import settings


# TODO(VARCO): Replace these defaults with the official VARCO Image-to-3D API
# endpoints from the VARCO docs. They are also configurable through .env so the
# worker can be updated without code changes.
VARCO_SUBMIT_URL = os.getenv("VARCO_SUBMIT_URL", "https://api.varco.example/v1/image-to-3d")
VARCO_RESULT_URL_TEMPLATE = os.getenv(
    "VARCO_RESULT_URL_TEMPLATE",
    "https://api.varco.example/v1/image-to-3d/{request_id}",
)


def _headers() -> Dict[str, str]:
    if not settings.varco_api_key:
        raise RuntimeError("VARCO_API_KEY is required unless MOCK_VARCO=true")
    return {
        "Authorization": f"Bearer {settings.varco_api_key}",
        "Content-Type": "application/json",
    }


def submit_image_to_3d(image_url: str) -> str:
    """Submit an image URL to VARCO and return the provider request id.

    TODO(VARCO): Confirm request body and response fields. Current assumptions:
    - request body accepts {"image_url": "..."}
    - response contains request_id, provider_request_id, or id
    """
    response = requests.post(
        VARCO_SUBMIT_URL,
        headers=_headers(),
        json={"image_url": image_url},
        timeout=60,
    )
    response.raise_for_status()
    payload = response.json()
    request_id = (
        payload.get("request_id")
        or payload.get("provider_request_id")
        or payload.get("id")
    )
    if not request_id:
        raise RuntimeError(f"VARCO submit response did not include a request id: {payload}")
    return str(request_id)


def get_generation_result(request_id: str) -> dict:
    """Fetch generation status/result from VARCO.

    TODO(VARCO): Confirm status and model URL field names. The worker checks
    several common shapes, but the constants/helpers should be aligned with the
    official VARCO API before MOCK_VARCO is disabled.
    """
    url = VARCO_RESULT_URL_TEMPLATE.format(request_id=request_id)
    response = requests.get(url, headers=_headers(), timeout=60)
    response.raise_for_status()
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

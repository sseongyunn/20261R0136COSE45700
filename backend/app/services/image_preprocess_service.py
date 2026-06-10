from __future__ import annotations

import math
from dataclasses import dataclass
from io import BytesIO
from typing import Mapping, Optional

from PIL import Image, ImageEnhance, ImageOps, UnidentifiedImageError

from app.config import settings
from app.services.render_profile_service import ImageStats, image_stats_from_bytes


@dataclass(frozen=True)
class ColorTransform:
    target_luminance: float
    exposure_gain: float
    gamma: float
    saturation_gain: float
    contrast_gain: float
    red_gain: float
    green_gain: float
    blue_gain: float


@dataclass(frozen=True)
class ProcessedImage:
    view_label: str
    image_bytes: bytes
    original_stats: Optional[ImageStats]
    processed_stats: Optional[ImageStats]
    transform: ColorTransform
    notes: Optional[str] = None


def preprocess_single_image(image_bytes: bytes, view_label: str = "front") -> ProcessedImage:
    return preprocess_image_group({view_label: image_bytes})[view_label]


def preprocess_image_group(images: Mapping[str, bytes]) -> dict[str, ProcessedImage]:
    """Normalize uploaded images before image-to-3D submission.

    For multiview jobs this computes one shared transform from all views, then
    applies the same exposure/white-balance/saturation correction to every view
    so generated textures do not drift between front/back/left/right.
    """

    if not images:
        return {}

    original_stats = {
        view: _safe_stats(image_bytes)
        for view, image_bytes in images.items()
    }
    transform = _shared_transform([stats for stats in original_stats.values() if stats])

    processed: dict[str, ProcessedImage] = {}
    for view, image_bytes in images.items():
        try:
            normalized = _normalize_image(image_bytes, transform)
            normalized_stats = _safe_stats(normalized)
            notes = None
        except (OSError, UnidentifiedImageError, ValueError) as exc:
            normalized = _png_passthrough(image_bytes)
            normalized_stats = _safe_stats(normalized)
            notes = f"preprocess_fallback:{type(exc).__name__}"

        processed[view] = ProcessedImage(
            view_label=view,
            image_bytes=normalized,
            original_stats=original_stats[view],
            processed_stats=normalized_stats,
            transform=transform,
            notes=notes,
        )

    return processed


def _safe_stats(image_bytes: bytes) -> Optional[ImageStats]:
    try:
        return image_stats_from_bytes(image_bytes)
    except (OSError, UnidentifiedImageError, ValueError):
        return None


def _shared_transform(stats: list[ImageStats]) -> ColorTransform:
    if stats:
        total = sum(max(1, item.sample_count) for item in stats)
        mean_r = sum(item.mean_r * max(1, item.sample_count) for item in stats) / total
        mean_g = sum(item.mean_g * max(1, item.sample_count) for item in stats) / total
        mean_b = sum(item.mean_b * max(1, item.sample_count) for item in stats) / total
        luminance = sum(item.luminance * max(1, item.sample_count) for item in stats) / total
        saturation = sum(item.saturation * max(1, item.sample_count) for item in stats) / total
    else:
        mean_r = mean_g = mean_b = luminance = 0.5
        saturation = 0.35

    target = settings.preprocess_target_luminance
    exposure = _clamp(
        target / max(0.08, luminance),
        settings.preprocess_min_exposure_gain,
        settings.preprocess_max_exposure_gain,
    )

    avg = max(0.001, (mean_r + mean_g + mean_b) / 3)
    red_gain = _clamp(avg / max(0.001, mean_r), 0.78, 1.28)
    green_gain = _clamp(avg / max(0.001, mean_g), 0.78, 1.28)
    blue_gain = _clamp(avg / max(0.001, mean_b), 0.78, 1.28)

    gamma = 1.0
    if luminance < target:
        gamma = _clamp(1.0 - (target - luminance) * 0.45, 0.72, 1.0)
    elif luminance > target + 0.18:
        gamma = _clamp(1.0 + (luminance - target) * 0.35, 1.0, 1.18)

    saturation_gain = _clamp(
        settings.preprocess_saturation_gain + max(0.0, 0.34 - saturation) * 0.38,
        1.0,
        1.26,
    )

    return ColorTransform(
        target_luminance=target,
        exposure_gain=exposure,
        gamma=gamma,
        saturation_gain=saturation_gain,
        contrast_gain=settings.preprocess_contrast_gain,
        red_gain=red_gain,
        green_gain=green_gain,
        blue_gain=blue_gain,
    )


def _normalize_image(image_bytes: bytes, transform: ColorTransform) -> bytes:
    with Image.open(BytesIO(image_bytes)) as loaded:
        image = ImageOps.exif_transpose(loaded).convert("RGBA")

    image = _pad_to_square(image)
    pixels = image.load()
    assert pixels is not None
    inv_gamma = 1.0 / max(0.01, transform.gamma)

    for y in range(image.height):
        for x in range(image.width):
            r_raw, g_raw, b_raw, a_raw = pixels[x, y]
            if a_raw <= 0:
                continue
            r = _correct_channel(r_raw, transform.exposure_gain, transform.red_gain, inv_gamma)
            g = _correct_channel(g_raw, transform.exposure_gain, transform.green_gain, inv_gamma)
            b = _correct_channel(b_raw, transform.exposure_gain, transform.blue_gain, inv_gamma)
            pixels[x, y] = (r, g, b, a_raw)

    if transform.contrast_gain != 1.0:
        image = ImageEnhance.Contrast(image).enhance(transform.contrast_gain)
    if transform.saturation_gain != 1.0:
        image = ImageEnhance.Color(image).enhance(transform.saturation_gain)

    output = BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def _correct_channel(raw: int, exposure_gain: float, balance_gain: float, inv_gamma: float) -> int:
    value = (raw / 255.0) * exposure_gain * balance_gain
    value = _clamp(value, 0.0, 1.0)
    value = math.pow(value, inv_gamma)
    return int(round(_clamp(value, 0.0, 1.0) * 255))


def _pad_to_square(image: Image.Image) -> Image.Image:
    width, height = image.size
    if width == height:
        return image
    side = max(width, height)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(image, ((side - width) // 2, (side - height) // 2))
    return canvas


def _png_passthrough(image_bytes: bytes) -> bytes:
    with Image.open(BytesIO(image_bytes)) as loaded:
        image = ImageOps.exif_transpose(loaded).convert("RGBA")
    output = BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def _clamp(value: float, low: float, high: float) -> float:
    if math.isnan(value):
        return low
    return min(high, max(low, value))

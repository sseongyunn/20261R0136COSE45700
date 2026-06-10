from __future__ import annotations

import base64
import json
import math
from dataclasses import dataclass
from io import BytesIO
from typing import Any, Optional

from PIL import Image, UnidentifiedImageError


GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


@dataclass(frozen=True)
class ImageStats:
    mean_r: float
    mean_g: float
    mean_b: float
    luminance: float
    saturation: float
    sample_count: int


def analyze_render_profile(
    model_bytes: bytes,
    source_image_bytes: Optional[bytes] = None,
    input_color_profile: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """Build a lightweight AR color/lighting profile for a generated model.

    The profile is intentionally small: it stores canonical color and material
    hints that the AR client can use later with the live ARKit light estimate.
    It supports embedded GLB textures first and falls back to the user's source
    image when the generated model has external/no textures.
    """

    gltf, binary_chunk = _read_glb(model_bytes)
    material_stats = _material_stats(gltf)
    texture_stats = _embedded_texture_stats(gltf, binary_chunk)
    source_stats = _safe_image_stats(source_image_bytes)

    selected_stats = texture_stats or source_stats or material_stats["base_color_stats"]
    if texture_stats is not None:
        source = "model_texture"
    elif source_stats is not None:
        source = "source_image"
    elif material_stats["base_color_stats"] is not None:
        source = "material_factor"
    else:
        source = "fallback"

    luminance = selected_stats.luminance if selected_stats else None
    saturation = selected_stats.saturation if selected_stats else None
    mean_r = selected_stats.mean_r if selected_stats else None
    mean_g = selected_stats.mean_g if selected_stats else None
    mean_b = selected_stats.mean_b if selected_stats else None

    profile = {
        "profile_version": 1,
        "source": source,
        "albedo_mean_r": mean_r,
        "albedo_mean_g": mean_g,
        "albedo_mean_b": mean_b,
        "texture_luminance_mean": luminance,
        "texture_saturation_mean": saturation,
        "roughness_mean": material_stats["roughness_mean"],
        "metallic_mean": material_stats["metallic_mean"],
        "suggested_exposure_gain": _suggested_exposure_gain(luminance),
        "suggested_emissive_lift": _suggested_emissive_lift(luminance),
        "has_embedded_textures": texture_stats is not None,
        "has_external_textures": material_stats["has_external_textures"],
        "has_normal_map": material_stats["has_normal_map"],
        "has_occlusion_map": material_stats["has_occlusion_map"],
        "has_emissive": material_stats["has_emissive"],
        "material_count": material_stats["material_count"],
        "texture_count": material_stats["texture_count"],
        "notes": _profile_notes(texture_stats, source_stats, material_stats, luminance),
    }
    if input_color_profile:
        profile.update(input_color_profile)
    return profile


def image_stats_from_bytes(image_bytes: bytes) -> ImageStats:
    return _image_stats(image_bytes)


def _read_glb(model_bytes: bytes) -> tuple[dict[str, Any], bytes]:
    if len(model_bytes) < 20:
        return {}, b""

    magic = int.from_bytes(model_bytes[0:4], "little")
    if magic != GLB_MAGIC:
        return {}, b""

    offset = 12
    gltf: dict[str, Any] = {}
    binary = b""
    while offset + 8 <= len(model_bytes):
        chunk_length = int.from_bytes(model_bytes[offset : offset + 4], "little")
        chunk_type = int.from_bytes(model_bytes[offset + 4 : offset + 8], "little")
        chunk_start = offset + 8
        chunk_end = chunk_start + chunk_length
        if chunk_end > len(model_bytes):
            break
        chunk = model_bytes[chunk_start:chunk_end]
        if chunk_type == JSON_CHUNK:
            try:
                gltf = json.loads(chunk.rstrip(b" \t\r\n\x00").decode("utf-8"))
            except json.JSONDecodeError:
                gltf = {}
        elif chunk_type == BIN_CHUNK:
            binary = chunk
        offset = chunk_end

    return gltf, binary


def _material_stats(gltf: dict[str, Any]) -> dict[str, Any]:
    materials = gltf.get("materials") or []
    textures = gltf.get("textures") or []
    images = gltf.get("images") or []
    roughness_values: list[float] = []
    metallic_values: list[float] = []
    base_color_values: list[ImageStats] = []
    has_normal = False
    has_occlusion = False
    has_emissive = False

    for material in materials:
        if not isinstance(material, dict):
            continue
        pbr = material.get("pbrMetallicRoughness") or {}
        if isinstance(pbr, dict):
            roughness_values.append(_as_float(pbr.get("roughnessFactor"), 1.0))
            metallic_values.append(_as_float(pbr.get("metallicFactor"), 0.0))
            base = pbr.get("baseColorFactor")
            if isinstance(base, list) and len(base) >= 3:
                r = _clamp01(_as_float(base[0], 1.0))
                g = _clamp01(_as_float(base[1], 1.0))
                b = _clamp01(_as_float(base[2], 1.0))
                base_color_values.append(_stats_from_rgb(r, g, b))

        has_normal = has_normal or "normalTexture" in material
        has_occlusion = has_occlusion or "occlusionTexture" in material
        emissive = material.get("emissiveFactor")
        if isinstance(emissive, list) and any(_as_float(v, 0.0) > 0 for v in emissive[:3]):
            has_emissive = True
        has_emissive = has_emissive or "emissiveTexture" in material

    has_external_textures = any(
        isinstance(image, dict)
        and isinstance(image.get("uri"), str)
        and not image["uri"].startswith("data:")
        for image in images
    )

    return {
        "material_count": len(materials),
        "texture_count": len(textures),
        "roughness_mean": _mean(roughness_values),
        "metallic_mean": _mean(metallic_values),
        "base_color_stats": _combine_stats(base_color_values),
        "has_external_textures": has_external_textures,
        "has_normal_map": has_normal,
        "has_occlusion_map": has_occlusion,
        "has_emissive": has_emissive,
    }


def _embedded_texture_stats(gltf: dict[str, Any], binary_chunk: bytes) -> Optional[ImageStats]:
    images = gltf.get("images") or []
    buffer_views = gltf.get("bufferViews") or []
    stats: list[ImageStats] = []

    for image in images:
        if not isinstance(image, dict):
            continue
        image_bytes: Optional[bytes] = None

        buffer_view_index = image.get("bufferView")
        if isinstance(buffer_view_index, int) and 0 <= buffer_view_index < len(buffer_views):
            view = buffer_views[buffer_view_index]
            if isinstance(view, dict):
                start = int(view.get("byteOffset") or 0)
                length = int(view.get("byteLength") or 0)
                if length > 0:
                    image_bytes = binary_chunk[start : start + length]

        uri = image.get("uri")
        if image_bytes is None and isinstance(uri, str) and uri.startswith("data:"):
            try:
                image_bytes = base64.b64decode(uri.split(",", 1)[1], validate=True)
            except (IndexError, ValueError):
                image_bytes = None

        image_stats = _safe_image_stats(image_bytes)
        if image_stats is not None:
            stats.append(image_stats)

    return _combine_stats(stats)


def _safe_image_stats(image_bytes: Optional[bytes]) -> Optional[ImageStats]:
    if not image_bytes:
        return None
    try:
        return _image_stats(image_bytes)
    except (OSError, UnidentifiedImageError, ValueError):
        return None


def _image_stats(image_bytes: bytes) -> ImageStats:
    with Image.open(BytesIO(image_bytes)) as image:
        image = image.convert("RGBA")
        image.thumbnail((256, 256))
        r_total = g_total = b_total = luma_total = sat_total = weight_total = 0.0
        count = 0
        for r_raw, g_raw, b_raw, a_raw in image.getdata():
            if a_raw < 24:
                continue
            weight = a_raw / 255.0
            r = r_raw / 255.0
            g = g_raw / 255.0
            b = b_raw / 255.0
            maximum = max(r, g, b)
            minimum = min(r, g, b)
            saturation = 0.0 if maximum <= 0 else (maximum - minimum) / maximum
            luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r_total += r * weight
            g_total += g * weight
            b_total += b * weight
            luma_total += luminance * weight
            sat_total += saturation * weight
            weight_total += weight
            count += 1

        if weight_total <= 0 or count == 0:
            raise ValueError("image has no opaque pixels")

        return ImageStats(
            mean_r=r_total / weight_total,
            mean_g=g_total / weight_total,
            mean_b=b_total / weight_total,
            luminance=luma_total / weight_total,
            saturation=sat_total / weight_total,
            sample_count=count,
        )


def _stats_from_rgb(r: float, g: float, b: float) -> ImageStats:
    maximum = max(r, g, b)
    minimum = min(r, g, b)
    saturation = 0.0 if maximum <= 0 else (maximum - minimum) / maximum
    luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return ImageStats(r, g, b, luminance, saturation, 1)


def _combine_stats(stats: list[ImageStats]) -> Optional[ImageStats]:
    if not stats:
        return None
    total = sum(max(1, item.sample_count) for item in stats)
    return ImageStats(
        mean_r=sum(item.mean_r * max(1, item.sample_count) for item in stats) / total,
        mean_g=sum(item.mean_g * max(1, item.sample_count) for item in stats) / total,
        mean_b=sum(item.mean_b * max(1, item.sample_count) for item in stats) / total,
        luminance=sum(item.luminance * max(1, item.sample_count) for item in stats) / total,
        saturation=sum(item.saturation * max(1, item.sample_count) for item in stats) / total,
        sample_count=total,
    )


def _suggested_exposure_gain(luminance: Optional[float]) -> float:
    if luminance is None or luminance <= 0:
        return 1.0
    # Keep correction conservative. Big lifts make AR objects look emissive.
    return round(min(1.45, max(0.78, 0.52 / luminance)), 3)


def _suggested_emissive_lift(luminance: Optional[float]) -> float:
    if luminance is None or luminance >= 0.45:
        return 0.0
    return round(min(0.18, (0.45 - luminance) * 0.42), 3)


def _profile_notes(
    texture_stats: Optional[ImageStats],
    source_stats: Optional[ImageStats],
    material_stats: dict[str, Any],
    luminance: Optional[float],
) -> Optional[str]:
    notes: list[str] = []
    if texture_stats is None and material_stats["has_external_textures"]:
        notes.append("external_texture_not_sampled")
    if texture_stats is None and source_stats is not None:
        notes.append("used_source_image_fallback")
    if luminance is not None and luminance < 0.32:
        notes.append("dark_texture")
    if material_stats["has_emissive"]:
        notes.append("model_has_emissive")
    return ",".join(notes) if notes else None


def _as_float(value: Any, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _mean(values: list[float]) -> Optional[float]:
    if not values:
        return None
    return sum(values) / len(values)


def _clamp01(value: float) -> float:
    if math.isnan(value):
        return 0.0
    return min(1.0, max(0.0, value))

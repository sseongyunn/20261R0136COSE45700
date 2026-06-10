# api_server.py
import argparse
import asyncio
import base64
import json
import logging
import logging.handlers
import os
import sys
import tempfile
import threading
import traceback
import uuid
from io import BytesIO
from typing import Dict, Any, Optional

import requests
import torch
import trimesh
import uvicorn
from PIL import Image
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, FileResponse
from fastapi.middleware.cors import CORSMiddleware

from hy3dgen.rembg import BackgroundRemover
from hy3dgen.shapegen import (
    Hunyuan3DDiTFlowMatchingPipeline,
    FloaterRemover,
    DegenerateFaceRemover,
    FaceReducer,
)
from hy3dgen.texgen import Hunyuan3DPaintPipeline


LOGDIR = "."
SAVE_DIR = "gradio_cache"
os.makedirs(SAVE_DIR, exist_ok=True)

server_error_msg = "**NETWORK ERROR DUE TO HIGH TRAFFIC. PLEASE REGENERATE OR REFRESH THIS PAGE.**"

handler = None
worker_id = str(uuid.uuid4())[:6]
model_semaphore = None
model_state_lock = threading.Lock()
active_model_requests = 0
waiting_model_requests = 0
args = None


def build_logger(logger_name: str, logger_filename: str):
    global handler

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    if not logging.getLogger().handlers:
        logging.basicConfig(level=logging.INFO)

    logging.getLogger().handlers[0].setFormatter(formatter)

    stdout_logger = logging.getLogger("stdout")
    stdout_logger.setLevel(logging.INFO)
    sys.stdout = StreamToLogger(stdout_logger, logging.INFO)

    stderr_logger = logging.getLogger("stderr")
    stderr_logger.setLevel(logging.ERROR)
    sys.stderr = StreamToLogger(stderr_logger, logging.ERROR)

    logger = logging.getLogger(logger_name)
    logger.setLevel(logging.INFO)

    if handler is None:
        os.makedirs(LOGDIR, exist_ok=True)
        filename = os.path.join(LOGDIR, logger_filename)
        handler = logging.handlers.TimedRotatingFileHandler(
            filename,
            when="D",
            utc=True,
            encoding="UTF-8",
        )
        handler.setFormatter(formatter)

        for _, item in logging.root.manager.loggerDict.items():
            if isinstance(item, logging.Logger):
                item.addHandler(handler)

    return logger


class StreamToLogger:
    def __init__(self, logger, log_level=logging.INFO):
        self.terminal = sys.__stdout__
        self.logger = logger
        self.log_level = log_level
        self.linebuf = ""

    def __getattr__(self, attr):
        return getattr(self.terminal, attr)

    def write(self, buf):
        temp_linebuf = self.linebuf + buf
        self.linebuf = ""

        for line in temp_linebuf.splitlines(True):
            if line.endswith("\n"):
                self.logger.log(self.log_level, line.rstrip())
            else:
                self.linebuf += line

    def flush(self):
        if self.linebuf:
            self.logger.log(self.log_level, self.linebuf.rstrip())
        self.linebuf = ""


logger = build_logger("controller", f"{SAVE_DIR}/controller.log")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def load_local_env(env_path: str) -> None:
    if not os.path.exists(env_path):
        return

    with open(env_path, "r", encoding="utf-8") as env_file:
        for raw_line in env_file:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip("\"'")
            if key and key not in os.environ:
                os.environ[key] = value


load_local_env(os.path.join(SCRIPT_DIR, ".env"))


def load_image_from_base64(image_b64: str) -> Image.Image:
    return Image.open(BytesIO(base64.b64decode(image_b64))).convert("RGBA")


def encode_image_to_base64(image: Image.Image, image_format: str = "PNG") -> str:
    buffer = BytesIO()
    image.save(buffer, format=image_format)
    return base64.b64encode(buffer.getvalue()).decode("utf-8")


def encode_image_jpeg_base64(image: Image.Image, max_size: int) -> str:
    image = image.convert("RGBA")
    image.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)
    background = Image.new("RGB", image.size, (255, 255, 255))
    background.paste(image, mask=image.getchannel("A"))
    buffer = BytesIO()
    background.save(buffer, format="JPEG", quality=85, optimize=True)
    return base64.b64encode(buffer.getvalue()).decode("utf-8")


def encode_image_data_url(image: Image.Image, max_size: int) -> str:
    return f"data:image/jpeg;base64,{encode_image_jpeg_base64(image, max_size)}"


CANONICAL_VIEWS = ("front", "back", "left", "right")
VIEW_ALIASES = {
    "front_left": ("front", "left"),
    "front_right": ("front", "right"),
    "back_left": ("back", "left"),
    "back_right": ("back", "right"),
    "left_front": ("front", "left"),
    "right_front": ("front", "right"),
    "left_back": ("back", "left"),
    "right_back": ("back", "right"),
    "side_left": ("left",),
    "side_right": ("right",),
}
TEXTURE_VIEW_ORDER = ("front", "right", "back", "left")
VIEW_SELECTOR_BASE_URL = os.getenv("VIEW_SELECTOR_BASE_URL", "").rstrip("/")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
OPENAI_VIEW_SELECTOR_MODEL = os.getenv("OPENAI_VIEW_SELECTOR_MODEL", "gpt-4.1-mini")
OPENAI_VIEW_SELECTOR_TIMEOUT_SECONDS = int(os.getenv("OPENAI_VIEW_SELECTOR_TIMEOUT_SECONDS", "90"))
OPENAI_VIEW_SELECTOR_MAX_IMAGE_SIZE = int(os.getenv("OPENAI_VIEW_SELECTOR_MAX_IMAGE_SIZE", "768"))
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
CLAUDE_VIEW_SELECTOR_MODEL = os.getenv("CLAUDE_VIEW_SELECTOR_MODEL", "claude-3-5-haiku-20241022")
CLAUDE_VIEW_SELECTOR_TIMEOUT_SECONDS = int(os.getenv("CLAUDE_VIEW_SELECTOR_TIMEOUT_SECONDS", "90"))
CLAUDE_VIEW_SELECTOR_MAX_IMAGE_SIZE = int(os.getenv("CLAUDE_VIEW_SELECTOR_MAX_IMAGE_SIZE", "768"))
MISSING_VIEW_BASE_URL = os.getenv("MISSING_VIEW_BASE_URL", "").rstrip("/")
MISSING_VIEW_PROVIDER = os.getenv("MISSING_VIEW_PROVIDER", "era3d")
MISSING_VIEW_TIMEOUT_SECONDS = int(os.getenv("MISSING_VIEW_TIMEOUT_SECONDS", "600"))


def normalize_view_label(value: str) -> str:
    return str(value or "unknown").strip().lower().replace("-", "_")


def parse_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "on"}
    return bool(value)


def collect_texture_reference_images(image_input):
    if not isinstance(image_input, dict):
        return image_input

    texture_images = [
        image_input[view]
        for view in TEXTURE_VIEW_ORDER
        if image_input.get(view) is not None
    ]
    if not texture_images:
        raise ValueError("No texture reference image provided.")
    return texture_images


def _candidate_score(candidate: dict, canonical_view: str) -> tuple[float, int, int]:
    view_label = candidate.get("view_label", "unknown")
    confidence = float(candidate.get("confidence", 0.5))
    quality = float(candidate.get("quality", 0.5))
    if view_label == canonical_view:
        label_score = 2.0
    elif canonical_view in VIEW_ALIASES.get(view_label, ()):
        label_score = 1.0
    else:
        label_score = 0.0
    return (label_score + confidence + quality, int(candidate.get("is_exact", False)), -candidate["order"])


def _extract_response_text(result: dict) -> str:
    if result.get("output_text"):
        return str(result["output_text"])

    chunks = []
    for content in result.get("content", []):
        if content.get("type") == "text" and content.get("text"):
            chunks.append(str(content["text"]))

    for item in result.get("output", []):
        for content in item.get("content", []):
            if content.get("type") in {"output_text", "text"} and content.get("text"):
                chunks.append(str(content["text"]))
    return "\n".join(chunks)


def _parse_json_object(text: str) -> dict:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`")
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:].strip()
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start >= 0 and end > start:
            return json.loads(cleaned[start : end + 1])
        raise


def _apply_openai_view_selector(candidates: list[dict]) -> bool:
    if not OPENAI_API_KEY:
        return False

    content = [
        {
            "type": "input_text",
            "text": (
                "Classify each furniture image by camera viewpoint. "
                "Allowed views: front, back, left, right, front_left, front_right, "
                "back_left, back_right, detail, unknown. "
                "Use the user-provided hint only as weak context; inspect the image itself. "
                "Return strict JSON only with this shape: "
                "{\"images\":[{\"id\":\"...\",\"view\":\"front|back|left|right|front_left|front_right|back_left|back_right|detail|unknown\","
                "\"confidence\":0.0,\"quality\":0.0,\"reason\":\"short\"}]}. "
                "confidence means viewpoint certainty. quality means usefulness for 3D reconstruction."
            ),
        }
    ]

    for candidate in candidates:
        content.append(
            {
                "type": "input_text",
                "text": f"image id={candidate['id']}, user_hint={candidate.get('view_label', 'unknown')}",
            }
        )
        content.append(
            {
                "type": "input_image",
                "image_url": encode_image_data_url(candidate["image"], OPENAI_VIEW_SELECTOR_MAX_IMAGE_SIZE),
            }
        )

    response = requests.post(
        "https://api.openai.com/v1/responses",
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
        json={
            "model": OPENAI_VIEW_SELECTOR_MODEL,
            "input": [{"role": "user", "content": content}],
        },
        timeout=OPENAI_VIEW_SELECTOR_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    result = _parse_json_object(_extract_response_text(response.json()))

    by_id = {candidate["id"]: candidate for candidate in candidates}
    updated = False
    for item in result.get("images", []):
        candidate = by_id.get(str(item.get("id")))
        if not candidate:
            continue
        candidate["view_label"] = normalize_view_label(item.get("view", candidate["view_label"]))
        candidate["confidence"] = float(item.get("confidence", candidate.get("confidence", 0.5)))
        candidate["quality"] = float(item.get("quality", candidate.get("quality", 0.5)))
        candidate["ai_reason"] = str(item.get("reason", ""))
        candidate["ai_provider"] = "openai"
        updated = True

    if updated:
        logger.info(
            "OpenAI view selector assignment: %s",
            {
                candidate["id"]: {
                    "view": candidate.get("view_label"),
                    "confidence": candidate.get("confidence"),
                    "quality": candidate.get("quality"),
                    "reason": candidate.get("ai_reason", ""),
                }
                for candidate in candidates
            },
        )
    return updated


def _apply_claude_view_selector(candidates: list[dict]) -> bool:
    if not ANTHROPIC_API_KEY:
        return False

    content = [
        {
            "type": "text",
            "text": (
                "Classify each furniture image by camera viewpoint. "
                "Allowed views: front, back, left, right, front_left, front_right, "
                "back_left, back_right, detail, unknown. "
                "Use the user-provided hint only as weak context; inspect the image itself. "
                "Return strict JSON only with this shape: "
                "{\"images\":[{\"id\":\"...\",\"view\":\"front|back|left|right|front_left|front_right|back_left|back_right|detail|unknown\","
                "\"confidence\":0.0,\"quality\":0.0,\"reason\":\"short\"}]}. "
                "confidence means viewpoint certainty. quality means usefulness for 3D reconstruction."
            ),
        }
    ]

    for candidate in candidates:
        content.append(
            {
                "type": "text",
                "text": f"image id={candidate['id']}, user_hint={candidate.get('view_label', 'unknown')}",
            }
        )
        content.append(
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": encode_image_jpeg_base64(candidate["image"], CLAUDE_VIEW_SELECTOR_MAX_IMAGE_SIZE),
                },
            }
        )

    response = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
        },
        json={
            "model": CLAUDE_VIEW_SELECTOR_MODEL,
            "max_tokens": 1200,
            "temperature": 0,
            "messages": [{"role": "user", "content": content}],
        },
        timeout=CLAUDE_VIEW_SELECTOR_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    result = _parse_json_object(_extract_response_text(response.json()))

    by_id = {candidate["id"]: candidate for candidate in candidates}
    updated = False
    for item in result.get("images", []):
        candidate = by_id.get(str(item.get("id")))
        if not candidate:
            continue
        candidate["view_label"] = normalize_view_label(item.get("view", candidate["view_label"]))
        candidate["confidence"] = float(item.get("confidence", candidate.get("confidence", 0.5)))
        candidate["quality"] = float(item.get("quality", candidate.get("quality", 0.5)))
        candidate["ai_reason"] = str(item.get("reason", ""))
        candidate["ai_provider"] = "claude"
        updated = True

    if updated:
        logger.info(
            "Claude view selector assignment: %s",
            {
                candidate["id"]: {
                    "view": candidate.get("view_label"),
                    "confidence": candidate.get("confidence"),
                    "quality": candidate.get("quality"),
                    "reason": candidate.get("ai_reason", ""),
                }
                for candidate in candidates
            },
        )
    return updated


def _apply_view_selector(candidates: list[dict]) -> None:
    for selector_name, selector in (
        ("openai", _apply_openai_view_selector),
        ("claude", _apply_claude_view_selector),
    ):
        try:
            if selector(candidates):
                return
        except Exception:
            logger.exception("View selector '%s' failed; falling back.", selector_name)

    if not VIEW_SELECTOR_BASE_URL:
        return

    try:
        payload = {
            "views": [
                {
                    "id": candidate["id"],
                    "view": candidate["view_label"],
                    "image": encode_image_to_base64(candidate["image"]),
                }
                for candidate in candidates
            ],
            "target_views": list(CANONICAL_VIEWS),
        }
        response = requests.post(
            f"{VIEW_SELECTOR_BASE_URL}/select-views",
            json=payload,
            timeout=120,
        )
        response.raise_for_status()
        result = response.json()
    except Exception:
        logger.exception("External view selector failed; falling back.")
        return

    images = result.get("images", [])
    by_id = {candidate["id"]: candidate for candidate in candidates}
    for item in images:
        candidate = by_id.get(str(item.get("id")))
        if not candidate:
            continue
        candidate["view_label"] = normalize_view_label(item.get("view", candidate["view_label"]))
        candidate["confidence"] = float(item.get("confidence", candidate.get("confidence", 0.5)))
        candidate["quality"] = float(item.get("quality", candidate.get("quality", 0.5)))


def _fallback_front_view(candidates: list[dict]) -> Optional[dict]:
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda candidate: (
            float(candidate.get("quality", 0.5)),
            float(candidate.get("confidence", 0.5)),
            -candidate["order"],
        ),
    )


def _select_canonical_images(candidates: list[dict]) -> dict[str, dict]:
    selected: dict[str, dict] = {}
    used_ids: set[str] = set()

    for view in CANONICAL_VIEWS:
        view_candidates = [
            candidate
            for candidate in candidates
            if candidate["id"] not in used_ids
            and (
                candidate.get("view_label") == view
                or view in VIEW_ALIASES.get(candidate.get("view_label", "unknown"), ())
            )
        ]
        if not view_candidates:
            continue
        best = max(view_candidates, key=lambda candidate: _candidate_score(candidate, view))
        selected[view] = best
        used_ids.add(best["id"])

    if not selected:
        fallback = _fallback_front_view(candidates)
        if fallback is not None:
            fallback["view_label"] = "front"
            fallback["is_exact"] = True
            selected["front"] = fallback
            logger.info(
                "No canonical view was selected; using candidate '%s' as front fallback.",
                fallback.get("id"),
            )

    return selected


def _generate_missing_view(target_view: str, selected: dict[str, dict]) -> Optional[Image.Image]:
    if not MISSING_VIEW_BASE_URL:
        return None
    if not selected:
        raise ValueError(f"Cannot generate missing view '{target_view}' without any reference image.")

    reference_view, reference_candidate = next(iter(selected.items()))
    payload = {
        "provider": MISSING_VIEW_PROVIDER,
        "target_view": target_view,
        "reference_view": reference_view,
        "reference_image": encode_image_to_base64(reference_candidate["image"]),
        "available_views": [
            {
                "view": view,
                "source": candidate.get("source", "real"),
                "image": encode_image_to_base64(candidate["image"]),
            }
            for view, candidate in selected.items()
        ],
    }
    response = requests.post(
        f"{MISSING_VIEW_BASE_URL}/generate-view",
        json=payload,
        timeout=MISSING_VIEW_TIMEOUT_SECONDS,
    )
    response.raise_for_status()

    content_type = response.headers.get("content-type", "")
    if "application/json" in content_type:
        generated_b64 = response.json().get("image")
        if not generated_b64:
            raise ValueError(f"Missing-view API did not return an image for '{target_view}'.")
        return load_image_from_base64(generated_b64)

    return Image.open(BytesIO(response.content)).convert("RGBA")


def _fill_missing_canonical_views(
    selected: dict[str, dict],
    auto_fill_missing_views: bool,
) -> dict[str, dict]:
    missing = [view for view in CANONICAL_VIEWS if view not in selected]
    if not missing:
        return selected
    if not auto_fill_missing_views:
        raise ValueError(
            "Hunyuan multiview generation requires canonical views: "
            f"{', '.join(missing)}"
        )

    for view in missing:
        generated = _generate_missing_view(view, selected)
        if generated is None:
            logger.info(
                "Missing canonical view '%s' will be inferred by Hunyuan3D-2mv from provided views.",
                view,
            )
            continue
        selected[view] = {
            "id": f"generated_{view}",
            "image": generated,
            "view_label": view,
            "source": "generated",
            "confidence": 1.0,
            "quality": 1.0,
            "order": 10_000 + len(selected),
            "is_exact": True,
        }
        logger.info("Generated missing canonical view via %s: %s", MISSING_VIEW_PROVIDER, view)

    return selected


class ModelWorker:
    def __init__(
        self,
        model_path: str = "tencent/Hunyuan3D-2mv",
        tex_model_path: str = "tencent/Hunyuan3D-2",
        subfolder: str = "hunyuan3d-dit-v2-mv",
        device: str = "cuda",
        enable_tex: bool = False,
    ):
        self.model_path = model_path
        self.tex_model_path = tex_model_path
        self.subfolder = subfolder
        self.worker_id = worker_id
        self.device = device
        self.enable_tex = enable_tex

        logger.info(f"Loading shape model: {model_path}/{subfolder} on worker {worker_id}")

        self.rembg = BackgroundRemover()

        self.pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
            model_path,
            subfolder=subfolder,
            use_safetensors=True,
            device=device,
        )

        self.pipeline.enable_flashvdm(mc_algo="mc")

        self.pipeline_tex = None
        if enable_tex:
            logger.info(f"Loading texture model: {tex_model_path}")
            self.pipeline_tex = Hunyuan3DPaintPipeline.from_pretrained(tex_model_path)

        logger.info("ModelWorker ready.")

    def get_queue_length(self):
        with model_state_lock:
            return active_model_requests + waiting_model_requests

    def get_status(self):
        return {
            "speed": 1,
            "queue_length": self.get_queue_length(),
        }

    def _prepare_image_input(self, params: Dict[str, Any]):
        remove_background = params.get("remove_background", True)
        auto_fill_missing_views = parse_bool(params.get("auto_fill_missing_views"), default=True)

        # General multiview input. We accept all uploaded images as candidates,
        # then collapse them into the canonical four views Hunyuan3D-2mv expects.
        if "views" in params and params.get("views"):
            candidates = []
            unsupported_views = []

            for idx, item in enumerate(params["views"]):
                view_label = normalize_view_label(item.get("view", "unknown"))
                image_b64 = item.get("image")
                if not image_b64:
                    continue

                img = load_image_from_base64(image_b64)
                if remove_background:
                    img = self.rembg(img)

                candidate = {
                    "id": str(item.get("id") or item.get("source_image_id") or f"image_{idx}"),
                    "image": img,
                    "is_exact": view_label in CANONICAL_VIEWS,
                    "order": idx,
                    "view_label": view_label,
                    "source": str(item.get("source") or "real"),
                    "confidence": float(item.get("confidence", 1.0 if view_label in CANONICAL_VIEWS else 0.5)),
                    "quality": float(item.get("quality", 0.5)),
                }
                candidates.append(candidate)

                if view_label not in CANONICAL_VIEWS and view_label not in VIEW_ALIASES:
                    unsupported_views.append(view_label)

            if not candidates:
                raise ValueError("No valid images were provided in `views`.")

            _apply_view_selector(candidates)
            selected = _select_canonical_images(candidates)
            selected = _fill_missing_canonical_views(selected, bool(auto_fill_missing_views))
            image_dict = {
                view: selected[view]["image"]
                for view in CANONICAL_VIEWS
                if view in selected
            }
            if not image_dict:
                raise ValueError(
                    "No canonical front/back/left/right view could be selected from provided images."
                )

            if unsupported_views:
                logger.info(
                    "Unsupported auxiliary view labels were ignored unless the selector relabeled them: %s",
                    sorted(set(unsupported_views)),
                )
            logger.info(
                "Canonical view assignment: %s",
                {
                    view: {
                        "id": selected[view].get("id"),
                        "source": selected[view].get("source", "real"),
                        "view_label": selected[view].get("view_label"),
                    }
                    for view in CANONICAL_VIEWS
                    if view in selected
                },
            )

            params.pop("views", None)
            for view in CANONICAL_VIEWS:
                params.pop(view, None)

            params["image"] = image_dict
            return image_dict

        # Single-image input
        if "image" in params and params.get("image"):
            image = load_image_from_base64(params["image"])

            if remove_background:
                image = self.rembg(image)

            params["image"] = image
            return image

        # Multiview input: front/back/left/right. Hunyuan3D-2mv accepts a
        # subset of canonical views and infers unobserved sides during sampling.
        if any(params.get(view) for view in CANONICAL_VIEWS):
            image_dict = {}

            for view in CANONICAL_VIEWS:
                if params.get(view):
                    img = load_image_from_base64(params[view])

                    if remove_background:
                        img = self.rembg(img)

                    image_dict[view] = img

            for view in CANONICAL_VIEWS:
                params.pop(view, None)

            params["image"] = image_dict
            return image_dict

        raise ValueError("No input image provided. Use either `image` or `front/back/left/right`.")

    @torch.inference_mode()
    def generate(self, uid, params: Dict[str, Any]):
        logger.info(f"Worker generating uid={uid}")

        image = self._prepare_image_input(params)

        file_type = params.get("type", params.get("file_type", "glb"))
        texture_enabled = parse_bool(params.get("texture"), default=False)
        face_count = int(params.get("face_count", params.get("target_face_num", 1000000)))

        if "mesh" in params and params.get("mesh"):
            logger.info("Loading input mesh from request.")
            mesh = trimesh.load(BytesIO(base64.b64decode(params["mesh"])), file_type="glb")

        else:
            seed = params.get("seed", 1234)

            shape_params = {
                "image": params["image"],
                "generator": torch.Generator(self.device).manual_seed(seed),
                "octree_resolution": params.get("octree_resolution", 384),
                "num_inference_steps": params.get("num_inference_steps", 40),
                "guidance_scale": params.get("guidance_scale", 5.0),
                "num_chunks": params.get("num_chunks", 8000),
                "mc_algo": "mc",
            }

            logger.info(
                "Shape params: "
                f"steps={shape_params['num_inference_steps']}, "
                f"octree={shape_params['octree_resolution']}, "
                f"guidance={shape_params['guidance_scale']}, "
                f"chunks={shape_params['num_chunks']}, "
                f"seed={seed}"
            )

            import time
            start_time = time.time()

            logger.info("Starting shape pipeline...")
            mesh = self.pipeline(**shape_params)[0]
            logger.info(f"Shape pipeline done. Took {time.time() - start_time:.2f} seconds.")

        if texture_enabled:
            if not self.enable_tex or self.pipeline_tex is None:
                raise ValueError("Texture requested, but server was not started with --enable_tex.")

            logger.info("Starting mesh cleanup before texture...")
            mesh = FloaterRemover()(mesh)
            mesh = DegenerateFaceRemover()(mesh)
            mesh = FaceReducer()(mesh, max_facenum=face_count)

            texture_image = collect_texture_reference_images(image)
            texture_image_count = len(texture_image) if isinstance(texture_image, list) else 1
            texture_use_delight = parse_bool(params.get("texture_use_delight"), default=True)
            preserve_texture_color = parse_bool(params.get("preserve_texture_color"), default=True)
            texture_color_match_strength = float(params.get("texture_color_match_strength", 0.75))

            logger.info(
                "Starting texture pipeline with %d reference image(s), "
                "use_delight=%s, preserve_color=%s, color_strength=%.2f...",
                texture_image_count,
                texture_use_delight,
                preserve_texture_color,
                texture_color_match_strength,
            )
            mesh = self.pipeline_tex(
                mesh,
                texture_image,
                use_delight=texture_use_delight,
                preserve_color=preserve_texture_color,
                color_match_strength=texture_color_match_strength,
            )
            logger.info("Texture pipeline done.")

        with tempfile.NamedTemporaryFile(suffix=f".{file_type}", delete=False) as temp_file:
            logger.info(f"Exporting temp mesh: {temp_file.name}")
            mesh.export(temp_file.name)

            logger.info("Reloading temp mesh.")
            mesh = trimesh.load(temp_file.name)

            save_path = os.path.join(SAVE_DIR, f"{str(uid)}.{file_type}")
            logger.info(f"Exporting final mesh: {save_path}")
            mesh.export(save_path)

        torch.cuda.empty_cache()
        logger.info(f"Generation complete: {save_path}")

        return save_path, uid


def generate_with_model_gate(uid, params):
    global active_model_requests, waiting_model_requests

    if model_semaphore is None:
        return worker.generate(uid, params)

    with model_state_lock:
        waiting_model_requests += 1

    model_semaphore.acquire()
    try:
        with model_state_lock:
            waiting_model_requests -= 1
            active_model_requests += 1

        return worker.generate(uid, params)
    finally:
        with model_state_lock:
            active_model_requests -= 1
        model_semaphore.release()


def get_cors_allow_origins():
    value = os.getenv("CORS_ALLOW_ORIGINS", "*")
    origins = [origin.strip() for origin in value.split(",") if origin.strip()]
    return origins or ["*"]


app = FastAPI(title="Hunyuan3D-2mv API")

cors_allow_origins = get_cors_allow_origins()
app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_allow_origins,
    allow_credentials="*" not in cors_allow_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/generate")
async def generate(request: Request):
    logger.info("POST /generate")
    params = await request.json()
    uid = uuid.uuid4()

    try:
        loop = asyncio.get_running_loop()
        file_path, uid = await loop.run_in_executor(None, generate_with_model_gate, uid, params)
        return FileResponse(file_path)

    except ValueError as e:
        traceback.print_exc()
        logger.error(f"Caught ValueError: {e}")
        return JSONResponse(
            {
                "text": server_error_msg,
                "error": str(e),
                "error_code": 1,
            },
            status_code=400,
        )

    except torch.cuda.OutOfMemoryError as e:
        torch.cuda.empty_cache()
        traceback.print_exc()
        logger.error(f"Caught CUDA OOM: {e}")
        return JSONResponse(
            {
                "text": "CUDA out of memory.",
                "error": str(e),
                "error_code": 1,
            },
            status_code=500,
        )

    except torch.cuda.CudaError as e:
        torch.cuda.empty_cache()
        traceback.print_exc()
        logger.error(f"Caught torch.cuda.CudaError: {e}")
        return JSONResponse(
            {
                "text": server_error_msg,
                "error": str(e),
                "error_code": 1,
            },
            status_code=500,
        )

    except Exception as e:
        traceback.print_exc()
        logger.error(f"Caught Unknown Error: {e}")
        return JSONResponse(
            {
                "text": server_error_msg,
                "error": str(e),
                "error_code": 1,
            },
            status_code=500,
        )


@app.post("/send")
async def send(request: Request):
    logger.info("POST /send")
    params = await request.json()
    uid = uuid.uuid4()

    threading.Thread(target=generate_with_model_gate, args=(uid, params), daemon=True).start()

    return JSONResponse({"uid": str(uid)}, status_code=200)


@app.get("/status/{uid}")
async def status(uid: str):
    save_file_path = os.path.join(SAVE_DIR, f"{uid}.glb")
    logger.info(f"GET /status/{uid}: {save_file_path}, exists={os.path.exists(save_file_path)}")

    if not os.path.exists(save_file_path):
        return JSONResponse({"status": "processing"}, status_code=200)

    with open(save_file_path, "rb") as f:
        base64_str = base64.b64encode(f.read()).decode()

    return JSONResponse(
        {
            "status": "completed",
            "model_base64": base64_str,
        },
        status_code=200,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument("--host", type=str, default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)

    parser.add_argument("--model_path", type=str, default="tencent/Hunyuan3D-2mv")
    parser.add_argument("--subfolder", type=str, default="hunyuan3d-dit-v2-mv")
    parser.add_argument("--tex_model_path", type=str, default="tencent/Hunyuan3D-2")

    parser.add_argument("--device", type=str, default="cuda")
    parser.add_argument("--limit-model-concurrency", type=int, default=1)
    parser.add_argument("--enable_tex", action="store_true")

    args = parser.parse_args()
    logger.info(f"args: {args}")

    model_semaphore = threading.BoundedSemaphore(args.limit_model_concurrency)

    worker = ModelWorker(
        model_path=args.model_path,
        tex_model_path=args.tex_model_path,
        subfolder=args.subfolder,
        device=args.device,
        enable_tex=args.enable_tex,
    )

    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level="info",
    )

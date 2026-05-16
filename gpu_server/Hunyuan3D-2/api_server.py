# api_server.py
import argparse
import asyncio
import base64
import logging
import logging.handlers
import os
import sys
import tempfile
import threading
import traceback
import uuid
from io import BytesIO
from typing import Dict, Any

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


def load_image_from_base64(image_b64: str) -> Image.Image:
    return Image.open(BytesIO(base64.b64decode(image_b64))).convert("RGBA")


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
        if model_semaphore is None:
            return 0

        waiters = 0
        if model_semaphore._waiters is not None:
            waiters = len(model_semaphore._waiters)

        return args.limit_model_concurrency - model_semaphore._value + waiters

    def get_status(self):
        return {
            "speed": 1,
            "queue_length": self.get_queue_length(),
        }

    def _prepare_image_input(self, params: Dict[str, Any]):
        remove_background = params.get("remove_background", True)

        # Single-image input
        if "image" in params and params.get("image"):
            image = load_image_from_base64(params["image"])

            if remove_background:
                image = self.rembg(image)

            params["image"] = image
            return image

        # Multiview input: front/back/left/right
        if "front" in params and params.get("front"):
            image_dict = {}

            for view in ["front", "back", "left", "right"]:
                if params.get(view):
                    img = load_image_from_base64(params[view])

                    if remove_background:
                        img = self.rembg(img)

                    image_dict[view] = img

            if "front" not in image_dict:
                raise ValueError("Front image is required for multiview generation.")

            for view in ["front", "back", "left", "right"]:
                params.pop(view, None)

            params["image"] = image_dict
            return image_dict

        raise ValueError("No input image provided. Use either `image` or `front/back/left/right`.")

    @torch.inference_mode()
    def generate(self, uid, params: Dict[str, Any]):
        logger.info(f"Worker generating uid={uid}")

        image = self._prepare_image_input(params)

        file_type = params.get("type", params.get("file_type", "glb"))
        texture_enabled = params.get("texture", False)

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
            mesh = FaceReducer()(mesh, max_facenum=params.get("face_count", 40000))

            texture_image = image["front"] if isinstance(image, dict) else image

            logger.info("Starting texture pipeline...")
            mesh = self.pipeline_tex(mesh, texture_image)
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


app = FastAPI(title="Hunyuan3D-2mv API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # testing only
    allow_credentials=True,
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
        file_path, uid = worker.generate(uid, params)
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

    threading.Thread(target=worker.generate, args=(uid, params), daemon=True).start()

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

    model_semaphore = asyncio.Semaphore(args.limit_model_concurrency)

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
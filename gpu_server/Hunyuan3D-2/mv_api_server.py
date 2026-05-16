import base64
import os
import uuid
from io import BytesIO
from typing import Optional, Dict

import torch
from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
from PIL import Image

from hy3dgen.rembg import BackgroundRemover
from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline
from hy3dgen.texgen import Hunyuan3DPaintPipeline


SAVE_DIR = "./api_outputs"
os.makedirs(SAVE_DIR, exist_ok=True)

app = FastAPI(title="Hunyuan3D-2mv Multiview API")

print("Loading shape model: tencent/Hunyuan3D-2mv / hunyuan3d-dit-v2-mv")
shape_pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
    "tencent/Hunyuan3D-2mv",
    subfolder="hunyuan3d-dit-v2-mv",
    variant="fp16",
)

print("Loading texture model: tencent/Hunyuan3D-2")
tex_pipeline = Hunyuan3DPaintPipeline.from_pretrained("tencent/Hunyuan3D-2")

rembg = BackgroundRemover()


class MultiViewRequest(BaseModel):
    front: str
    back: Optional[str] = None
    left: Optional[str] = None
    right: Optional[str] = None

    remove_background: bool = False
    texture: bool = True

    seed: int = 1234
    num_inference_steps: int = 40
    octree_resolution: int = 384
    guidance_scale: float = 5.0
    num_chunks: int = 8000
    file_type: str = "glb"


def decode_image(image_b64: str, remove_background: bool) -> Image.Image:
    image = Image.open(BytesIO(base64.b64decode(image_b64))).convert("RGBA")
    if remove_background:
        image = rembg(image)
    return image


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/generate")
def generate(req: MultiViewRequest):
    try:
        images: Dict[str, Image.Image] = {
            "front": decode_image(req.front, req.remove_background)
        }

        if req.back:
            images["back"] = decode_image(req.back, req.remove_background)
        if req.left:
            images["left"] = decode_image(req.left, req.remove_background)
        if req.right:
            images["right"] = decode_image(req.right, req.remove_background)

        generator = torch.manual_seed(req.seed)

        mesh = shape_pipeline(
            image=images,
            num_inference_steps=req.num_inference_steps,
            octree_resolution=req.octree_resolution,
            guidance_scale=req.guidance_scale,
            num_chunks=req.num_chunks,
            generator=generator,
            output_type="trimesh",
        )[0]

        if req.texture:
            mesh = tex_pipeline(mesh, image=images["front"])

        out_path = os.path.join(SAVE_DIR, f"{uuid.uuid4()}.{req.file_type}")
        mesh.export(out_path)

        torch.cuda.empty_cache()

        media_type = "model/gltf-binary" if req.file_type == "glb" else "application/octet-stream"
        return FileResponse(out_path, media_type=media_type, filename=os.path.basename(out_path))

    except torch.cuda.OutOfMemoryError as e:
        torch.cuda.empty_cache()
        return JSONResponse(
            status_code=500,
            content={"error": "CUDA out of memory", "detail": str(e)}
        )
    except Exception as e:
        return JSONResponse(
            status_code=500,
            content={"error": type(e).__name__, "detail": str(e)}
        )

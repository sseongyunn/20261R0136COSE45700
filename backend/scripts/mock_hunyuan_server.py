from __future__ import annotations

from fastapi import FastAPI, Request, Response


app = FastAPI(title="Mock Hunyuan GPU Server")


def _minimal_glb() -> bytes:
    json_chunk = b'{"asset":{"version":"2.0"},"scenes":[{"nodes":[]}],"scene":0}'
    padding = (4 - (len(json_chunk) % 4)) % 4
    json_chunk += b" " * padding
    total_length = 12 + 8 + len(json_chunk)
    header = b"glTF" + (2).to_bytes(4, "little") + total_length.to_bytes(4, "little")
    chunk_header = len(json_chunk).to_bytes(4, "little") + b"JSON"
    return header + chunk_header + json_chunk


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "mode": "mock"}


@app.post("/generate")
async def generate(request: Request) -> Response:
    await request.json()
    return Response(content=_minimal_glb(), media_type="model/gltf-binary")

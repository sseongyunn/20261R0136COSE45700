#!/usr/bin/env python3
"""
MASt3R Pipeline API Server

Hunyuan 서버(포트 5173)와 동일한 방식으로,
5단계 3D 생성 파이프라인을 HTTP API로 제공합니다.
포트: 5174
"""
from __future__ import annotations

import base64
import logging
import sys
from pathlib import Path
from typing import List, Optional

import uvicorn
from fastapi import FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

sys.path.insert(0, str(Path(__file__).parent))
import pipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("mast3r-api")

app = FastAPI(
    title="MASt3R 3D Generation Pipeline",
    description=(
        "5단계 파이프라인으로 공식 상품 이미지와 리뷰 사진을 결합하여 "
        "고품질 AR용 3D 모델(.glb)을 생성합니다.\n\n"
        "**단계:**\n"
        "1. 공식 이미지 → InstantMesh → base 3D\n"
        "2. 리뷰 사진 전처리 (배경 제거, 품질 필터링)\n"
        "3. MASt3R geometry 분석 및 일관성 검증\n"
        "4. 누락 부분 보완 (point cloud 병합 / Zero123++)\n"
        "5. Mesh 단순화, UV 언래핑, 텍스처 베이킹, GLB 패키징"
    ),
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ImageEntry(BaseModel):
    image: str = Field(..., description="Base64 인코딩된 이미지 데이터")
    view: Optional[str] = Field(default="unknown", description="촬영 각도")
    source: Optional[str] = Field(default="official", description="이미지 출처 (official|review)")


class GenerateRequest(BaseModel):
    official_images: List[ImageEntry] = Field(..., min_items=1, description="공식 상품 이미지 (최소 1장)")
    review_images: Optional[List[ImageEntry]] = Field(default=[], description="사용자 리뷰 사진 (선택적)")
    remove_background: bool = Field(default=True, description="배경 제거 여부")
    target_faces: int = Field(default=50_000, ge=1_000, le=500_000, description="최종 메쉬 최대 폴리곤 수")
    texture_size: int = Field(default=2048, description="텍스처 해상도 (px)")
    octree_resolution: int = Field(default=256, description="InstantMesh 메쉬 해상도")
    num_inference_steps: int = Field(default=75, ge=20, le=200, description="추론 스텝 수")
    file_type: str = Field(default="glb", description="출력 파일 형식")


class HealthResponse(BaseModel):
    status: str
    pipeline_stages: List[str]


@app.get("/health", response_model=HealthResponse, tags=["System"])
def health_check():
    """서버 상태 확인."""
    return HealthResponse(
        status="ok",
        pipeline_stages=[
            "stage1: InstantMesh (official images → base mesh)",
            "stage2: Review image preprocessing",
            "stage3: MASt3R geometry analysis",
            "stage4: Missing part completion (Zero123++ / point cloud)",
            "stage5: Mesh post-processing → GLB",
        ],
    )


@app.post(
    "/generate",
    tags=["Generation"],
    response_class=None,
    responses={200: {"content": {"model/gltf-binary": {}}, "description": "생성된 GLB 파일"}},
    summary="5단계 파이프라인으로 3D 모델 생성",
)
async def generate(request: GenerateRequest):
    """
    공식 상품 이미지와 리뷰 사진을 결합하여 AR용 3D 모델(.glb)을 생성합니다.

    응답: `Content-Type: model/gltf-binary` (GLB 바이너리)
    """
    from fastapi.responses import Response

    logger.info("생성 요청 수신: official=%d, review=%d",
                len(request.official_images), len(request.review_images or []))

    def entry_to_dict(entry: ImageEntry) -> dict:
        raw = base64.b64decode(entry.image)
        return {"image": raw, "view": entry.view, "source": entry.source}

    official_dicts = [entry_to_dict(e) for e in request.official_images]
    review_dicts = [entry_to_dict(e) for e in (request.review_images or [])]

    try:
        result = pipeline.run_pipeline(
            official_images=official_dicts,
            review_images=review_dicts,
            remove_background=request.remove_background,
            target_faces=request.target_faces,
            texture_size=request.texture_size,
            octree_resolution=request.octree_resolution,
            num_inference_steps=request.num_inference_steps,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    except Exception as exc:
        logger.exception("파이프라인 실행 오류")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"3D 생성 실패: {exc}",
        )

    glb_bytes = result["glb"]
    if not glb_bytes:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="GLB 생성 결과가 비어있습니다.",
        )

    headers = {}
    if result.get("warnings"):
        headers["X-Pipeline-Warnings"] = "; ".join(result["warnings"])
    stage_times = result.get("stage_times", {})
    if stage_times:
        headers["X-Pipeline-Total-Seconds"] = str(round(stage_times.get("total", 0), 1))

    logger.info("생성 완료: %d bytes, 총 %.1fs", len(glb_bytes), stage_times.get("total", 0))
    return Response(content=glb_bytes, media_type="model/gltf-binary", headers=headers)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="MASt3R Pipeline API Server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5174)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--log-level", default="info")
    args = parser.parse_args()

    logger.info("MASt3R Pipeline 서버 시작: http://%s:%d", args.host, args.port)
    uvicorn.run(
        "api_server:app",
        host=args.host,
        port=args.port,
        workers=args.workers,
        log_level=args.log_level,
    )

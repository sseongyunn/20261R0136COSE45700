#!/usr/bin/env bash
# =============================================================================
# MASt3R Pipeline — GPU 서버 설치 스크립트
# Ubuntu 20.04/22.04, CUDA 11.8 or 12.1 환경 기준
#
# 사용법:
#   chmod +x setup_mast3r_env.sh
#   ./setup_mast3r_env.sh
# =============================================================================
set -e

CONDA_ENV="mast3r"
PIPELINE_DIR="/home/ubuntu/furniture-ar-backend/gpu_server/mast3r_pipeline"
CKPT_DIR="${PIPELINE_DIR}/checkpoints"
CONFIG_DIR="${PIPELINE_DIR}/configs"

echo "============================================================"
echo "  MASt3R Pipeline 환경 설치 시작"
echo "============================================================"

# ── 0. CUDA 버전 확인 ─────────────────────────────────────────────────────────
echo ""
echo "[0/7] CUDA 버전 확인..."
if command -v nvcc &>/dev/null; then
    CUDA_VER=$(nvcc --version | grep "release" | awk '{print $6}' | cut -c2-)
    echo "  CUDA 버전: ${CUDA_VER}"
else
    echo "  ⚠️  nvcc를 찾을 수 없습니다. CUDA 드라이버를 확인하세요."
    nvidia-smi || echo "  ⚠️  nvidia-smi도 없습니다. GPU 드라이버 설치가 필요합니다."
fi

# ── 1. Conda 환경 생성 ────────────────────────────────────────────────────────
echo ""
echo "[1/7] Conda 환경 '${CONDA_ENV}' 생성 (Python 3.10)..."
source /opt/conda/etc/profile.d/conda.sh

if conda env list | grep -q "^${CONDA_ENV}"; then
    echo "  이미 존재합니다 → 건너뜀"
else
    conda create -y -n "${CONDA_ENV}" python=3.10
    echo "  ✅ 환경 생성 완료"
fi

conda activate "${CONDA_ENV}"

# ── 2. PyTorch 설치 ───────────────────────────────────────────────────────────
echo ""
echo "[2/7] PyTorch (CUDA 12.1) 설치..."
# CUDA 11.8 사용 시: torch==2.2.0+cu118 --index-url https://download.pytorch.org/whl/cu118
pip install torch==2.2.0 torchvision==0.17.0 --index-url https://download.pytorch.org/whl/cu121 --quiet
echo "  ✅ PyTorch 설치 완료"
python -c "import torch; print(f'  PyTorch {torch.__version__}, CUDA available: {torch.cuda.is_available()}')"

# ── 3. 기본 패키지 설치 ───────────────────────────────────────────────────────
echo ""
echo "[3/7] 기본 패키지 설치..."
pip install --quiet \
    fastapi \
    "uvicorn[standard]" \
    pydantic \
    Pillow \
    numpy \
    opencv-python-headless \
    rembg \
    trimesh \
    open3d \
    xatlas \
    diffusers \
    transformers \
    accelerate \
    omegaconf \
    einops \
    huggingface_hub \
    requests \
    scipy
echo "  ✅ 기본 패키지 설치 완료"

# ── 4. MASt3R / DUSt3R 설치 ──────────────────────────────────────────────────
echo ""
echo "[4/7] MASt3R + DUSt3R 설치 (GitHub)..."
TMP_DIR=$(mktemp -d)

# DUSt3R 먼저 설치 (MASt3R가 의존)
echo "  DUSt3R 클론 중..."
git clone --quiet https://github.com/naver/dust3r.git "${TMP_DIR}/dust3r"
pip install --quiet -e "${TMP_DIR}/dust3r"
echo "  ✅ DUSt3R 설치 완료"

# MASt3R 설치
echo "  MASt3R 클론 중..."
git clone --quiet https://github.com/naver/mast3r.git "${TMP_DIR}/mast3r"
pip install --quiet -e "${TMP_DIR}/mast3r"
echo "  ✅ MASt3R 설치 완료"

# ── 5. InstantMesh 설치 ──────────────────────────────────────────────────────
echo ""
echo "[5/7] InstantMesh 설치 (GitHub)..."
git clone --quiet https://github.com/TencentARC/InstantMesh.git "${TMP_DIR}/InstantMesh"
pip install --quiet -e "${TMP_DIR}/InstantMesh"
echo "  ✅ InstantMesh 설치 완료"

# ── 6. 모델 가중치 다운로드 ──────────────────────────────────────────────────
echo ""
echo "[6/7] 모델 가중치 다운로드..."
mkdir -p "${CKPT_DIR}" "${CONFIG_DIR}"

# MASt3R 모델 (Hugging Face에서 자동 캐시 — 첫 실행 시 자동 다운)
echo "  MASt3R 가중치는 첫 실행 시 자동 다운로드됩니다"
echo "    모델: naver/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric (~1.5GB)"

# InstantMesh 모델 다운로드
echo "  InstantMesh 가중치 다운로드 중..."
python - <<'PYEOF'
from huggingface_hub import hf_hub_download
import os

ckpt_dir = os.environ.get("CKPT_DIR", "/home/ubuntu/furniture-ar-backend/gpu_server/mast3r_pipeline/checkpoints")
os.makedirs(ckpt_dir, exist_ok=True)

print("  instant-mesh-large.ckpt 다운로드 중 (~4GB)...")
path = hf_hub_download(
    repo_id="TencentARC/InstantMesh",
    filename="instant-mesh-large.ckpt",
    local_dir=ckpt_dir,
)
print(f"  ✅ 저장 완료: {path}")
PYEOF

# InstantMesh config 복사
echo "  InstantMesh config 복사 중..."
CONFIG_SRC="${TMP_DIR}/InstantMesh/configs/instant-mesh-large.yaml"
if [ -f "${CONFIG_SRC}" ]; then
    cp "${CONFIG_SRC}" "${CONFIG_DIR}/instant-mesh-large.yaml"
    echo "  ✅ config 복사 완료: ${CONFIG_DIR}/instant-mesh-large.yaml"
else
    echo "  ⚠️  config 파일을 찾을 수 없습니다. 수동으로 복사하세요."
fi

# Zero123++ 모델은 첫 실행 시 diffusers가 자동 다운로드
echo "  Zero123++ 가중치는 첫 실행 시 자동 다운로드됩니다"
echo "    모델: sudo-ai/zero123plus-v1.2 (~3GB)"

# ── 7. 설치 검증 ─────────────────────────────────────────────────────────────
echo ""
echo "[7/7] 설치 검증..."
python - <<'PYEOF'
import sys
print(f"  Python: {sys.version.split()[0]}")

checks = [
    ("torch", "PyTorch"),
    ("fastapi", "FastAPI"),
    ("trimesh", "trimesh"),
    ("open3d", "Open3D"),
    ("cv2", "OpenCV"),
    ("rembg", "rembg"),
    ("xatlas", "xatlas"),
    ("diffusers", "diffusers"),
    ("omegaconf", "omegaconf"),
]

all_ok = True
for module, name in checks:
    try:
        __import__(module)
        print(f"  ✅ {name}")
    except ImportError:
        print(f"  ❌ {name} (설치 실패)")
        all_ok = False

try:
    from mast3r.model import AsymmetricMASt3R
    print("  ✅ MASt3R")
except ImportError:
    print("  ❌ MASt3R (설치 실패)")
    all_ok = False

import torch
cuda_ok = torch.cuda.is_available()
print(f"  {'✅' if cuda_ok else '⚠️ '} CUDA: {'사용 가능' if cuda_ok else '사용 불가 (CPU 모드로 동작)'}")

if all_ok:
    print("\n  🎉 모든 패키지 설치 완료!")
else:
    print("\n  ⚠️  일부 패키지 설치 실패. 위 오류를 확인하세요.")
PYEOF

# ── 완료 ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ✅ 설치 완료!"
echo ""
echo "  서버 실행 방법:"
echo "    cd ${PIPELINE_DIR}"
echo "    bash start_mast3r_pipeline.sh"
echo ""
echo "  API 문서 (서버 실행 후):"
echo "    http://서버IP:5174/docs"
echo ""
echo "  ⚠️  주의: 첫 실행 시 MASt3R, Zero123++ 모델이 자동 다운로드됩니다."
echo "           충분한 디스크 공간 (~10GB)을 확인하세요."
echo "============================================================"

# MASt3R Pipeline — GPU 서버 설치 및 실행 가이드

## 전체 폴더 구조

```
gpu_server/
├── Hunyuan3D-2/                    ← 기존 (변경 없음, 포트 5173)
├── start_hunyuan_v2.sh
│
└── mast3r_pipeline/                ← 새로 추가
    ├── setup_mast3r_env.sh         ← 설치 스크립트 (이것만 실행하면 됨)
    ├── start_mast3r_pipeline.sh    ← 서버 실행
    ├── api_server.py               ← FastAPI 서버 (포트 5174)
    ├── pipeline.py                 ← 5단계 오케스트레이터
    ├── requirements.txt
    └── stages/
        ├── stage1_base.py          ← InstantMesh
        ├── stage2_review.py        ← 리뷰 이미지 전처리
        ├── stage3_mast3r.py        ← MASt3R geometry 분석
        ├── stage4_complete.py      ← 누락 부분 보완
        └── stage5_post.py          ← 후처리 → 최종 GLB
```

---

## Step 1. GPU 서버에 접속

```bash
ssh ubuntu@<GPU 서버 IP>
```

---

## Step 2. 코드 배포 (로컬 → 서버)

```bash
# 로컬 Mac에서 실행
cd "Desktop/고려대학교 파일/5-1/SW 프로젝트/Furniture_Backend"
rsync -avz --progress gpu_server/mast3r_pipeline/ \
    ubuntu@<서버IP>:/home/ubuntu/furniture-ar-backend/gpu_server/mast3r_pipeline/
```

---

## Step 3. 설치 스크립트 실행 (서버에서)

```bash
cd /home/ubuntu/furniture-ar-backend/gpu_server/mast3r_pipeline
chmod +x setup_mast3r_env.sh
./setup_mast3r_env.sh
```

> ⚠️ **시간:** 약 15~30분 소요 (모델 다운로드 포함)  
> 💾 **디스크:** 약 10~15GB 필요

---

## Step 4. 서버 실행

```bash
chmod +x start_mast3r_pipeline.sh
./start_mast3r_pipeline.sh
```

서버가 정상 실행되면:
```
INFO:     Started server process [PID]
INFO:     Uvicorn running on http://0.0.0.0:5174
```

---

## Step 5. 동작 확인

### Health Check
```bash
curl http://localhost:5174/health
```
```json
{
  "status": "ok",
  "pipeline_stages": [
    "stage1: InstantMesh (official images → base mesh)",
    "stage2: Review image preprocessing",
    "stage3: MASt3R geometry analysis",
    "stage4: Missing part completion (Zero123++ / point cloud)",
    "stage5: Mesh post-processing → GLB"
  ]
}
```

### 3D 생성 테스트 (Python)
```python
import requests, base64

with open("chair_front.jpg", "rb") as f:
    front_b64 = base64.b64encode(f.read()).decode()

with open("review1.jpg", "rb") as f:
    review_b64 = base64.b64encode(f.read()).decode()

response = requests.post("http://서버IP:5174/generate", json={
    "official_images": [
        {"image": front_b64, "view": "front"}
    ],
    "review_images": [
        {"image": review_b64, "source": "review"}
    ],
    "target_faces": 50000,
    "texture_size": 2048
})

with open("result.glb", "wb") as f:
    f.write(response.content)
print("GLB 저장 완료!")
```

---

## 두 서버 동시 운영

| 서버 | 포트 | 모델 | 실행 스크립트 |
|------|------|------|--------------|
| Hunyuan (기존) | 5173 | Hunyuan3D-2mv | `start_hunyuan_v2.sh` |
| MASt3R Pipeline (신규) | 5174 | InstantMesh + MASt3R + Zero123++ | `start_mast3r_pipeline.sh` |

```bash
# 두 서버 동시에 백그라운드로 실행
nohup bash /home/ubuntu/furniture-ar-backend/gpu_server/start_hunyuan_v2.sh > /var/log/hunyuan.log 2>&1 &
nohup bash /home/ubuntu/furniture-ar-backend/gpu_server/mast3r_pipeline/start_mast3r_pipeline.sh > /var/log/mast3r.log 2>&1 &
```

---

## GPU 메모리 참고

| 모델 | VRAM 사용량 |
|------|------------|
| Hunyuan3D-2mv (기존) | ~16GB |
| MASt3R | ~8GB |
| InstantMesh (Zero123++ + LRM) | ~18GB |
| **MASt3R Pipeline 합산** | **~24GB** |

> 💡 **권장 GPU:** A100 40GB (또는 A6000 48GB)  
> **최소 GPU:** A10G 24GB (메모리 타이트)

---

## 첫 실행 시 자동 다운로드되는 모델

| 모델 | 크기 | 저장 위치 |
|------|------|----------|
| MASt3R ViTLarge | ~1.5GB | `~/.cache/huggingface/` |
| InstantMesh Large | ~4GB | `checkpoints/instant-mesh-large.ckpt` |
| Zero123++ v1.2 | ~3GB | `~/.cache/huggingface/` |
| rembg (U2Net) | ~180MB | `~/.u2net/` |

**합계: 약 9GB**

---

## 문제 해결

### `ModuleNotFoundError: mast3r`
```bash
conda activate mast3r
pip install git+https://github.com/naver/mast3r.git
pip install git+https://github.com/naver/dust3r.git
```

### CUDA OOM (Out of Memory)
`start_mast3r_pipeline.sh`에서 환경변수 추가:
```bash
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
```

### InstantMesh config 오류
```bash
# InstantMesh 레포에서 직접 config 복사
wget -O configs/instant-mesh-large.yaml \
    https://raw.githubusercontent.com/TencentARC/InstantMesh/main/configs/instant-mesh-large.yaml
```

#!/usr/bin/env bash
# MASt3R Pipeline 서버 시작 스크립트
# Hunyuan 서버(포트 5173)와 별개로 포트 5174에서 실행됩니다.
set -e

source /opt/conda/etc/profile.d/conda.sh
conda activate mast3r  # mast3r 전용 conda 환경

cd /home/ubuntu/furniture-ar-backend/gpu_server/mast3r_pipeline

# 모델 경로 환경변수 (필요 시 수정)
export INSTANTMESH_CONFIG="configs/instant-mesh-large.yaml"
export INSTANTMESH_CKPT="checkpoints/instant-mesh-large.ckpt"
export MAST3R_MODEL_NAME="naver/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric"

exec python api_server.py \
  --host 0.0.0.0 \
  --port 5174 \
  --workers 1 \
  --log-level info

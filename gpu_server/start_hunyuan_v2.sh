#!/usr/bin/env bash
set -e

source /opt/conda/etc/profile.d/conda.sh
conda activate hy3d

cd /home/ubuntu/furniture-ar-backend/gpu_server/Hunyuan3D-2

exec python api_server.py \
  --host 0.0.0.0 \
  --port 5173 \
  --model_path tencent/Hunyuan3D-2mv \
  --subfolder hunyuan3d-dit-v2-mv \
  --tex_model_path tencent/Hunyuan3D-2 \
  --enable_tex

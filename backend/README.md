# Furniture AR Backend MVP

FastAPI backend and worker for the furniture image-to-3D MVP.

## Environment

Create `backend/.env` or repository-root `.env`:

```bash
DATABASE_URL=postgresql://vibecoders:<DB_PASSWORD>@ku-hys-06.cgxkyy4aox5u.us-east-1.rds.amazonaws.com:5432/postgres?sslmode=require
AWS_REGION=us-east-1
S3_BUCKET=ku-hys-06
VARCO_API_KEY=<VARCO_API_KEY>
JWT_SECRET=<JWT_SECRET>
MOCK_VARCO=false

# VARCO defaults from the Image to 3D docs. Keep these unless VARCO changes them.
VARCO_API_KEY_HEADER=OPENAPI_KEY
VARCO_SUBMIT_URL=https://openapi.ai.nc.com/3d/varco/v1/image-to-3d
VARCO_RESULT_URL_TEMPLATE=https://openapi.ai.nc.com/inference/result/{request_id}
VARCO_TARGET_FACE_TYPE=tri
VARCO_TARGET_FACE_NUM=300000
VARCO_GENERATE_TEXTURE=true
VARCO_SEED=-1
VARCO_CONVERT_IMAGE_TO_PNG=true
```

Do not set `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` on EC2. boto3 uses the EC2 IAM instance profile.

## Database

Apply the schema once:

```bash
psql "$DATABASE_URL" -f sql/schema.sql
```

If the RDS database already has older tables, run the upgrade script once before
starting the worker:

```bash
psql "$DATABASE_URL" -f sql/upgrade_existing.sql
```

## Run API on EC2

```bash
cd ~/furniture-ar-backend/backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 5173
```

With tmux:

```bash
tmux new -s backend
```

Test:

```bash
curl http://100.30.223.95:5173/health
```

API docs:

```text
http://100.30.223.95:5173/docs
```

## Run Worker

```bash
cd ~/furniture-ar-backend/backend
source venv/bin/activate
python worker/generation_worker.py
```

With tmux:

```bash
tmux new -s worker
```

## VARCO Integration

`app/services/varco_service.py` follows the VARCO Image to 3D API docs:

- `POST https://openapi.ai.nc.com/3d/varco/v1/image-to-3d`
- header: `OPENAPI_KEY: <key>`
- multipart file field: `image`
- form fields: `target_face_type`, `target_face_num`, `generate_texture`, `seed`
- result polling: `GET https://openapi.ai.nc.com/inference/result/{request_id}`
- submit response field: `requestId`
- result model field: `model_url`

The documented input format is PNG, so the worker converts uploaded images to
PNG before sending them to VARCO when `VARCO_CONVERT_IMAGE_TO_PNG=true`.

For pipeline testing, keep `MOCK_VARCO=true`. The worker will upload a minimal GLB file to S3 and create a `furniture_assets` row.

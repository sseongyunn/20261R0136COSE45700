CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_identities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  provider_user_id TEXT NOT NULL,
  password_hash TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(provider, provider_user_id),
  CHECK (provider IN ('local', 'google', 'apple'))
);

CREATE TABLE IF NOT EXISTS source_images (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  s3_bucket TEXT NOT NULL,
  s3_key TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(s3_bucket, s3_key)
);

CREATE TABLE IF NOT EXISTS generation_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_image_id UUID NOT NULL REFERENCES source_images(id) ON DELETE CASCADE,

  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'submitted', 'processing', 'succeeded', 'failed')),

  provider TEXT NOT NULL DEFAULT 'varco',
  provider_request_id TEXT,

  requested_name TEXT,
  requested_category TEXT,
  requested_width_cm NUMERIC(8,2),
  requested_height_cm NUMERIC(8,2),
  requested_depth_cm NUMERIC(8,2),

  queued_at TIMESTAMPTZ DEFAULT now(),
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  failure_reason TEXT,

  CHECK (requested_width_cm IS NULL OR requested_width_cm > 0),
  CHECK (requested_height_cm IS NULL OR requested_height_cm > 0),
  CHECK (requested_depth_cm IS NULL OR requested_depth_cm > 0)
);

CREATE TABLE IF NOT EXISTS furniture_assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  generation_job_id UUID UNIQUE NOT NULL REFERENCES generation_jobs(id) ON DELETE CASCADE,

  name TEXT,
  category TEXT,

  width_cm NUMERIC(8,2),
  height_cm NUMERIC(8,2),
  depth_cm NUMERIC(8,2),

  model_s3_bucket TEXT NOT NULL,
  model_s3_key TEXT NOT NULL,

  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  UNIQUE(model_s3_bucket, model_s3_key),

  CHECK (width_cm IS NULL OR width_cm > 0),
  CHECK (height_cm IS NULL OR height_cm > 0),
  CHECK (depth_cm IS NULL OR depth_cm > 0)
);

CREATE INDEX IF NOT EXISTS idx_source_images_user_id 
ON source_images(user_id);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_user_status 
ON generation_jobs(user_id, status);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_status_queued 
ON generation_jobs(status, queued_at);

CREATE INDEX IF NOT EXISTS idx_furniture_assets_user_created 
ON furniture_assets(user_id, created_at DESC);
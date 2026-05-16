CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE generation_jobs
  ADD COLUMN IF NOT EXISTS provider TEXT NOT NULL DEFAULT 'varco',
  ADD COLUMN IF NOT EXISTS provider_request_id TEXT,
  ADD COLUMN IF NOT EXISTS requested_name TEXT,
  ADD COLUMN IF NOT EXISTS requested_category TEXT,
  ADD COLUMN IF NOT EXISTS requested_width_cm NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS requested_height_cm NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS requested_depth_cm NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS failure_reason TEXT,
  ADD COLUMN IF NOT EXISTS generation_mode TEXT NOT NULL DEFAULT 'single',
  ADD COLUMN IF NOT EXISTS source_back_image_id UUID,
  ADD COLUMN IF NOT EXISTS source_left_image_id UUID,
  ADD COLUMN IF NOT EXISTS source_right_image_id UUID;

UPDATE generation_jobs
SET provider = 'varco'
WHERE provider IS NULL;

UPDATE generation_jobs
SET generation_mode = 'single'
WHERE generation_mode IS NULL;

ALTER TABLE generation_jobs
  ALTER COLUMN provider SET DEFAULT 'varco',
  ALTER COLUMN provider SET NOT NULL,
  ALTER COLUMN generation_mode SET DEFAULT 'single',
  ALTER COLUMN generation_mode SET NOT NULL;

ALTER TABLE furniture_assets
  ADD COLUMN IF NOT EXISTS name TEXT,
  ADD COLUMN IF NOT EXISTS category TEXT,
  ADD COLUMN IF NOT EXISTS width_cm NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS height_cm NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS depth_cm NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_generation_mode_check'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_generation_mode_check
      CHECK (generation_mode IN ('single', 'multiview'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_requested_width_cm_check'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_requested_width_cm_check
      CHECK (requested_width_cm IS NULL OR requested_width_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_requested_height_cm_check'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_requested_height_cm_check
      CHECK (requested_height_cm IS NULL OR requested_height_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_requested_depth_cm_check'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_requested_depth_cm_check
      CHECK (requested_depth_cm IS NULL OR requested_depth_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_source_back_image_id_fkey'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_source_back_image_id_fkey
      FOREIGN KEY (source_back_image_id) REFERENCES source_images(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_source_left_image_id_fkey'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_source_left_image_id_fkey
      FOREIGN KEY (source_left_image_id) REFERENCES source_images(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'generation_jobs_source_right_image_id_fkey'
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_source_right_image_id_fkey
      FOREIGN KEY (source_right_image_id) REFERENCES source_images(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'furniture_assets_width_cm_check'
  ) THEN
    ALTER TABLE furniture_assets
      ADD CONSTRAINT furniture_assets_width_cm_check
      CHECK (width_cm IS NULL OR width_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'furniture_assets_height_cm_check'
  ) THEN
    ALTER TABLE furniture_assets
      ADD CONSTRAINT furniture_assets_height_cm_check
      CHECK (height_cm IS NULL OR height_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'furniture_assets_depth_cm_check'
  ) THEN
    ALTER TABLE furniture_assets
      ADD CONSTRAINT furniture_assets_depth_cm_check
      CHECK (depth_cm IS NULL OR depth_cm > 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_source_images_user_id
ON source_images(user_id);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_user_status
ON generation_jobs(user_id, status);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_status_queued
ON generation_jobs(status, queued_at);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_provider_status
ON generation_jobs(provider, status);

CREATE INDEX IF NOT EXISTS idx_furniture_assets_user_created
ON furniture_assets(user_id, created_at DESC);

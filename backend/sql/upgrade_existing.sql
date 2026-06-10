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

CREATE TABLE IF NOT EXISTS generation_job_source_images (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  generation_job_id UUID NOT NULL REFERENCES generation_jobs(id) ON DELETE CASCADE,
  source_image_id UUID NOT NULL REFERENCES source_images(id) ON DELETE CASCADE,
  view_label TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_primary BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(generation_job_id, source_image_id, view_label)
);

CREATE TABLE IF NOT EXISTS source_image_preprocess_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_image_id UUID NOT NULL REFERENCES source_images(id) ON DELETE CASCADE,
  generation_job_id UUID REFERENCES generation_jobs(id) ON DELETE CASCADE,

  view_label TEXT NOT NULL DEFAULT 'front',
  preprocess_version INTEGER NOT NULL DEFAULT 1,

  original_s3_bucket TEXT NOT NULL,
  original_s3_key TEXT NOT NULL,
  processed_s3_bucket TEXT NOT NULL,
  processed_s3_key TEXT NOT NULL,

  original_mean_r NUMERIC(6,5),
  original_mean_g NUMERIC(6,5),
  original_mean_b NUMERIC(6,5),
  original_luminance_mean NUMERIC(6,5),
  original_saturation_mean NUMERIC(6,5),

  processed_mean_r NUMERIC(6,5),
  processed_mean_g NUMERIC(6,5),
  processed_mean_b NUMERIC(6,5),
  processed_luminance_mean NUMERIC(6,5),
  processed_saturation_mean NUMERIC(6,5),

  target_luminance NUMERIC(6,5) NOT NULL DEFAULT 0.58,
  exposure_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  gamma NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  saturation_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  contrast_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  red_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  green_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  blue_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,

  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  UNIQUE(generation_job_id, source_image_id, view_label),

  CHECK (preprocess_version > 0),
  CHECK (target_luminance > 0 AND target_luminance <= 1),
  CHECK (exposure_gain > 0),
  CHECK (gamma > 0),
  CHECK (saturation_gain > 0),
  CHECK (contrast_gain > 0),
  CHECK (red_gain > 0),
  CHECK (green_gain > 0),
  CHECK (blue_gain > 0),
  CHECK (original_mean_r IS NULL OR (original_mean_r >= 0 AND original_mean_r <= 1)),
  CHECK (original_mean_g IS NULL OR (original_mean_g >= 0 AND original_mean_g <= 1)),
  CHECK (original_mean_b IS NULL OR (original_mean_b >= 0 AND original_mean_b <= 1)),
  CHECK (original_luminance_mean IS NULL OR (original_luminance_mean >= 0 AND original_luminance_mean <= 1)),
  CHECK (original_saturation_mean IS NULL OR (original_saturation_mean >= 0 AND original_saturation_mean <= 1)),
  CHECK (processed_mean_r IS NULL OR (processed_mean_r >= 0 AND processed_mean_r <= 1)),
  CHECK (processed_mean_g IS NULL OR (processed_mean_g >= 0 AND processed_mean_g <= 1)),
  CHECK (processed_mean_b IS NULL OR (processed_mean_b >= 0 AND processed_mean_b <= 1)),
  CHECK (processed_luminance_mean IS NULL OR (processed_luminance_mean >= 0 AND processed_luminance_mean <= 1)),
  CHECK (processed_saturation_mean IS NULL OR (processed_saturation_mean >= 0 AND processed_saturation_mean <= 1))
);

CREATE TABLE IF NOT EXISTS asset_render_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id UUID UNIQUE NOT NULL REFERENCES furniture_assets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_profile_id UUID REFERENCES source_image_preprocess_profiles(id) ON DELETE SET NULL,

  profile_version INTEGER NOT NULL DEFAULT 1,
  source TEXT NOT NULL DEFAULT 'fallback'
    CHECK (source IN ('model_texture', 'source_image', 'material_factor', 'fallback')),

  albedo_mean_r NUMERIC(6,5),
  albedo_mean_g NUMERIC(6,5),
  albedo_mean_b NUMERIC(6,5),
  texture_luminance_mean NUMERIC(6,5),
  texture_saturation_mean NUMERIC(6,5),
  roughness_mean NUMERIC(6,5),
  metallic_mean NUMERIC(6,5),

  source_original_mean_r NUMERIC(6,5),
  source_original_mean_g NUMERIC(6,5),
  source_original_mean_b NUMERIC(6,5),
  source_original_luminance_mean NUMERIC(6,5),
  source_original_saturation_mean NUMERIC(6,5),
  source_processed_mean_r NUMERIC(6,5),
  source_processed_mean_g NUMERIC(6,5),
  source_processed_mean_b NUMERIC(6,5),
  source_processed_luminance_mean NUMERIC(6,5),
  source_processed_saturation_mean NUMERIC(6,5),

  preprocess_target_luminance NUMERIC(6,5),
  preprocess_exposure_gain NUMERIC(6,3),
  preprocess_gamma NUMERIC(6,3),
  preprocess_saturation_gain NUMERIC(6,3),
  preprocess_contrast_gain NUMERIC(6,3),
  preprocess_red_gain NUMERIC(6,3),
  preprocess_green_gain NUMERIC(6,3),
  preprocess_blue_gain NUMERIC(6,3),

  suggested_exposure_gain NUMERIC(6,3) NOT NULL DEFAULT 1.0,
  suggested_emissive_lift NUMERIC(6,3) NOT NULL DEFAULT 0.0,

  has_embedded_textures BOOLEAN NOT NULL DEFAULT false,
  has_external_textures BOOLEAN NOT NULL DEFAULT false,
  has_normal_map BOOLEAN NOT NULL DEFAULT false,
  has_occlusion_map BOOLEAN NOT NULL DEFAULT false,
  has_emissive BOOLEAN NOT NULL DEFAULT false,

  material_count INTEGER NOT NULL DEFAULT 0,
  texture_count INTEGER NOT NULL DEFAULT 0,
  notes TEXT,

  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  CHECK (profile_version > 0),
  CHECK (albedo_mean_r IS NULL OR (albedo_mean_r >= 0 AND albedo_mean_r <= 1)),
  CHECK (albedo_mean_g IS NULL OR (albedo_mean_g >= 0 AND albedo_mean_g <= 1)),
  CHECK (albedo_mean_b IS NULL OR (albedo_mean_b >= 0 AND albedo_mean_b <= 1)),
  CHECK (texture_luminance_mean IS NULL OR (texture_luminance_mean >= 0 AND texture_luminance_mean <= 1)),
  CHECK (texture_saturation_mean IS NULL OR (texture_saturation_mean >= 0 AND texture_saturation_mean <= 1)),
  CHECK (roughness_mean IS NULL OR (roughness_mean >= 0 AND roughness_mean <= 1)),
  CHECK (metallic_mean IS NULL OR (metallic_mean >= 0 AND metallic_mean <= 1)),
  CHECK (suggested_exposure_gain > 0),
  CHECK (suggested_emissive_lift >= 0),
  CHECK (material_count >= 0),
  CHECK (texture_count >= 0)
);

ALTER TABLE asset_render_profiles
  ADD COLUMN IF NOT EXISTS source_profile_id UUID REFERENCES source_image_preprocess_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_original_mean_r NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_original_mean_g NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_original_mean_b NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_original_luminance_mean NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_original_saturation_mean NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_processed_mean_r NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_processed_mean_g NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_processed_mean_b NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_processed_luminance_mean NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS source_processed_saturation_mean NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS preprocess_target_luminance NUMERIC(6,5),
  ADD COLUMN IF NOT EXISTS preprocess_exposure_gain NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS preprocess_gamma NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS preprocess_saturation_gain NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS preprocess_contrast_gain NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS preprocess_red_gain NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS preprocess_green_gain NUMERIC(6,3),
  ADD COLUMN IF NOT EXISTS preprocess_blue_gain NUMERIC(6,3);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_generation_mode_check'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_generation_mode_check
      CHECK (generation_mode IN ('single', 'multiview'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_requested_width_cm_check'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_requested_width_cm_check
      CHECK (requested_width_cm IS NULL OR requested_width_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_requested_height_cm_check'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_requested_height_cm_check
      CHECK (requested_height_cm IS NULL OR requested_height_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_requested_depth_cm_check'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_requested_depth_cm_check
      CHECK (requested_depth_cm IS NULL OR requested_depth_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_source_back_image_id_fkey'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_source_back_image_id_fkey
      FOREIGN KEY (source_back_image_id) REFERENCES source_images(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_source_left_image_id_fkey'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_source_left_image_id_fkey
      FOREIGN KEY (source_left_image_id) REFERENCES source_images(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'generation_jobs_source_right_image_id_fkey'
      AND conrelid = 'generation_jobs'::regclass
  ) THEN
    ALTER TABLE generation_jobs
      ADD CONSTRAINT generation_jobs_source_right_image_id_fkey
      FOREIGN KEY (source_right_image_id) REFERENCES source_images(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'furniture_assets_width_cm_check'
      AND conrelid = 'furniture_assets'::regclass
  ) THEN
    ALTER TABLE furniture_assets
      ADD CONSTRAINT furniture_assets_width_cm_check
      CHECK (width_cm IS NULL OR width_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'furniture_assets_height_cm_check'
      AND conrelid = 'furniture_assets'::regclass
  ) THEN
    ALTER TABLE furniture_assets
      ADD CONSTRAINT furniture_assets_height_cm_check
      CHECK (height_cm IS NULL OR height_cm > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'furniture_assets_depth_cm_check'
      AND conrelid = 'furniture_assets'::regclass
  ) THEN
    ALTER TABLE furniture_assets
      ADD CONSTRAINT furniture_assets_depth_cm_check
      CHECK (depth_cm IS NULL OR depth_cm > 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_source_images_user_id
ON source_images(user_id);

CREATE INDEX IF NOT EXISTS idx_source_image_preprocess_profiles_source
ON source_image_preprocess_profiles(source_image_id);

CREATE INDEX IF NOT EXISTS idx_source_image_preprocess_profiles_job
ON source_image_preprocess_profiles(generation_job_id);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_user_status
ON generation_jobs(user_id, status);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_user_queued_at
ON generation_jobs(user_id, queued_at DESC);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_status_queued
ON generation_jobs(status, queued_at);

CREATE INDEX IF NOT EXISTS idx_generation_jobs_provider_status
ON generation_jobs(provider, status);

CREATE INDEX IF NOT EXISTS idx_generation_job_source_images_job_order
ON generation_job_source_images(generation_job_id, sort_order);

CREATE INDEX IF NOT EXISTS idx_generation_job_source_images_source_image
ON generation_job_source_images(source_image_id);

CREATE INDEX IF NOT EXISTS idx_furniture_assets_user_created
ON furniture_assets(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_asset_render_profiles_user_id
ON asset_render_profiles(user_id);

-- Externally-discovered image candidates for a Landmark. Deliberately
-- minimal: this records "an external source suggests this image may
-- depict this Landmark," not "this image is approved for use in the
-- game." No uploader/approval/perceptual-hash/gallery fields yet --
-- those belong to a player-submission system that doesn't exist until
-- there's an actual app with accounts and uploads to feed it.
create table landmark_image_candidates (
  id uuid primary key default gen_random_uuid(),
  landmark_id uuid not null references landmarks (id) on delete cascade,
  source_type text not null check (source_type in (
    'osm_image', 'wikimedia_commons', 'wikidata', 'wikipedia', 'official_website'
  )),
  source_url text not null,
  thumbnail_url text,
  source_page_url text,
  attribution_text text,
  license text,
  evidence jsonb,
  discovered_at timestamptz not null default now()
);
create index landmark_image_candidates_landmark_idx on landmark_image_candidates (landmark_id);

alter table landmark_image_candidates enable row level security;
-- No client-facing policy yet -- same as the other pre-review tables,
-- reached only via the service role until there's a reason to expose it.

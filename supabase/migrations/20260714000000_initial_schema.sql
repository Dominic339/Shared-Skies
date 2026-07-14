-- Shared Skies — Initial Database Schema
-- Target: Supabase (Postgres 15+, postgis + pgcrypto extensions)
--
-- ============================================================================
-- CONVENTIONS
-- ============================================================================
--
-- 1. STABLE IDS. Every table's primary key is a `uuid` (`id`), generated
--    server-side, never reused, never exposed as guessable sequence. All
--    foreign keys point at these. Nothing ever joins on a display name —
--    names and descriptions change, ids don't.
--
-- 2. HUMAN-READABLE CODES. Tables referenced by humans (moderation, bug
--    reports, spreadsheets, support) also carry a short public `code` such
--    as `LM000493` for a Landmark. This is a *generated* column built from a
--    per-table `bigserial`, so it costs nothing to maintain and is
--    guaranteed unique.
--
-- 3. TEXT + CHECK, NOT ENUM TYPES. Lifecycle/category fields use `text`
--    with a `check` constraint rather than a Postgres `enum` type. Enum
--    types are awkward to extend safely over a multi-year live service
--    (renaming/removing a value is a real migration); a checked text column
--    can be loosened with a plain `alter table ... drop/add constraint`.
--
-- 4. SOFT DELETION. Nothing important is ever hard-deleted. Content tables
--    carry `archived_at timestamptz`; application code filters
--    `where archived_at is null` by default, and history stays queryable.
--
-- 5. DATA-DRIVEN CONTENT. One model asset (e.g. `tulip.glb`) is shared by
--    many catalog entries that differ only by parameters (color, material,
--    scale) instead of by duplicated model files. See `model_assets`,
--    `item_definitions`, `item_variants`.
--
-- 6. CONTENT PACKS. Any piece of shippable content (an item definition, a
--    landmark seed, a spawn rule, an achievement) can be tagged to a
--    `content_packs` row via the polymorphic `pack_contents` table, so a
--    "New England Wildflowers Pack" is a label applied across tables, not a
--    new subsystem to build.
--
-- 7. SOURCE CONFIDENCE vs. COMMUNITY VERIFICATION. A Landmark's *existence*
--    (sourced from OpenStreetMap, a state parks dataset, or a player
--    submission) is tracked separately from whether the *community* has
--    confirmed it's currently accessible, accurate, and worth a visit. A
--    landmark can be high source-confidence and zero community-verified on
--    day one (a freshly imported OSM park) — that's the expected state for
--    almost everything at launch, not an error state.
--
-- 8. MODERATION IS ITS OWN LAYER, NOT A BLOCKER. The tables in the
--    administration section exist so every approve/reject/merge decision
--    has an audit trail from day one, even while the *interface* for that
--    work is still just Supabase Studio and small scripts. A custom review
--    UI can be built later against this same schema with no migration.
--
-- 9. ROW LEVEL SECURITY. Every table has RLS enabled. Public content tables
--    get a simple "published, non-archived rows are readable by anyone"
--    policy. Player-owned tables restrict access to `auth.uid()`. The
--    administration/moderation tables intentionally have NO client-facing
--    policies at launch — they're reached only via the service role key
--    from admin tooling/Edge Functions, which bypasses RLS. This is a
--    starting baseline, not an exhaustive security audit.
--
-- ============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists postgis;    -- geography(Point, 4326)

-- Generic "touch updated_at on every update" trigger, reused everywhere.
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- LAYER 0 — REFERENCE / CROSS-CUTTING TABLES
-- ============================================================================

create table content_packs (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('PK' || lpad(seq::text, 5, '0')) stored,
  name text not null,
  description text,
  category text not null check (category in (
    'structures', 'souvenirs', 'flowers', 'tokens', 'decorations',
    'stationery', 'landmarks', 'waymarks', 'seasonal', 'other'
  )),
  release_date date,
  publication_state text not null default 'draft'
    check (publication_state in ('draft', 'pending_review', 'published', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index content_packs_code_idx on content_packs (code);
create trigger trg_content_packs_updated_at before update on content_packs
  for each row execute function set_updated_at();

comment on table content_packs is
  'A shippable bundle of content (e.g. "New England Wildflowers Pack"). '
  'Individual rows in other tables are tagged to a pack via pack_contents; '
  'a pack itself carries no game logic, only grouping + release metadata.';

-- Polymorphic join: which rows (in whatever table) belong to which pack.
-- Trade-off: no DB-level FK integrity into the target table, by necessity
-- of being polymorphic. Application/import scripts are responsible for not
-- pointing entity_id at a row that doesn't exist. Kept deliberately simple
-- rather than introducing per-entity-type join tables for every content type.
create table pack_contents (
  id uuid primary key default gen_random_uuid(),
  pack_id uuid not null references content_packs (id) on delete cascade,
  entity_table text not null,
  entity_id uuid not null,
  created_at timestamptz not null default now(),
  unique (pack_id, entity_table, entity_id)
);
create index pack_contents_entity_idx on pack_contents (entity_table, entity_id);

create table regions (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('RG' || lpad(seq::text, 4, '0')) stored,
  iso_code text not null unique, -- e.g. 'US-MA'
  name text not null,            -- e.g. 'Massachusetts'
  short_name text,               -- e.g. 'The Bay State'
  country_code text not null default 'US',
  launch_status text not null default 'planned'
    check (launch_status in ('planned', 'seeded', 'active')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index regions_code_idx on regions (code);
create trigger trg_regions_updated_at before update on regions
  for each row execute function set_updated_at();

-- Global on/off switches so a system (e.g. free-text mail) can ship its
-- schema and UI hooks without being enabled for players yet. Flip a row,
-- not a deploy.
create table feature_flags (
  key text primary key,
  enabled boolean not null default false,
  description text,
  updated_at timestamptz not null default now()
);
create trigger trg_feature_flags_updated_at before update on feature_flags
  for each row execute function set_updated_at();

-- One row per reusable 3D/2D asset. Many catalog entries (item_definitions,
-- waymark designs, landmark structures) point at the same model_asset and
-- differentiate only through item_variants / their own parameter fields.
create table model_assets (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('MA' || lpad(seq::text, 6, '0')) stored,
  name text not null,
  asset_category text not null check (asset_category in (
    'structure', 'collectible', 'decoration', 'token', 'coin', 'stationery', 'other'
  )),
  storage_path text not null, -- e.g. path/key in asset bundle or storage bucket
  poly_budget int,
  pack_id uuid references content_packs (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index model_assets_code_idx on model_assets (code);
create trigger trg_model_assets_updated_at before update on model_assets
  for each row execute function set_updated_at();

-- ============================================================================
-- LAYER 1 — CORE WORLD DATA
-- ============================================================================

create table communities (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('CM' || lpad(seq::text, 6, '0')) stored,
  region_id uuid not null references regions (id) on delete restrict,
  name text not null,
  description text,
  center_point geography(Point, 4326) not null,
  stamp_asset_id uuid references model_assets (id) on delete set null,
  publication_state text not null default 'draft'
    check (publication_state in ('draft', 'pending_review', 'published', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index communities_code_idx on communities (code);
create index communities_center_point_idx on communities using gist (center_point);
create index communities_region_idx on communities (region_id);
create trigger trg_communities_updated_at before update on communities
  for each row execute function set_updated_at();

-- Community Centers share one layout in v1.0, but each Community still
-- unlocks its own services/areas over time (Museum Gallery, Botanical
-- Garden, Seasonal Displays, ...). A generic key/value unlock table avoids
-- hardcoding the list of possible services in the schema.
create table community_service_unlocks (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities (id) on delete cascade,
  service_key text not null, -- e.g. 'museum_gallery', 'botanical_garden'
  unlocked_at timestamptz not null default now(),
  unique (community_id, service_key)
);

create table landmarks (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('LM' || lpad(seq::text, 6, '0')) stored,
  community_id uuid not null references communities (id) on delete restrict,
  name text not null,
  description text,
  category text not null check (category in (
    'park', 'trail', 'museum', 'historic_site', 'garden', 'overlook',
    'beach', 'business', 'memorial', 'covered_bridge', 'other'
  )),
  location geography(Point, 4326) not null,

  -- Lifecycle: where this landmark is in the pipeline from "someone
  -- suggested this exists" to "fully live in the game".
  lifecycle_state text not null default 'candidate' check (lifecycle_state in (
    'candidate',   -- freshly submitted or imported, not yet reviewed at all
    'rumor',       -- visible to players as an unverified Rumor
    'seeded',      -- imported (e.g. OSM) and published without needing community verification
    'published',   -- fully live, official Landmark
    'duplicate',   -- resolved as a duplicate of another landmark
    'rejected',    -- reviewed and declined
    'archived'     -- was published, no longer active (e.g. permanently closed)
  )),

  -- Source confidence: how much we trust that this place *exists* and the
  -- imported facts about it, independent of community activity.
  source_confidence text not null default 'unverified' check (source_confidence in (
    'unverified', 'low', 'medium', 'high'
  )),

  -- Community verification: independent of source confidence. Only
  -- meaningful for player-submitted candidates (`landmark_sources.source_type
  -- = 'player_submission'`); imported records can be `not_required` and go
  -- straight to 'seeded'/'published'.
  community_verification_status text not null default 'not_required' check (
    community_verification_status in ('not_required', 'pending', 'verified')
  ),
  required_verifications smallint not null default 5,

  profile_card_slot_count smallint not null default 3,
  publication_state text not null default 'draft'
    check (publication_state in ('draft', 'pending_review', 'published', 'archived')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index landmarks_code_idx on landmarks (code);
create index landmarks_location_idx on landmarks using gist (location);
create index landmarks_community_idx on landmarks (community_id);
create index landmarks_lifecycle_idx on landmarks (lifecycle_state);
create trigger trg_landmarks_updated_at before update on landmarks
  for each row execute function set_updated_at();

comment on column landmarks.source_confidence is
  'Confidence that the place exists and its imported facts are accurate — '
  'independent of community_verification_status. An OSM-imported park can '
  'be source_confidence=high, community_verification_status=not_required, '
  'lifecycle_state=seeded on day one with zero player visits.';

-- Append-only provenance log. A landmark can accumulate more than one
-- source record over time (originally OSM, later cross-matched against a
-- state parks dataset, later a player submission for a nearby trailhead).
create table landmark_sources (
  id uuid primary key default gen_random_uuid(),
  landmark_id uuid not null references landmarks (id) on delete cascade,
  source_type text not null check (source_type in (
    'osm_import', 'government_dataset', 'wikipedia_match', 'player_submission'
  )),
  external_ref text,       -- e.g. OSM node/way id
  raw_payload jsonb,       -- original imported tags/fields, kept for audit/debug
  submitted_by uuid,       -- references profiles(id); nullable for automated imports
  imported_at timestamptz not null default now()
);
create index landmark_sources_landmark_idx on landmark_sources (landmark_id);

-- Community verification events counting toward
-- landmarks.required_verifications. Only relevant for player-submitted
-- candidates; imported/seeded landmarks don't need these to publish.
create table verifications (
  id uuid primary key default gen_random_uuid(),
  landmark_id uuid not null references landmarks (id) on delete cascade,
  wayfinder_id uuid not null, -- references profiles(id)
  verification_type text not null check (verification_type in (
    'exists', 'accessible', 'accurate', 'photo_evidence'
  )),
  photo_url text,
  notes text,
  created_at timestamptz not null default now(),
  unique (landmark_id, wayfinder_id, verification_type)
);
create index verifications_landmark_idx on verifications (landmark_id);

comment on table verifications is
  'One row per (landmark, wayfinder, verification_type). Distinct wayfinder '
  'count on a landmark is compared against landmarks.required_verifications '
  'to decide when a candidate/rumor flips to published.';

-- Where/how often a given item can spawn. Rules ship alongside content
-- packs (a "Wildflowers Pack" brings its own spawn rules) and can target a
-- region, a landmark category, or be global.
create table spawn_rules (
  id uuid primary key default gen_random_uuid(),
  item_definition_id uuid not null, -- references item_definitions(id), declared below via alter table
  region_id uuid references regions (id) on delete cascade,
  landmark_category text,
  weight numeric not null default 1.0,
  rarity_tier text not null default 'common'
    check (rarity_tier in ('common', 'uncommon', 'rare', 'historic')),
  pack_id uuid references content_packs (id) on delete set null,
  created_at timestamptz not null default now()
);

-- ============================================================================
-- LAYER 1b — DATA-DRIVEN ITEM CATALOG
-- ============================================================================

-- One row per *kind* of collectible/decoration/token — a Souvenir, a house
-- Decoration, a player Token, a piece of Stationery, a Profile Card frame.
-- Distinguished by `category`, not by separate tables, so the catalog stays
-- one place to search/filter/bulk-import regardless of kind.
create table item_definitions (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('IT' || lpad(seq::text, 6, '0')) stored,
  category text not null check (category in (
    'souvenir', 'decoration', 'token', 'stationery', 'card_frame', 'atlas_cover'
  )),
  name text not null,
  description text,
  model_asset_id uuid references model_assets (id) on delete restrict,
  theme_tags text[] not null default '{}', -- e.g. '{coastal, botanical}'
  rarity_tier text not null default 'common'
    check (rarity_tier in ('common', 'uncommon', 'rare', 'historic')),
  pack_id uuid references content_packs (id) on delete set null,
  publication_state text not null default 'draft'
    check (publication_state in ('draft', 'pending_review', 'published', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index item_definitions_code_idx on item_definitions (code);
create index item_definitions_category_idx on item_definitions (category);
create index item_definitions_pack_idx on item_definitions (pack_id);
create trigger trg_item_definitions_updated_at before update on item_definitions
  for each row execute function set_updated_at();

comment on table item_definitions is
  'e.g. "Tulip" as one row with model_asset_id -> tulip.glb. Color/size/etc. '
  'variation lives in item_variants, not in duplicated rows or files.';

-- e.g. Tulip (Red), Tulip (Purple) — same model_asset, different parameters.
create table item_variants (
  id uuid primary key default gen_random_uuid(),
  item_definition_id uuid not null references item_definitions (id) on delete cascade,
  variant_key text not null,   -- e.g. 'color'
  variant_value text not null, -- e.g. 'red'
  display_suffix text,         -- e.g. 'Red Tulip' override, optional
  material_params jsonb not null default '{}', -- shader/material overrides
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  unique (item_definition_id, variant_key, variant_value)
);

alter table spawn_rules
  add constraint spawn_rules_item_definition_fk
  foreign key (item_definition_id) references item_definitions (id) on delete cascade;
create index spawn_rules_item_idx on spawn_rules (item_definition_id);
create index spawn_rules_region_idx on spawn_rules (region_id);

-- The annual/regional coin catalog (not per-player — this is the design
-- library; who owns which design lives in waymark_collection below).
create table waymark_designs (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('WM' || lpad(seq::text, 6, '0')) stored,
  title text not null,
  year smallint, -- null for location commemoratives, which don't display a year
  region_id uuid references regions (id) on delete restrict,
  design_kind text not null check (design_kind in (
    'annual_regional', 'historic', 'location_commemorative', 'special_event'
  )),
  landmark_id uuid references landmarks (id) on delete set null, -- location commemoratives only
  obverse_asset_id uuid references model_assets (id) on delete restrict,
  reverse_asset_id uuid references model_assets (id) on delete restrict,
  is_spendable boolean not null default true, -- false for historic/location commemoratives
  pack_id uuid references content_packs (id) on delete set null,
  publication_state text not null default 'draft'
    check (publication_state in ('draft', 'pending_review', 'published', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index waymark_designs_code_idx on waymark_designs (code);
create trigger trg_waymark_designs_updated_at before update on waymark_designs
  for each row execute function set_updated_at();

-- ============================================================================
-- LAYER 2 — PLAYER & COLLECTION DATA
-- ============================================================================

create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  home_community_id uuid references communities (id) on delete set null,
  role text not null default 'wayfinder' check (role in ('wayfinder', 'moderator', 'admin')),
  card_frame_item_id uuid references item_definitions (id) on delete set null,
  bio_text text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_profiles_updated_at before update on profiles
  for each row execute function set_updated_at();

-- Now that profiles exists, backfill the FKs that earlier tables left as
-- bare uuid columns (Postgres table order requires profiles to exist first
-- for a real FK; those tables were written before profiles for readability).
alter table landmark_sources
  add constraint landmark_sources_submitted_by_fk
  foreign key (submitted_by) references profiles (id) on delete set null;
alter table verifications
  add constraint verifications_wayfinder_fk
  foreign key (wayfinder_id) references profiles (id) on delete cascade;

create table visits (
  id uuid primary key default gen_random_uuid(),
  wayfinder_id uuid not null references profiles (id) on delete cascade,
  landmark_id uuid not null references landmarks (id) on delete cascade,
  visited_at timestamptz not null default now(),
  is_first_visit boolean not null default false
);
create index visits_wayfinder_idx on visits (wayfinder_id, visited_at);
create index visits_landmark_idx on visits (landmark_id);
-- Enforce "first visit" uniqueness at the app layer (insert is_first_visit=true
-- only when no prior row exists for that wayfinder+landmark); left as a plain
-- index rather than a partial-unique constraint to keep repeat-visit inserts simple.

-- Physical inventory: souvenirs, decorations, tokens a wayfinder owns,
-- has donated, or has otherwise let go of. Postcards are modeled separately
-- (see below) because their data shape (season/weather/time-of-day/mailing)
-- is meaningfully different from a generic collectible.
create table item_instances (
  id uuid primary key default gen_random_uuid(),
  owner_wayfinder_id uuid not null references profiles (id) on delete cascade,
  item_definition_id uuid not null references item_definitions (id) on delete restrict,
  variant_id uuid references item_variants (id) on delete restrict,
  acquired_at timestamptz not null default now(),
  acquired_landmark_id uuid references landmarks (id) on delete set null,
  discovered_via text not null default 'landmark_slot' check (discovered_via in (
    'landmark_slot', 'museum_event', 'starter_kit', 'purchase'
  )),
  status text not null default 'owned' check (status in ('owned', 'donated', 'consumed')),
  donated_to_community_id uuid references communities (id) on delete set null,
  donated_at timestamptz
);
create index item_instances_owner_idx on item_instances (owner_wayfinder_id, status);
create index item_instances_definition_idx on item_instances (item_definition_id);

create table postcards (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('PC' || lpad(seq::text, 7, '0')) stored,
  holder_wayfinder_id uuid references profiles (id) on delete set null, -- null once fully given away
  landmark_id uuid not null references landmarks (id) on delete restrict,
  community_id uuid not null references communities (id) on delete restrict,
  season text not null check (season in ('spring', 'summer', 'autumn', 'winter')),
  weather text not null check (weather in ('clear', 'rain', 'snow', 'fog', 'overcast')),
  time_of_day text not null check (time_of_day in ('dawn', 'day', 'dusk', 'night')),
  artwork_render_url text,
  collected_at timestamptz not null default now(),
  status text not null default 'held' check (status in ('held', 'mailed', 'archived'))
);
create unique index postcards_code_idx on postcards (code);
create index postcards_holder_idx on postcards (holder_wayfinder_id);
create index postcards_landmark_idx on postcards (landmark_id);

create table postcard_mailings (
  id uuid primary key default gen_random_uuid(),
  postcard_id uuid not null references postcards (id) on delete cascade,
  sender_id uuid not null references profiles (id) on delete cascade,
  recipient_id uuid not null references profiles (id) on delete cascade,
  stationery_item_id uuid references item_definitions (id) on delete set null,
  message_kind text not null check (message_kind in ('canned', 'freetext')),
  canned_message_key text, -- e.g. 'greetings_from', 'check_out'
  message_text text,       -- only populated when message_kind = 'freetext'
  mailed_at timestamptz not null default now(),
  delivered_at timestamptz
);
create index postcard_mailings_recipient_idx on postcard_mailings (recipient_id, delivered_at);

comment on table postcard_mailings is
  'message_kind is gated by feature_flags["mail.freetext_enabled"] at the '
  'application layer — the schema supports free-text letters from day one; '
  'whether the client allows composing one is a flag flip, not a migration.';

create table waymark_balances (
  wayfinder_id uuid primary key references profiles (id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);
create trigger trg_waymark_balances_updated_at before update on waymark_balances
  for each row execute function set_updated_at();

create table waymark_transactions (
  id uuid primary key default gen_random_uuid(),
  wayfinder_id uuid not null references profiles (id) on delete cascade,
  amount bigint not null, -- positive = earned, negative = spent
  reason text not null,   -- e.g. 'landmark_visit_reward', 'stationery_purchase'
  related_table text,
  related_id uuid,
  created_at timestamptz not null default now()
);
create index waymark_transactions_wayfinder_idx on waymark_transactions (wayfinder_id, created_at);

-- Permanent record of every distinct design a wayfinder has ever earned.
-- Independent of waymark_balances/waymark_transactions: spending currency
-- never removes a row here.
create table waymark_collection (
  id uuid primary key default gen_random_uuid(),
  wayfinder_id uuid not null references profiles (id) on delete cascade,
  waymark_design_id uuid not null references waymark_designs (id) on delete restrict,
  first_obtained_at timestamptz not null default now(),
  discovery_landmark_id uuid references landmarks (id) on delete set null, -- historic waymarks only
  unique (wayfinder_id, waymark_design_id)
);

create table stamp_collection (
  id uuid primary key default gen_random_uuid(),
  wayfinder_id uuid not null references profiles (id) on delete cascade,
  community_id uuid not null references communities (id) on delete cascade,
  collected_at timestamptz not null default now(),
  unique (wayfinder_id, community_id)
);

-- A wayfinder's own leave-behind card slots at landmarks.
create table profile_card_slots (
  id uuid primary key default gen_random_uuid(),
  landmark_id uuid not null references landmarks (id) on delete cascade,
  slot_index smallint not null,
  unlocked_at timestamptz not null default now(),
  unique (landmark_id, slot_index)
);
create index profile_card_slots_landmark_idx on profile_card_slots (landmark_id);

-- An instance of a wayfinder's card placed into a specific slot, with the
-- "exactly 3 copies" countdown.
create table profile_card_placements (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references profile_card_slots (id) on delete cascade,
  placed_by uuid not null references profiles (id) on delete cascade,
  remaining_copies smallint not null default 3 check (remaining_copies >= 0),
  placed_at timestamptz not null default now(),
  removed_at timestamptz -- set once remaining_copies hits 0, slot becomes free again
);
create unique index profile_card_placements_active_slot_idx
  on profile_card_placements (slot_id) where removed_at is null;

create table profile_card_collections (
  id uuid primary key default gen_random_uuid(),
  placement_id uuid not null references profile_card_placements (id) on delete cascade,
  collected_by uuid not null references profiles (id) on delete cascade,
  collected_at timestamptz not null default now(),
  unique (placement_id, collected_by)
);

-- ============================================================================
-- LAYER 3 — SHARED COMMUNITY STATE
-- ============================================================================

-- One slot per (community, item_definition) — "every Museum accepts exactly
-- one copy of each souvenir". Also used for Botanical Garden plots by
-- filtering item_definitions.category = 'decoration' with a garden theme
-- tag, rather than building a second parallel table for the garden.
create table museum_exhibit_slots (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities (id) on delete cascade,
  item_definition_id uuid not null references item_definitions (id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  unique (community_id, item_definition_id)
);

create table museum_donations (
  id uuid primary key default gen_random_uuid(),
  exhibit_slot_id uuid not null references museum_exhibit_slots (id) on delete cascade,
  donor_wayfinder_id uuid not null references profiles (id) on delete restrict,
  item_instance_id uuid not null references item_instances (id) on delete restrict,
  donated_at timestamptz not null default now(),
  unique (exhibit_slot_id) -- one donation fills the slot, permanently
);

create table accessibility_reports (
  id uuid primary key default gen_random_uuid(),
  landmark_id uuid not null references landmarks (id) on delete cascade,
  reporter_wayfinder_id uuid not null references profiles (id) on delete cascade,
  category text not null check (category in (
    'wheelchair', 'paved_path', 'restroom', 'parking', 'pet_friendly',
    'family_friendly', 'seasonal_closure'
  )),
  details text,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'disputed')),
  confirmations smallint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index accessibility_reports_landmark_idx on accessibility_reports (landmark_id);
create trigger trg_accessibility_reports_updated_at before update on accessibility_reports
  for each row execute function set_updated_at();

create table community_recommendations (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities (id) on delete cascade,
  landmark_id uuid references landmarks (id) on delete cascade,
  author_wayfinder_id uuid references profiles (id) on delete set null, -- null = system/curated
  body text not null,
  status text not null default 'pending' check (status in ('pending', 'published', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index community_recommendations_community_idx on community_recommendations (community_id);
create trigger trg_community_recommendations_updated_at before update on community_recommendations
  for each row execute function set_updated_at();

-- Community-level progress (percent of exhibit slots filled, landmarks
-- published, etc.) is intentionally NOT a stored table — it's a read model
-- computed from museum_exhibit_slots/museum_donations/landmarks so it can
-- never drift out of sync. See a `community_progress` view maintained
-- alongside the application code once query patterns are known.

-- ============================================================================
-- LAYER 4 — ADMINISTRATION & MODERATION
-- ============================================================================

create table submission_tickets (
  id uuid primary key default gen_random_uuid(),
  seq bigserial not null,
  code text generated always as ('RV' || lpad(seq::text, 6, '0')) stored,
  ticket_type text not null check (ticket_type in (
    'landmark_submission', 'accessibility_report', 'recommendation',
    'duplicate_flag', 'content_report'
  )),
  subject_table text not null, -- e.g. 'landmarks'
  subject_id uuid not null,    -- polymorphic, see pack_contents note above
  submitted_by uuid references profiles (id) on delete set null,
  status text not null default 'open' check (status in (
    'open', 'in_review', 'approved', 'rejected', 'merged', 'duplicate', 'archived'
  )),
  assigned_to uuid references profiles (id) on delete set null,
  priority smallint not null default 0,
  resolution_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index submission_tickets_code_idx on submission_tickets (code);
create index submission_tickets_subject_idx on submission_tickets (subject_table, subject_id);
create index submission_tickets_status_idx on submission_tickets (status);
create trigger trg_submission_tickets_updated_at before update on submission_tickets
  for each row execute function set_updated_at();

create table submission_images (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references submission_tickets (id) on delete cascade,
  image_url text not null,
  uploaded_by uuid references profiles (id) on delete set null,
  is_primary boolean not null default false,
  uploaded_at timestamptz not null default now()
);
create index submission_images_ticket_idx on submission_images (ticket_id);

create table duplicate_candidates (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references submission_tickets (id) on delete cascade,
  candidate_landmark_id uuid not null references landmarks (id) on delete cascade,
  similarity_score numeric,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
create index duplicate_candidates_ticket_idx on duplicate_candidates (ticket_id);

create table moderation_actions (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid references submission_tickets (id) on delete set null,
  actor_id uuid references profiles (id) on delete set null,
  action text not null check (action in (
    'approve', 'reject', 'merge', 'archive', 'restore', 'duplicate', 'edit'
  )),
  target_table text not null,
  target_id uuid not null,
  notes text,
  created_at timestamptz not null default now()
);
create index moderation_actions_ticket_idx on moderation_actions (ticket_id);
create index moderation_actions_target_idx on moderation_actions (target_table, target_id);

-- Generic append-only history. Populated by triggers attached to whichever
-- tables need it (see record_audit_log() below + example attachments).
create table audit_log (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  record_id uuid not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  changed_by uuid, -- references profiles(id); no FK so history survives a deleted actor
  diff jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_record_idx on audit_log (table_name, record_id);

create or replace function record_audit_log()
returns trigger
language plpgsql
as $$
begin
  insert into audit_log (table_name, record_id, action, changed_by, diff)
  values (
    TG_TABLE_NAME,
    coalesce(new.id, old.id),
    lower(TG_OP),
    auth.uid(),
    case TG_OP
      when 'INSERT' then to_jsonb(new)
      when 'UPDATE' then jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new))
      when 'DELETE' then to_jsonb(old)
    end
  );
  return coalesce(new, old);
end;
$$;

-- Attach audit logging to the highest-stakes tables first. Add more with
-- the same one-liner as new workflows prove they need a paper trail:
--   create trigger trg_audit_<table> after insert or update or delete on <table>
--     for each row execute function record_audit_log();
create trigger trg_audit_landmarks after insert or update or delete on landmarks
  for each row execute function record_audit_log();
create trigger trg_audit_item_definitions after insert or update or delete on item_definitions
  for each row execute function record_audit_log();
create trigger trg_audit_museum_donations after insert or update or delete on museum_donations
  for each row execute function record_audit_log();
create trigger trg_audit_waymark_balances after insert or update or delete on waymark_balances
  for each row execute function record_audit_log();

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
-- Baseline policies only. Treat this as a starting point to review before
-- any of this touches production, not a finished security audit.

alter table communities enable row level security;
alter table landmarks enable row level security;
alter table item_definitions enable row level security;
alter table waymark_designs enable row level security;
alter table content_packs enable row level security;
alter table profiles enable row level security;
alter table visits enable row level security;
alter table item_instances enable row level security;
alter table postcards enable row level security;
alter table postcard_mailings enable row level security;
alter table waymark_balances enable row level security;
alter table waymark_transactions enable row level security;
alter table waymark_collection enable row level security;
alter table stamp_collection enable row level security;
alter table profile_card_slots enable row level security;
alter table profile_card_placements enable row level security;
alter table profile_card_collections enable row level security;
alter table museum_exhibit_slots enable row level security;
alter table museum_donations enable row level security;
alter table accessibility_reports enable row level security;
alter table community_recommendations enable row level security;
alter table verifications enable row level security;
-- Administration tables get RLS enabled with NO policies below, which
-- means: fully locked down for anon/authenticated clients. Only the
-- service role (used by admin tooling/Edge Functions) can touch them,
-- since the service role bypasses RLS entirely.
alter table submission_tickets enable row level security;
alter table submission_images enable row level security;
alter table duplicate_candidates enable row level security;
alter table moderation_actions enable row level security;
alter table audit_log enable row level security;
alter table landmark_sources enable row level security;

-- Public content: readable by anyone once published and not archived.
create policy communities_public_read on communities
  for select using (publication_state = 'published' and archived_at is null);
create policy landmarks_public_read on landmarks
  for select using (publication_state = 'published' and archived_at is null);
create policy item_definitions_public_read on item_definitions
  for select using (publication_state = 'published' and archived_at is null);
create policy waymark_designs_public_read on waymark_designs
  for select using (publication_state = 'published' and archived_at is null);
create policy content_packs_public_read on content_packs
  for select using (publication_state = 'published' and archived_at is null);

-- Player-owned data: a wayfinder can read/write only their own rows.
create policy profiles_self_rw on profiles
  for all using (auth.uid() = id) with check (auth.uid() = id);
create policy visits_self_rw on visits
  for all using (auth.uid() = wayfinder_id) with check (auth.uid() = wayfinder_id);
create policy item_instances_self_rw on item_instances
  for all using (auth.uid() = owner_wayfinder_id) with check (auth.uid() = owner_wayfinder_id);
create policy postcards_self_rw on postcards
  for all using (auth.uid() = holder_wayfinder_id) with check (auth.uid() = holder_wayfinder_id);
create policy postcard_mailings_participant_rw on postcard_mailings
  for all using (auth.uid() in (sender_id, recipient_id))
  with check (auth.uid() = sender_id);
create policy waymark_balances_self_read on waymark_balances
  for select using (auth.uid() = wayfinder_id);
create policy waymark_transactions_self_read on waymark_transactions
  for select using (auth.uid() = wayfinder_id);
create policy waymark_collection_self_read on waymark_collection
  for select using (auth.uid() = wayfinder_id);
create policy stamp_collection_self_read on stamp_collection
  for select using (auth.uid() = wayfinder_id);
create policy profile_card_placements_owner_rw on profile_card_placements
  for all using (auth.uid() = placed_by) with check (auth.uid() = placed_by);
create policy profile_card_collections_self_read on profile_card_collections
  for select using (auth.uid() = collected_by);

-- Shared community state: readable by anyone, writes go through
-- application logic using the service role (donations/verifications are
-- side effects of gameplay actions, not raw table writes from the client).
create policy museum_exhibit_slots_public_read on museum_exhibit_slots
  for select using (true);
create policy museum_donations_public_read on museum_donations
  for select using (true);
create policy accessibility_reports_public_read on accessibility_reports
  for select using (status != 'disputed');
create policy community_recommendations_public_read on community_recommendations
  for select using (status = 'published');
create policy verifications_public_read on verifications
  for select using (true);

-- ============================================================================
-- END OF INITIAL SCHEMA
-- ============================================================================

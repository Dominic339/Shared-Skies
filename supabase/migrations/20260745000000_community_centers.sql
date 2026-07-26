-- One active hub per Community -- the connective layer tying Board/
-- Museum/Post Office/Recommendations together behind a single physical
-- (eventually) location, instead of leaving them as scattered
-- unrelated buttons forever. location uses geography(Point, 4326),
-- matching landmarks/communities' own convention, rather than the
-- separate latitude/longitude columns floated in discussion -- staying
-- consistent with how every other located entity in this schema works.
create table community_centers (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities (id) on delete cascade,
  name text not null,
  location geography(Point, 4326) not null,
  anchor_type text not null default 'other' check (anchor_type in (
    'park', 'library', 'town_hall', 'visitor_center', 'plaza', 'other'
  )),
  anchor_name text,
  publication_state text not null default 'draft' check (publication_state in ('draft', 'published', 'archived')),
  active_from timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index community_centers_community_idx on community_centers (community_id);
create trigger trg_community_centers_updated_at before update on community_centers
  for each row execute function set_updated_at();

-- Multiple drafts can coexist per Community while candidate anchor
-- locations are being evaluated (park vs. library vs. town hall plaza,
-- during the real content pass), but only one can ever be the live,
-- active one at a time.
create unique index community_centers_active_idx on community_centers (community_id)
  where publication_state = 'published' and retired_at is null;

alter table community_centers enable row level security;
create policy community_centers_public_read on community_centers
  for select using (publication_state = 'published' and retired_at is null);
-- No write policy for anon/authenticated -- centers are seeded/managed
-- by the developer for now (real civic anchors get chosen during the
-- content pass), same as feature_flags/app_settings.

-- Seed one published placeholder center per existing published
-- Community, reusing the Community's own center_point -- explicitly a
-- placeholder location, not a reviewed real-world civic anchor. Kept
-- editable (a normal UPDATE via the SQL editor) so real anchors can
-- replace these later without touching the Community record itself.
insert into community_centers (community_id, name, location, anchor_type, anchor_name, publication_state, active_from)
select
  id,
  name || ' Community Center',
  center_point,
  'other',
  'placeholder -- needs a real civic anchor (park/library/town hall/plaza)',
  'published',
  now()
from communities
where publication_state = 'published';

-- security_invoker relies on community_centers_public_read +
-- communities_public_read -- both unconditional-on-caller policies, no
-- RLS-gap risk (same reasoning as landmarks_map_view).
create or replace view community_centers_view
  with (security_invoker = true) as
select
  cc.id,
  cc.community_id,
  c.name as community_name,
  cc.name,
  st_y(cc.location::geometry) as lat,
  st_x(cc.location::geometry) as lng,
  cc.anchor_type,
  cc.anchor_name
from community_centers cc
join communities c on c.id = cc.community_id;

grant select on community_centers_view to anon, authenticated;

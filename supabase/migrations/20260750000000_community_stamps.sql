-- Community Stamps backbone: one published stamp per Community for
-- now, collected at that Community's active Center, permanently
-- recorded per player. Schema is deliberately shaped to grow into
-- seasonal/event stamps later (nullable community_id, a starts_at/
-- ends_at availability window, stamp_type) without ever needing a
-- redesign -- but collect_stamp() below only implements the
-- Community-Center-proximity path; a future event-stamp collection
-- flow is a separate function to add later, not a schema change.
create table stamp_definitions (
  id uuid primary key default gen_random_uuid(),
  community_id uuid references communities (id) on delete cascade,
  name text not null,
  description text,
  stamp_type text not null default 'community' check (stamp_type in ('community', 'seasonal', 'event')),
  asset_reference text,
  starts_at timestamptz,
  ends_at timestamptz,
  publication_state text not null default 'draft' check (publication_state in ('draft', 'published', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index stamp_definitions_community_idx on stamp_definitions (community_id);
create trigger trg_stamp_definitions_updated_at before update on stamp_definitions
  for each row execute function set_updated_at();

alter table stamp_definitions enable row level security;
create policy stamp_definitions_public_read on stamp_definitions
  for select using (publication_state = 'published');
-- No write policy for anon/authenticated -- stamp definitions are
-- dev-managed for now, same as community_centers/app_settings.

-- Permanent per-player collection record -- a real DB constraint
-- (not just an app-level check) against ever owning the same Stamp
-- twice, same belt-and-suspenders reasoning as
-- community_recommendations_unique_active.
create table player_stamps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  stamp_definition_id uuid not null references stamp_definitions (id) on delete cascade,
  collected_at timestamptz not null default now(),
  source_type text not null default 'community_center' check (source_type in ('community_center', 'event', 'admin_grant')),
  source_community_center_id uuid references community_centers (id) on delete set null,
  unique (user_id, stamp_definition_id)
);
create index player_stamps_user_idx on player_stamps (user_id);

alter table player_stamps enable row level security;
create policy player_stamps_self_read on player_stamps
  for select using (auth.uid() = user_id);
-- No write policy for anon/authenticated either -- only collect_stamp()
-- (security definer) ever inserts here, same pattern as
-- museum_donations/item_instances.

-- Seed one published stamp per existing published Community, matching
-- the same seeding convention community_centers used -- a real name/
-- description, but asset_reference is a bare placeholder tag (no
-- dedicated stamp art exists yet, same "functional first" call already
-- made for tree.glb standing in as a collectible item).
insert into stamp_definitions (community_id, name, description, stamp_type, asset_reference, publication_state)
select
  id,
  name || ' Community Stamp',
  'A commemorative stamp for visiting ' || name || '''s Community Center.',
  'community',
  'placeholder',
  'published'
from communities
where publication_state = 'published';

insert into app_settings (key, value, description) values (
  'stamps.collection_radius_meters',
  '25',
  'Max distance (meters) a player can be from a Community Center and still collect its Stamp.'
)
on conflict (key) do nothing;

-- Requires actual proximity to the Stamp's OWN Community's active
-- Center (not just "somewhere"), auth.uid() only (never a client-
-- supplied account id), one collection ever per player per Stamp.
create function collect_stamp(p_stamp_definition_id uuid, p_lat double precision, p_lng double precision)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_stamp record;
  v_center record;
  v_radius_meters numeric;
  v_point geography;
  v_player_stamp_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to collect a Stamp';
  end if;

  select * into v_stamp from stamp_definitions
  where id = p_stamp_definition_id and publication_state = 'published';
  if v_stamp.id is null then
    raise exception 'Stamp not found or not published';
  end if;
  if v_stamp.starts_at is not null and now() < v_stamp.starts_at then
    raise exception 'this Stamp is not available yet';
  end if;
  if v_stamp.ends_at is not null and now() > v_stamp.ends_at then
    raise exception 'this Stamp is no longer available';
  end if;
  if v_stamp.community_id is null then
    raise exception 'this Stamp has no Community Center collection point yet';
  end if;

  select * into v_center from community_centers
  where community_id = v_stamp.community_id and publication_state = 'published' and retired_at is null;
  if v_center.id is null then
    raise exception 'no active Community Center for this Stamp''s Community';
  end if;

  v_point := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;

  select value::numeric into v_radius_meters from app_settings where key = 'stamps.collection_radius_meters';
  v_radius_meters := coalesce(v_radius_meters, 25);
  if st_distance(v_point, v_center.location) > v_radius_meters then
    raise exception 'you must be at the Community Center to collect this Stamp';
  end if;

  if exists (
    select 1 from player_stamps
    where user_id = v_user_id and stamp_definition_id = p_stamp_definition_id
  ) then
    raise exception 'you have already collected this Stamp';
  end if;

  insert into player_stamps (user_id, stamp_definition_id, source_type, source_community_center_id)
  values (v_user_id, p_stamp_definition_id, 'community_center', v_center.id)
  returning id into v_player_stamp_id;

  return v_player_stamp_id;
end;
$$;

revoke all on function collect_stamp(uuid, double precision, double precision) from public, anon, authenticated;
grant execute on function collect_stamp(uuid, double precision, double precision) to authenticated;

-- "Collected vs. missing" read model for the Stamp Desk screen --
-- security_invoker relies on stamp_definitions_public_read
-- (unconditional on publication_state) and player_stamps_self_read
-- (auth.uid() = user_id) -- since this view only ever needs the
-- CALLER's own collection state (left join filtered to auth.uid()),
-- there's no RLS-gap risk, same reasoning as my_donatable_items_view.
create or replace view stamp_progress_view
  with (security_invoker = true) as
select
  sd.id as stamp_definition_id,
  sd.community_id,
  c.name as community_name,
  sd.name as stamp_name,
  sd.description,
  sd.stamp_type,
  sd.asset_reference,
  ps.id as player_stamp_id,
  ps.collected_at,
  (ps.id is not null) as collected
from stamp_definitions sd
left join communities c on c.id = sd.community_id
left join player_stamps ps on ps.stamp_definition_id = sd.id and ps.user_id = auth.uid()
where sd.publication_state = 'published';

grant select on stamp_progress_view to authenticated;

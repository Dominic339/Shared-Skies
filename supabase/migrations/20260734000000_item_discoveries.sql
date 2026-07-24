-- Permanent record of "has this wayfinder ever obtained this item
-- definition, and how/where" -- independent of any individual
-- item_instance's fate (donated, consumed, gifted onward, whatever).
-- Exactly the same reasoning as postcards.original_collector_id: this
-- has to survive the physical copy's lifecycle, or a later donation/
-- consumption would silently erase history a future Atlas needs to
-- answer "have I encountered this?" reliably.
--
-- first_obtained_at/discovery_source_type are frozen at the very first
-- acquisition, by ANY means. first_personal_discovery_at/
-- source_landmark_id/source_community_id are frozen separately, the
-- first time (if ever) that acquisition happens to be a real in-person
-- Landmark discovery -- which can happen LATER than first_obtained_at
-- (e.g. gifted first, personally found afterward) without overwriting
-- the original acquisition record.
create table item_discoveries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  item_definition_id uuid not null references item_definitions (id) on delete cascade,
  first_obtained_at timestamptz not null default now(),
  first_personal_discovery_at timestamptz,
  discovery_source_type text not null check (discovery_source_type in (
    'personal', 'gift', 'purchase', 'event', 'admin'
  )),
  source_landmark_id uuid references landmarks (id) on delete set null,
  source_community_id uuid references communities (id) on delete set null,
  first_item_instance_id uuid references item_instances (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, item_definition_id)
);
create trigger trg_item_discoveries_updated_at before update on item_discoveries
  for each row execute function set_updated_at();

alter table item_discoveries enable row level security;
create policy item_discoveries_self_read on item_discoveries
  for select using (auth.uid() = user_id);
-- No write policy for anon/authenticated -- only record_item_discovery()
-- below (called internally by trusted acquisition functions, never
-- exposed directly) ever writes here.

-- Called by every legitimate acquisition path (dev_grant_item today;
-- a real Landmark drop system, museum/event rewards, gifts, and
-- purchases later) right after an item_instance is created. Not
-- security definer itself and never granted to any client role --
-- it only ever runs from within an already-elevated caller (a
-- security-definer acquisition function), inheriting that context, so
-- it doesn't need its own privilege escalation, and nothing should be
-- able to fabricate a discovery record by calling this directly.
create or replace function record_item_discovery(
  p_user_id uuid,
  p_item_definition_id uuid,
  p_source_type text,
  p_landmark_id uuid,
  p_community_id uuid,
  p_item_instance_id uuid
) returns void
language plpgsql
set search_path = public
as $$
declare
  v_existing_personal_at timestamptz;
begin
  select first_personal_discovery_at into v_existing_personal_at
  from item_discoveries
  where user_id = p_user_id and item_definition_id = p_item_definition_id;

  if not found then
    -- First time ever this wayfinder has obtained this item definition,
    -- through any source.
    insert into item_discoveries (
      user_id, item_definition_id, discovery_source_type,
      first_personal_discovery_at, source_landmark_id, source_community_id, first_item_instance_id
    ) values (
      p_user_id, p_item_definition_id, p_source_type,
      case when p_source_type = 'personal' then now() end,
      case when p_source_type = 'personal' then p_landmark_id end,
      case when p_source_type = 'personal' then p_community_id end,
      p_item_instance_id
    );
  elsif v_existing_personal_at is null and p_source_type = 'personal' then
    -- Already discovered this item some other way (gift/purchase/event/
    -- admin) but this is the first time it's been found IN PERSON --
    -- fill in the personal-discovery fields without touching
    -- first_obtained_at/discovery_source_type, which describe whenever/
    -- however it was first obtained at all, not this later event.
    update item_discoveries
    set first_personal_discovery_at = now(),
        source_landmark_id = p_landmark_id,
        source_community_id = p_community_id,
        updated_at = now()
    where user_id = p_user_id and item_definition_id = p_item_definition_id;
  end if;
  -- Otherwise: the permanent record already covers this (either already
  -- personally discovered before, or this acquisition isn't a personal
  -- one either) -- nothing to update.
end;
$$;

revoke all on function record_item_discovery(uuid, uuid, text, uuid, uuid, uuid) from public;

-- Wired into the only acquisition path that currently exists.
-- Marked 'admin' per the explicit instruction that developer grants must
-- be distinguishable from (or excluded from) real discovery history.
create or replace function dev_grant_item(p_item_definition_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_allowed boolean;
  v_instance_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated';
  end if;

  select dev_grants_enabled into v_allowed from profiles where id = v_user_id;
  if not coalesce(v_allowed, false) then
    raise exception 'this account is not allowlisted for developer item grants';
  end if;

  insert into item_instances (owner_wayfinder_id, item_definition_id, discovered_via)
  values (v_user_id, p_item_definition_id, 'dev_grant')
  returning id into v_instance_id;

  perform record_item_discovery(v_user_id, p_item_definition_id, 'admin', null, null, v_instance_id);

  return v_instance_id;
end;
$$;

-- Backfill: item_instances already granted before this migration existed
-- (the dev-granted test saplings) still need a discovery record -- one
-- row per (owner, item definition), taking the earliest instance if
-- more than one exists.
insert into item_discoveries (user_id, item_definition_id, first_obtained_at, discovery_source_type, first_item_instance_id)
select distinct on (owner_wayfinder_id, item_definition_id)
  owner_wayfinder_id,
  item_definition_id,
  acquired_at,
  case discovered_via
    when 'landmark_slot' then 'personal'
    when 'museum_event' then 'event'
    when 'starter_kit' then 'gift'
    when 'purchase' then 'purchase'
    else 'admin'
  end,
  id
from item_instances
order by owner_wayfinder_id, item_definition_id, acquired_at asc
on conflict (user_id, item_definition_id) do nothing;

-- Not built into any UI yet (the full searchable Atlas book is
-- deferred) -- exists now so nothing needs retrofitting once that
-- screen actually gets built.
create or replace view item_discoveries_view
  with (security_invoker = true) as
select
  d.id as item_definition_id,
  d.name as item_name,
  d.category,
  disc.first_obtained_at,
  disc.discovery_source_type,
  disc.first_personal_discovery_at,
  l.name as source_landmark_name,
  c.name as source_community_name
from item_discoveries disc
join item_definitions d on d.id = disc.item_definition_id
left join landmarks l on l.id = disc.source_landmark_id
left join communities c on c.id = disc.source_community_id;

grant select on item_discoveries_view to authenticated;

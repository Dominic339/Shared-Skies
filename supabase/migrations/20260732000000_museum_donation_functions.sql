-- discovered_via's check constraint didn't anticipate a dev-only grant
-- path -- adding one now for the same reason dev_grant_waymarks exists:
-- testing the donation loop shouldn't have to wait for a real
-- item-discovery/exploration-drop system. Constraint name isn't hardcoded
-- (it was never explicitly named when the table was created, so Postgres
-- auto-generated it) -- found dynamically by definition text instead of
-- guessing the generated name.
do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'item_instances'::regclass
    and pg_get_constraintdef(oid) like '%discovered_via%';

  if v_constraint_name is not null then
    execute format('alter table item_instances drop constraint %I', v_constraint_name);
  end if;
end;
$$;

alter table item_instances add constraint item_instances_discovered_via_check
  check (discovered_via in ('landmark_slot', 'museum_event', 'starter_kit', 'purchase', 'dev_grant'));

-- Proves the loop: own item -> pick a Community -> donate -> item
-- leaves inventory -> museum records it -> Community unlocks it ->
-- donor gets permanent credit. museum_exhibit_slots' own
-- unique(community_id, item_definition_id) and museum_donations' own
-- unique(exhibit_slot_id) are the real DB-level guarantees against
-- double-unlocking or double-filling a slot -- this function just adds
-- friendly rejection messages and atomicity around them.
--
-- The exhibit slot for a (Community, item definition) pair doesn't
-- exist ahead of time -- there's no curation tool yet deciding which
-- items each Community "wants" to display, so the slot comes into
-- existence at the moment of its own first donation attempt, win or
-- lose the race.
create or replace function donate_to_museum(p_item_instance_id uuid, p_community_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_item record;
  v_slot_id uuid;
  v_donation_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to donate to a museum';
  end if;

  if not exists (select 1 from communities where id = p_community_id and publication_state = 'published') then
    raise exception 'community not found or not published';
  end if;

  select * into v_item from item_instances where id = p_item_instance_id for update;
  if v_item.id is null then
    raise exception 'item not found';
  end if;
  if v_item.owner_wayfinder_id != v_user_id then
    raise exception 'you do not own this item';
  end if;
  if v_item.status != 'owned' then
    raise exception 'this item is no longer available to donate';
  end if;
  if not exists (
    select 1 from item_definitions
    where id = v_item.item_definition_id and category in ('souvenir', 'decoration', 'token')
  ) then
    raise exception 'this item is not eligible for museum donation';
  end if;

  select id into v_slot_id from museum_exhibit_slots
  where community_id = p_community_id and item_definition_id = v_item.item_definition_id;

  if v_slot_id is null then
    insert into museum_exhibit_slots (community_id, item_definition_id)
    values (p_community_id, v_item.item_definition_id)
    on conflict (community_id, item_definition_id) do nothing
    returning id into v_slot_id;

    if v_slot_id is null then
      -- Lost a race against a concurrent donation creating the same
      -- slot at the same instant -- fetch what the other transaction
      -- just committed.
      select id into v_slot_id from museum_exhibit_slots
      where community_id = p_community_id and item_definition_id = v_item.item_definition_id;
    end if;
  end if;

  -- The donation insert (not a pre-check) is the real race arbiter for
  -- "did someone else already fill this slot" -- attempted BEFORE
  -- touching item_instances, so a losing racer's item is never marked
  -- donated only to have the donation itself rejected.
  begin
    insert into museum_donations (exhibit_slot_id, donor_wayfinder_id, item_instance_id)
    values (v_slot_id, v_user_id, p_item_instance_id)
    returning id into v_donation_id;
  exception when unique_violation then
    raise exception 'this Community has already received a donation of this item';
  end;

  update item_instances
  set status = 'donated', donated_to_community_id = p_community_id, donated_at = now()
  where id = p_item_instance_id;

  return v_donation_id;
end;
$$;

grant execute on function donate_to_museum(uuid, uuid) to authenticated;

-- Dev-only, gated the same way as dev_grant_waymarks (profiles.
-- dev_grants_enabled -- a column players can't write to themselves).
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

  return v_instance_id;
end;
$$;

grant execute on function dev_grant_item(uuid) to authenticated;

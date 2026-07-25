-- 20260738 apparently rolled back as a whole script (confirmed:
-- landmarks_map_view still returned profile_card_slot_count afterward,
-- meaning even its EARLIEST statement never actually committed) --
-- almost certainly because ITS OWN landmarks_map_view redefinition hit
-- the same "cannot drop columns from view" class of error rumor_landmarks_view
-- hit later, since I forgot profile_card_slot_count (added in
-- 20260717000000, after the view's original creation) had to be
-- preserved. Redoing every fix from 20260738 here, this time verified
-- against the FULL real column history of each view. rumor_landmarks_view
-- itself is NOT touched again -- 20260739's drop+create already
-- succeeded and was confirmed empty (no genuine player submissions
-- exist yet, the import backlog is correctly excluded).

create or replace view landmarks_map_view
  with (security_invoker = true) as
select
  id,
  code,
  name,
  category,
  st_y(location::geometry) as lat,
  st_x(location::geometry) as lng,
  profile_card_slot_count
from landmarks
where lifecycle_state in ('seeded', 'published');

grant select on landmarks_map_view to anon, authenticated;

create or replace view atlas_view
  with (security_invoker = true) as
select
  l.id as landmark_id,
  l.code,
  l.name,
  l.category,
  l.community_id,
  c.name as community_name,
  v.first_visited_at,
  (v.landmark_id is not null) as visited,
  exists (select 1 from postcards p where p.landmark_id = l.id) as has_postcard
from landmarks l
join communities c on c.id = l.community_id
left join (
  select landmark_id, wayfinder_id, min(visited_at) as first_visited_at
  from visits
  group by landmark_id, wayfinder_id
) v on v.landmark_id = l.id
where l.lifecycle_state in ('seeded', 'published');

grant select on atlas_view to authenticated;

drop policy if exists landmarks_rumor_read on landmarks;
create policy landmarks_rumor_read on landmarks
  for select using (
    lifecycle_state = 'rumor'
    and exists (
      select 1 from landmark_sources s
      where s.landmark_id = landmarks.id and s.source_type = 'player_submission'
    )
  );

create or replace function submit_rumor(
  p_name text,
  p_description text,
  p_category text,
  p_lat double precision,
  p_lng double precision
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_community_id uuid;
  v_distance_meters double precision;
  v_radius_km numeric;
  v_outside_range boolean;
  v_required_confirmations integer;
  v_landmark_id uuid;
  v_point geography;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to submit a Rumor';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'a name is required';
  end if;
  if p_category not in (
    'park', 'trail', 'museum', 'historic_site', 'garden', 'overlook',
    'beach', 'business', 'memorial', 'covered_bridge', 'other'
  ) then
    raise exception 'invalid category: %', p_category;
  end if;

  v_point := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;

  select id, (center_point <-> v_point) into v_community_id, v_distance_meters
  from communities
  where publication_state = 'published'
  order by center_point <-> v_point
  limit 1;
  if v_community_id is null then
    raise exception 'no published Community to attach this Rumor to yet';
  end if;

  select value::numeric into v_radius_km from app_settings where key = 'rumors.community_assignment_radius_km';
  v_radius_km := coalesce(v_radius_km, 25);
  v_outside_range := v_distance_meters > (v_radius_km * 1000);

  select value::integer into v_required_confirmations from app_settings where key = 'rumors.required_confirmations';
  v_required_confirmations := coalesce(v_required_confirmations, 5);

  insert into landmarks (
    community_id, name, description, category, location,
    lifecycle_state, source_confidence, community_verification_status, required_verifications,
    outside_community_range
  ) values (
    v_community_id, p_name, p_description, p_category, v_point,
    'rumor', 0, 'pending', v_required_confirmations,
    v_outside_range
  ) returning id into v_landmark_id;

  insert into landmark_sources (landmark_id, source_type, submitted_by)
  values (v_landmark_id, 'player_submission', v_user_id);

  insert into submission_tickets (ticket_type, subject_table, subject_id, submitted_by, status, submitter_notes)
  values ('landmark_submission', 'landmarks', v_landmark_id, v_user_id, 'open', p_description);

  return v_landmark_id;
end;
$$;

create or replace function approve_rumor(p_ticket_id uuid, p_reviewed_by text, p_notes text default null)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_ticket record;
begin
  select * into v_ticket from submission_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception 'ticket not found';
  end if;
  if v_ticket.ticket_type != 'landmark_submission' then
    raise exception 'not a landmark submission ticket';
  end if;
  if v_ticket.status not in ('open', 'in_review') then
    raise exception 'ticket already resolved';
  end if;
  if p_reviewed_by is null or length(trim(p_reviewed_by)) = 0 then
    raise exception 'reviewed_by is required';
  end if;

  update landmarks set lifecycle_state = 'published' where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'approved', resolution_notes = p_notes, reviewed_by = p_reviewed_by, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function approve_rumor(uuid, text, text) from public;

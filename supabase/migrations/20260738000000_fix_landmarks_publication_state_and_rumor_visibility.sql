-- Two compounding discoveries from trying to apply 20260737 against the
-- real live database (its own transaction rolled back cleanly, so none
-- of this was ever live -- fixing in place rather than patching on top):
--
-- 1. landmarks.publication_state does not exist on the live table at
--    all -- the copy of the original schema migration in this repo has
--    drifted from what was actually run against production at some
--    point before this session. The real gate (per
--    landmarks_public_read's live definition) is
--    lifecycle_state = ANY ('seeded', 'published') -- lifecycle_state
--    was always the one true visibility signal for this table; every
--    reference to landmarks.publication_state added across the Rumor
--    work (submit_rumor, approve_rumor, landmarks_map_view, atlas_view,
--    rumor_landmarks_view) was reading a column that isn't real and
--    would have failed the moment it actually ran.
--
-- 2. lifecycle_state = 'rumor' is NOT unique to genuine player Rumor
--    submissions -- the live database already has a large backlog of
--    real, pipeline-imported candidate Landmarks (~50 rows, names like
--    "Auschwitz", "Veterans Memorial Wall", several street murals) that
--    also sit at lifecycle_state = 'rumor', pending real curation, long
--    before this feature existed. The schema's own original comment on
--    community_verification_status already said as much: it's "only
--    meaningful for player-submitted candidates
--    (landmark_sources.source_type = 'player_submission')" -- that join
--    is the actual disambiguator this whole time, and rumor_landmarks_view/
--    landmarks_rumor_read should have used it from the start instead of
--    lifecycle_state alone.

-- submit_rumor: drop the publication_state column entirely -- it never
-- existed to set.
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

-- approve_rumor: only lifecycle_state actually needs to move.
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

-- Tightened at the source: a landmark only counts as a
-- visible-for-confirmation Rumor if a genuine player_submission source
-- record exists for it -- not just because its lifecycle_state happens
-- to say 'rumor', which the pipeline-import backlog also uses.
drop policy if exists landmarks_rumor_read on landmarks;
create policy landmarks_rumor_read on landmarks
  for select using (
    lifecycle_state = 'rumor'
    and exists (
      select 1 from landmark_sources s
      where s.landmark_id = landmarks.id and s.source_type = 'player_submission'
    )
  );

-- Both views filter explicitly on the REAL gate (lifecycle_state, not
-- the nonexistent publication_state) instead of relying purely on RLS.
create or replace view landmarks_map_view
  with (security_invoker = true) as
select
  id,
  code,
  name,
  category,
  st_y(location::geometry) as lat,
  st_x(location::geometry) as lng
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

-- Same player_submission join as the RLS policy above, belt-and-braces
-- -- excludes the import backlog explicitly, not just via RLS.
-- outside_community_range stays appended LAST (CREATE OR REPLACE VIEW
-- can only add columns at the end, not insert them in the middle).
create or replace view rumor_landmarks_view
  with (security_invoker = true) as
select
  l.id,
  l.code,
  l.name,
  l.description,
  l.category,
  st_y(l.location::geometry) as lat,
  st_x(l.location::geometry) as lng,
  l.required_verifications,
  (
    select count(distinct v.wayfinder_id) from verifications v
    where v.landmark_id = l.id and v.verification_type = 'exists'
  ) as confirmation_count,
  exists (
    select 1 from verifications v
    where v.landmark_id = l.id and v.wayfinder_id = auth.uid() and v.verification_type = 'exists'
  ) as already_confirmed,
  exists (
    select 1 from landmark_sources s
    where s.landmark_id = l.id and s.source_type = 'player_submission' and s.submitted_by = auth.uid()
  ) as is_own_submission,
  l.outside_community_range
from landmarks l
where l.lifecycle_state = 'rumor'
  and exists (
    select 1 from landmark_sources s
    where s.landmark_id = l.id and s.source_type = 'player_submission'
  );

grant select on rumor_landmarks_view to authenticated;

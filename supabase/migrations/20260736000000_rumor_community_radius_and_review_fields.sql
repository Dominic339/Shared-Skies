-- Nearest-Community assignment had no distance limit -- a Rumor far
-- outside every established Community would still get silently
-- attached to whichever one happened to be closest. Flagging instead of
-- rejecting outright: community_id stays NOT NULL (every other join in
-- this schema already assumes it's always populated -- profile_card_slots,
-- postcards, museum donations, claim_bounty, and more all inner-join
-- through it, and relaxing that constraint would ripple through all of
-- them), but outside_community_range marks the assignment as
-- provisional so a reviewer knows to double check it, and so clusters
-- of flagged Rumors can later suggest where a new Community belongs.
alter table landmarks add column outside_community_range boolean not null default false;

insert into app_settings (key, value, description) values (
  'rumors.community_assignment_radius_km',
  '25',
  'Maximum distance from a Community''s center point for a new Rumor to be assigned there without being flagged as outside_community_range.'
)
on conflict (key) do nothing;

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

  -- The <-> KNN operator on a geography column returns meters directly,
  -- so the same ORDER BY comparison also gives the actual distance to
  -- the winning Community, with no separate ST_Distance call needed.
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
    publication_state, outside_community_range
  ) values (
    v_community_id, p_name, p_description, p_category, v_point,
    'rumor', 0, 'pending', v_required_confirmations,
    'draft', v_outside_range
  ) returning id into v_landmark_id;

  insert into landmark_sources (landmark_id, source_type, submitted_by)
  values (v_landmark_id, 'player_submission', v_user_id);

  insert into submission_tickets (ticket_type, subject_table, subject_id, submitted_by, status, submitter_notes)
  values ('landmark_submission', 'landmarks', v_landmark_id, v_user_id, 'open', p_description);

  return v_landmark_id;
end;
$$;

-- reviewed_by is a genuinely new gap -- resolved_at/resolution_notes
-- already covered "when" and "why", but nothing recorded WHO made the
-- call. approve_rumor/reject_rumor run from the SQL editor as the
-- postgres role (no player JWT / auth.uid() in that context), so this
-- has to be an explicit parameter rather than derived automatically --
-- a free-text identifier for now since there's no formal moderator
-- account system yet (that's an Operations Console concern).
alter table submission_tickets add column reviewed_by text;

drop function if exists approve_rumor(uuid, text);

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

  update landmarks
  set lifecycle_state = 'published', publication_state = 'published'
  where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'approved', resolution_notes = p_notes, reviewed_by = p_reviewed_by, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function approve_rumor(uuid, text, text) from public;

drop function if exists reject_rumor(uuid, text);

create or replace function reject_rumor(p_ticket_id uuid, p_reviewed_by text, p_reason text)
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
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a rejection reason is required';
  end if;

  update landmarks set lifecycle_state = 'rejected' where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'rejected', resolution_notes = p_reason, reviewed_by = p_reviewed_by, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function reject_rumor(uuid, text, text) from public;

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
  l.outside_community_range,
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
  ) as is_own_submission
from landmarks l
where l.lifecycle_state = 'rumor';

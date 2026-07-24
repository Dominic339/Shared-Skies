-- Records a player-submitted Rumor at their current location. Reuses
-- the existing landmarks/landmark_sources/submission_tickets pipeline
-- exactly as designed (lifecycle_state='rumor', source_type=
-- 'player_submission', a submission_tickets row to track moderation) --
-- nothing new to invent here, just wiring up what already existed.
-- Nearest published Community by center_point stands in for a real
-- boundary/containment check, since Communities only store a center
-- point, not a polygon, today.
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

  select id into v_community_id from communities
  where publication_state = 'published'
  order by center_point <-> v_point
  limit 1;
  if v_community_id is null then
    raise exception 'no published Community to attach this Rumor to yet';
  end if;

  select value::integer into v_required_confirmations from app_settings where key = 'rumors.required_confirmations';
  v_required_confirmations := coalesce(v_required_confirmations, 5);

  insert into landmarks (
    community_id, name, description, category, location,
    lifecycle_state, source_confidence, community_verification_status, required_verifications, publication_state
  ) values (
    v_community_id, p_name, p_description, p_category, v_point,
    'rumor', 0, 'pending', v_required_confirmations, 'draft'
  ) returning id into v_landmark_id;

  insert into landmark_sources (landmark_id, source_type, submitted_by)
  values (v_landmark_id, 'player_submission', v_user_id);

  insert into submission_tickets (ticket_type, subject_table, subject_id, submitted_by, status, submitter_notes)
  values ('landmark_submission', 'landmarks', v_landmark_id, v_user_id, 'open', p_description);

  return v_landmark_id;
end;
$$;

grant execute on function submit_rumor(text, text, text, double precision, double precision) to authenticated;

-- One confirmation per wayfinder (verifications' own unique constraint),
-- never the original submitter, and only from within
-- rumors.confirmation_radius_meters of the Rumor's actual location.
-- Reaching required_verifications moves the ASSOCIATED TICKET to
-- in_review, not the landmark to published -- confirmations only prove
-- the place exists and is reachable; a human still decides whether it
-- belongs in the game (see approve_rumor/reject_rumor).
create or replace function confirm_rumor(
  p_landmark_id uuid,
  p_lat double precision,
  p_lng double precision
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_landmark record;
  v_radius_meters integer;
  v_is_own_submission boolean;
  v_verification_id uuid;
  v_confirmation_count integer;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to confirm a Rumor';
  end if;

  select * into v_landmark from landmarks where id = p_landmark_id;
  if v_landmark.id is null then
    raise exception 'Rumor not found';
  end if;
  if v_landmark.lifecycle_state != 'rumor' then
    raise exception 'this is no longer an open Rumor';
  end if;

  select exists (
    select 1 from landmark_sources
    where landmark_id = p_landmark_id and source_type = 'player_submission' and submitted_by = v_user_id
  ) into v_is_own_submission;
  if v_is_own_submission then
    raise exception 'you cannot confirm your own Rumor submission';
  end if;

  select value::integer into v_radius_meters from app_settings where key = 'rumors.confirmation_radius_meters';
  v_radius_meters := coalesce(v_radius_meters, 50);

  if not st_dwithin(
    v_landmark.location,
    st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography,
    v_radius_meters
  ) then
    raise exception 'you must be near the Rumor''s location to confirm it';
  end if;

  begin
    insert into verifications (landmark_id, wayfinder_id, verification_type)
    values (p_landmark_id, v_user_id, 'exists')
    returning id into v_verification_id;
  exception when unique_violation then
    raise exception 'you have already confirmed this Rumor';
  end;

  select count(distinct wayfinder_id) into v_confirmation_count
  from verifications
  where landmark_id = p_landmark_id and verification_type = 'exists';

  if v_confirmation_count >= v_landmark.required_verifications and v_landmark.community_verification_status != 'verified' then
    update landmarks set community_verification_status = 'verified' where id = p_landmark_id;
    update submission_tickets
    set status = 'in_review'
    where ticket_type = 'landmark_submission' and subject_table = 'landmarks'
      and subject_id = p_landmark_id and status = 'open';
  end if;

  return v_verification_id;
end;
$$;

grant execute on function confirm_rumor(uuid, double precision, double precision) to authenticated;

-- unsafe/inaccessible/inappropriate become a generic content_report
-- ticket; duplicate gets its own ticket_type (duplicate_flag) since the
-- schema already distinguishes it -- report_category preserves the
-- specific reason regardless of which ticket_type it maps to.
create or replace function report_rumor(
  p_landmark_id uuid,
  p_report_category text,
  p_details text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_ticket_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to report a Rumor';
  end if;
  if not exists (select 1 from landmarks where id = p_landmark_id and lifecycle_state = 'rumor') then
    raise exception 'Rumor not found';
  end if;
  if p_report_category not in ('unsafe', 'inaccessible', 'duplicate', 'inappropriate') then
    raise exception 'invalid report category: %', p_report_category;
  end if;

  insert into submission_tickets (
    ticket_type, subject_table, subject_id, submitted_by, status, report_category, submitter_notes
  ) values (
    case when p_report_category = 'duplicate' then 'duplicate_flag' else 'content_report' end,
    'landmarks', p_landmark_id, v_user_id, 'open', p_report_category, p_details
  ) returning id into v_ticket_id;

  return v_ticket_id;
end;
$$;

grant execute on function report_rumor(uuid, text, text) to authenticated;

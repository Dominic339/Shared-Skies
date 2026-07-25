-- Once the associated ticket leaves 'open' (moved to in_review at the
-- confirmation threshold, or later resolved), confirmations have done
-- their job -- proving the place exists and is reachable. Checking the
-- ticket's own status directly (not re-deriving from confirmation_count
-- vs required_verifications) means this stays correct even if the
-- threshold changes later, or if a ticket is ever moved to in_review by
-- some other path.
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
  v_ticket_status text;
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

  select status into v_ticket_status
  from submission_tickets
  where ticket_type = 'landmark_submission' and subject_table = 'landmarks' and subject_id = p_landmark_id
  order by created_at desc
  limit 1;
  if v_ticket_status is distinct from 'open' then
    raise exception 'This Rumor is already awaiting review.';
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

-- Drop + create (not replace) -- this view has hit CREATE OR REPLACE's
-- column-shape restrictions repeatedly enough across recent migrations
-- that its exact live shape isn't worth trusting; a fresh create
-- sidesteps that class of error entirely. awaiting_review reuses
-- community_verification_status = 'verified' rather than reading
-- submission_tickets directly -- that table has no read policy for
-- players at all (locked down on purpose), and the two are always kept
-- in sync by confirm_rumor() itself (set together, in the same
-- transaction, nowhere else touches either independently).
drop view if exists rumor_landmarks_view;

create view rumor_landmarks_view
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
  (l.community_verification_status = 'verified') as awaiting_review,
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
where l.lifecycle_state = 'rumor'
  and exists (
    select 1 from landmark_sources s
    where s.landmark_id = l.id and s.source_type = 'player_submission'
  );

grant select on rumor_landmarks_view to authenticated;

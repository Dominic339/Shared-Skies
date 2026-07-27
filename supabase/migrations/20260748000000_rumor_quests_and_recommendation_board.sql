-- Three UI/gameplay reworks land together here:
--
--   1. Rumors move off their own tab and into the Community Board as
--      quests (see community_board_ui.gd) -- a rough direction/distance
--      "hot zone" hint instead of an exact pin, submission becomes a
--      proper ticket flow (photo + name + details + a GPS-anchored,
--      radius-clamped location nudge).
--
--   2. Recommending a Landmark becomes a simple unique vote made from
--      the Landmark's own info panel (you have to have actually visited
--      it), not a text review picked from a separate list -- text
--      reviews are a distinct, not-yet-built feature. Publishes
--      immediately (it's a ranking signal from a verified visitor, not
--      user-generated content that needs a moderation queue).
--
--   3. The Community Center's "Recommended Places" board shows the top
--      N most-recommended Landmarks per Community. N is NOT hardcoded
--      to a magic number scattered through the client -- it's
--      community_centers.recommendation_slot_count, a plain integer
--      column defaulting to 3. Community Centers already have a
--      planned tier progression (wooden sign -> board -> visitor
--      center) that will one day update this column when a center
--      advances -- that progression system itself isn't being built
--      here, just the configurable field it will eventually drive.

-- ============================================================================
-- Rumor photo -- private Storage, not a public unrestricted URL
-- ============================================================================

-- Object paths are "<submitter_user_id>/<file>" -- the write policy
-- checks that prefix so a submitter can only ever upload into their own
-- folder. Read is open to any authenticated player (not the public
-- internet) -- the whole point of the photo is helping nearby verifiers
-- and moderators compare it to the real spot, so it needs to be
-- reachable by anyone who might confirm the Rumor, not locked down
-- further than "you're a logged-in player."
insert into storage.buckets (id, name, public)
values ('rumor-photos', 'rumor-photos', false)
on conflict (id) do nothing;

create policy rumor_photos_authenticated_read on storage.objects
  for select using (bucket_id = 'rumor-photos' and auth.role() = 'authenticated');

create policy rumor_photos_own_write on storage.objects
  for insert with check (
    bucket_id = 'rumor-photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- ============================================================================
-- Rumor submission ticket flow: photo ref + GPS-anchored, radius-clamped nudge
-- ============================================================================

-- Tracks which Storage object (see bucket above) a submission's photo
-- lives at -- a plain object path, not a public URL (the client resolves
-- it into a signed/authenticated fetch when actually displaying it).
alter table submission_tickets add column photo_ref text;

insert into app_settings (key, value) values
  ('rumors.location_nudge_radius_meters', '75')
on conflict (key) do nothing;

-- Dropped and recreated rather than a same-signature CREATE OR REPLACE
-- -- both the parameter list (player position added) and the return
-- behavior change here, and Postgres keys a function's identity by its
-- argument type list, so a same-name/different-signature CREATE OR
-- REPLACE would just create a second overload sitting alongside the old
-- one instead of replacing it.
drop function if exists submit_rumor(text, text, text, double precision, double precision);
drop function if exists submit_rumor(text, text, text, double precision, double precision, text);

create function submit_rumor(
  p_name text,
  p_description text,
  p_category text,
  p_player_lat double precision,
  p_player_lng double precision,
  p_lat double precision,
  p_lng double precision,
  p_photo_ref text default null
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
  v_nudge_radius_meters numeric;
  v_landmark_id uuid;
  v_point geography;
  v_player_point geography;
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
  v_player_point := st_setsrid(st_makepoint(p_player_lng, p_player_lat), 4326)::geography;

  -- The nudge exists to fix GPS drift or land the marker on the actual
  -- feature, not to let someone place a Rumor anywhere they like --
  -- enforced server-side against the player's own claimed position, not
  -- just a client-side slider bound that a modified client could ignore.
  select value::numeric into v_nudge_radius_meters
  from app_settings where key = 'rumors.location_nudge_radius_meters';
  v_nudge_radius_meters := coalesce(v_nudge_radius_meters, 75);
  if st_distance(v_point, v_player_point) > v_nudge_radius_meters then
    raise exception 'the marker can only be moved up to %m from your current position', v_nudge_radius_meters;
  end if;

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

  insert into submission_tickets (ticket_type, subject_table, subject_id, submitted_by, status, submitter_notes, photo_ref)
  values ('landmark_submission', 'landmarks', v_landmark_id, v_user_id, 'open', p_description, p_photo_ref);

  return v_landmark_id;
end;
$$;

revoke all on function submit_rumor(text, text, text, double precision, double precision, double precision, double precision, text) from public, anon, authenticated;
grant execute on function submit_rumor(text, text, text, double precision, double precision, double precision, double precision, text) to authenticated;

-- DROP + CREATE, not CREATE OR REPLACE -- this view has already burned
-- a migration on the "cannot change column shape" restriction once.
-- Adds photo_ref (from the submission ticket, so a verifier/moderator
-- can see what was submitted) alongside the existing hot-zone fields.
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
  ) as is_own_submission,
  t.photo_ref
from landmarks l
left join submission_tickets t
  on t.subject_table = 'landmarks' and t.subject_id = l.id and t.ticket_type = 'landmark_submission'
where l.lifecycle_state = 'rumor'
  and exists (
    select 1 from landmark_sources s
    where s.landmark_id = l.id and s.source_type = 'player_submission'
  );

grant select on rumor_landmarks_view to authenticated;

-- ============================================================================
-- Recommendations: a unique visitor vote, not a moderated text review
-- ============================================================================

-- Existing table (see 20260743000000) was designed around required body
-- text + a moderation queue -- relaxed here since a vote carries no
-- text. A real text review is still a plausible separate future feature
-- (this column staying nullable rather than being dropped keeps that
-- door open) but isn't being built now.
alter table community_recommendations alter column body drop not null;

-- A real DB constraint, not just an application-level existence check
-- -- belt-and-suspenders against a race between two near-simultaneous
-- requests from the same player, same convention as
-- community_centers_active_idx / profile_card_placements_active_landmark_idx.
create unique index community_recommendations_unique_active
  on community_recommendations (landmark_id, author_wayfinder_id)
  where status != 'archived';

-- Supersedes the old 2-arg text-review version -- recommending is now a
-- plain "I've been here, this is worth visiting" vote: requires an
-- actual visit, one active vote per player per Landmark, publishes
-- immediately (a verified visitor's vote is a ranking signal, not
-- content that needs review).
drop function if exists recommend_landmark(uuid, text);

create function recommend_landmark(p_landmark_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_community_id uuid;
  v_recommendation_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to recommend a Landmark';
  end if;

  select community_id into v_community_id from landmarks
  where id = p_landmark_id and lifecycle_state in ('seeded', 'published');
  if v_community_id is null then
    raise exception 'Landmark not found or not published';
  end if;

  if not exists (
    select 1 from visits where landmark_id = p_landmark_id and wayfinder_id = v_user_id
  ) then
    raise exception 'you must visit this Landmark before recommending it';
  end if;

  if exists (
    select 1 from community_recommendations
    where landmark_id = p_landmark_id and author_wayfinder_id = v_user_id and status != 'archived'
  ) then
    raise exception 'you have already recommended this Landmark';
  end if;

  insert into community_recommendations (community_id, landmark_id, author_wayfinder_id, status)
  values (v_community_id, p_landmark_id, v_user_id, 'published')
  returning id into v_recommendation_id;

  return v_recommendation_id;
end;
$$;

revoke all on function recommend_landmark(uuid) from public, anon, authenticated;
grant execute on function recommend_landmark(uuid) to authenticated;

-- Withdraws the caller's own vote -- archives rather than deletes, same
-- audit-preserving convention as reject_rumor/reject_recommendation.
-- Returns the archived row's id (not void) so PostgREST's response body
-- isn't empty on success -- an empty body is indistinguishable from a
-- rejection in the client's current generic RPC error handling.
create function unrecommend_landmark(p_landmark_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_recommendation_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated';
  end if;

  update community_recommendations
  set status = 'archived'
  where landmark_id = p_landmark_id and author_wayfinder_id = v_user_id and status != 'archived'
  returning id into v_recommendation_id;

  if v_recommendation_id is null then
    raise exception 'you have not recommended this Landmark';
  end if;

  return v_recommendation_id;
end;
$$;

revoke all on function unrecommend_landmark(uuid) from public, anon, authenticated;
grant execute on function unrecommend_landmark(uuid) to authenticated;

-- Read-only "most recommended Landmarks" per Community -- how many of
-- these get shown is community_centers.recommendation_slot_count
-- (below), not a number baked into this view or the client.
create or replace view community_top_recommendations_view
  with (security_invoker = true) as
select
  cr.community_id,
  cr.landmark_id,
  l.name as landmark_name,
  l.category as landmark_category,
  count(*) as recommendation_count
from community_recommendations cr
join landmarks l on l.id = cr.landmark_id
where cr.status = 'published'
group by cr.community_id, cr.landmark_id, l.name, l.category
order by cr.community_id, count(*) desc;

grant select on community_top_recommendations_view to authenticated;

-- ============================================================================
-- Community Center: configurable Recommended Places board capacity
-- ============================================================================

-- Community Centers are already planned to grow through tiers (a
-- wooden sign -> a board -> a full visitor center) as a Community
-- becomes more active -- this column is what that progression will
-- update later. The progression system itself (what drives a tier
-- change) isn't being designed or built here; this just avoids baking
-- the number 3 into the client ahead of that system existing.
alter table community_centers add column recommendation_slot_count integer not null default 3;

drop view if exists community_centers_view;
create view community_centers_view
  with (security_invoker = true) as
select
  cc.id,
  cc.community_id,
  c.name as community_name,
  cc.name,
  st_y(cc.location::geometry) as lat,
  st_x(cc.location::geometry) as lng,
  cc.anchor_type,
  cc.anchor_name,
  cc.recommendation_slot_count
from community_centers cc
join communities c on c.id = cc.community_id;

grant select on community_centers_view to anon, authenticated;

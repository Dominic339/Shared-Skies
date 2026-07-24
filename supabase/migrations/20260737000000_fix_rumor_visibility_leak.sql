-- Real bug caught before this ever reached testing: the entire
-- pre-existing imported landmark set apparently carries a stale
-- lifecycle_state = 'rumor' from the original import pipeline (nothing
-- before today ever read that column -- publication_state has always
-- been the actual visibility gate, per landmarks_public_read). Adding
-- landmarks_rumor_read (lifecycle_state = 'rumor') as an ADDITIVE RLS
-- policy therefore had two consequences, one cosmetic and one serious:
--
-- 1. rumor_landmarks_view showed every already-published Landmark as an
--    unconfirmed Rumor needing confirmation -- confusing, but harmless.
-- 2. landmarks_map_view and atlas_view both rely purely on RLS with no
--    explicit filter of their own (same class of gap already hit once
--    on profile_card_collection_view/postcard_mailings_view) -- meaning
--    a GENUINELY NEW, unconfirmed Rumor submission would render as a
--    full 3D sign marker on the live map and appear in every player's
--    Atlas before any review happens. That's the one that actually
--    matters and had to be fixed before any real Rumor testing.

-- Tightens the policy at its source: a landmark only counts as a
-- visible-for-confirmation Rumor if it's ACTUALLY not published yet,
-- regardless of what its lifecycle_state happens to say.
drop policy if exists landmarks_rumor_read on landmarks;
create policy landmarks_rumor_read on landmarks
  for select using (lifecycle_state = 'rumor' and publication_state != 'published');

-- Both views now filter explicitly instead of relying purely on RLS --
-- RLS now serves two different audiences on this table (the general
-- public via landmarks_public_read, Rumor-confirmers via
-- landmarks_rumor_read), and a view built for ONE of those audiences
-- can no longer assume RLS alone gives it the right scope.
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
where publication_state = 'published' and archived_at is null;

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
where l.publication_state = 'published' and l.archived_at is null;

grant select on atlas_view to authenticated;

-- Belt-and-braces on top of the tightened policy above: excludes
-- already-published Landmarks explicitly, not just via RLS, matching
-- the intent that this view is ONLY ever genuinely open Rumors.
-- outside_community_range stays appended LAST (matching the fix in
-- 20260736) -- CREATE OR REPLACE VIEW can only add columns at the end.
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
where l.lifecycle_state = 'rumor' and l.publication_state != 'published';

grant select on rumor_landmarks_view to authenticated;

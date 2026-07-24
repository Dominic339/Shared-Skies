-- Every open Rumor, with confirmation progress and per-caller state
-- (already confirmed / is my own submission) so the client can show
-- "Needs confirmations: 3/5" and disable the wrong buttons without a
-- wasted round-trip. security_invoker relies on the new
-- landmarks_rumor_read policy (lifecycle_state = 'rumor') --
-- verifications is already public-read on its own, so no extra
-- visibility concern there.
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
  ) as is_own_submission
from landmarks l
where l.lifecycle_state = 'rumor';

grant select on rumor_landmarks_view to authenticated;

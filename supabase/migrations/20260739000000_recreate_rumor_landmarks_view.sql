-- CREATE OR REPLACE VIEW has been a repeated source of friction on this
-- specific view across the last few migrations (42P16 "cannot change
-- name of view column", then 42P16 "cannot drop columns from view") --
-- its exact current live shape is genuinely hard to pin down with
-- certainty given how many attempts partially applied. DROP + CREATE
-- sidesteps the whole class of positional-compatibility rules entirely,
-- since a fresh CREATE has no prior shape to stay compatible with.
-- Nothing else in the schema selects from this view, so DROP is safe
-- without CASCADE.
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

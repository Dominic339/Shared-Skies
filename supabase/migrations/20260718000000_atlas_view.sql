-- Minimal Atlas: one view joining every published Landmark to the calling
-- wayfinder's own visit record (if any), so the client can render a full
-- "collection book" (visited entries highlighted, unvisited entries
-- present but marked) in a single query instead of stitching together
-- landmarks_map_view + visits client-side.
--
-- security_invoker means this runs with the CALLING user's own
-- permissions -- landmarks/communities are filtered by their existing
-- public_read RLS policies, and the visits subquery is filtered by
-- visits_self_rw (auth.uid() = wayfinder_id), so every row's
-- first_visited_at/visited fields are always about the current user,
-- never another wayfinder's visits. No need to duplicate any of those
-- policies' conditions here.
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
  (v.landmark_id is not null) as visited
from landmarks l
join communities c on c.id = l.community_id
left join (
  select landmark_id, wayfinder_id, min(visited_at) as first_visited_at
  from visits
  group by landmark_id, wayfinder_id
) v on v.landmark_id = l.id;

grant select on atlas_view to authenticated;

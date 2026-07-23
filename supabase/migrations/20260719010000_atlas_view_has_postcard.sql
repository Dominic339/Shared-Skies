-- Adds has_postcard to atlas_view -- lets the Atlas details view show
-- whether a postcard was collected for a visited Landmark, without a
-- second round-trip. Joins directly on auth.uid() rather than through
-- the visits join already in this view, since postcards carries its own
-- holder_wayfinder_id and doesn't need routing through visits at all.
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
  (p.landmark_id is not null) as has_postcard
from landmarks l
join communities c on c.id = l.community_id
left join (
  select landmark_id, wayfinder_id, min(visited_at) as first_visited_at
  from visits
  group by landmark_id, wayfinder_id
) v on v.landmark_id = l.id
left join postcards p on p.landmark_id = l.id and p.holder_wayfinder_id = auth.uid();

grant select on atlas_view to authenticated;

-- Landmark signs used to spin to face the camera every frame, plus snap
-- to a fixed angle on focus -- both replaced client-side with a single,
-- permanent orientation set once at spawn (see landmark_marker.gd). That
-- needs a real value to spawn with: facing_degrees is a compass-style
-- yaw (0 = the same reference direction the old FOCUS_CAMERA_YAW_DEGREES
-- constant used), editable per Landmark same as community_centers'
-- anchor_name -- 0 for every existing row is a placeholder, not a
-- reviewed "faces the trail" choice, until a real content pass sets
-- these individually.
alter table landmarks add column facing_degrees numeric not null default 0;

-- DROP + CREATE, not CREATE OR REPLACE -- appending a column at the very
-- end is technically allowed by REPLACE, but this view has already burned
-- an entire migration (20260738) to the "silently rolled back" version of
-- that restriction; sidestepping the class of bug entirely is cheaper
-- than re-litigating whether this particular change qualifies.
drop view if exists landmarks_map_view;
create view landmarks_map_view
  with (security_invoker = true) as
select
  id,
  code,
  name,
  category,
  st_y(location::geometry) as lat,
  st_x(location::geometry) as lng,
  profile_card_slot_count,
  facing_degrees
from landmarks
where lifecycle_state in ('seeded', 'published');

grant select on landmarks_map_view to anon, authenticated;

drop view if exists atlas_view;
create view atlas_view
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
  exists (select 1 from postcards p where p.landmark_id = l.id) as has_postcard,
  l.facing_degrees
from landmarks l
join communities c on c.id = l.community_id
left join (
  select landmark_id, wayfinder_id, min(visited_at) as first_visited_at
  from visits
  group by landmark_id, wayfinder_id
) v on v.landmark_id = l.id
where l.lifecycle_state in ('seeded', 'published');

grant select on atlas_view to authenticated;

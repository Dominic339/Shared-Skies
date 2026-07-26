-- Landmark signs used to spin to face the camera every frame, plus snap
-- to a fixed angle on focus -- both replaced client-side with a single,
-- permanent orientation set once at spawn (see landmark_marker.gd). That
-- needs a real value to spawn with: facing_degrees is a compass-style
-- yaw (matching the same atan2(x, z) convention the old ambient
-- face-camera code already used). Left nullable with no default rather
-- than defaulting to 0 -- null means "no manual override," which the
-- client resolves by auto-orienting the sign toward the nearest road in
-- its own cooked map tile data (see road_facing.gd). Setting a real
-- number here (e.g. once a content pass hand-picks a better angle, same
-- as community_centers' anchor_name placeholders) always wins over the
-- auto-computed one.
alter table landmarks add column facing_degrees numeric;

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

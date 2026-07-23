-- Lets the client browse a wayfinder's own postcard collection in one
-- query (landmark/community names joined in) instead of stitching
-- postcards + landmarks + communities together client-side. Same
-- security_invoker pattern as atlas_view/landmarks_map_view --
-- postcards_self_rw (auth.uid() = holder_wayfinder_id) already restricts
-- this to the calling wayfinder's own rows, no need to duplicate that
-- condition here.
create or replace view postcard_collection_view
  with (security_invoker = true) as
select
  p.id,
  p.code,
  p.landmark_id,
  l.name as landmark_name,
  p.community_id,
  c.name as community_name,
  p.season,
  p.weather,
  p.time_of_day,
  p.artwork_render_url,
  p.collected_at,
  p.status
from postcards p
join landmarks l on l.id = p.landmark_id
join communities c on c.id = p.community_id;

grant select on postcard_collection_view to authenticated;

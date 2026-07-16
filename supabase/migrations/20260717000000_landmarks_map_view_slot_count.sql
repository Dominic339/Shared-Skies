-- Adds profile_card_slot_count to landmarks_map_view -- needed so the
-- client knows how many card holders to spawn on a sign without a
-- second round-trip. Safe as create-or-replace: only adding a column,
-- not touching the existing ones.
create or replace view landmarks_map_view
  with (security_invoker = true) as
select
  id,
  code,
  name,
  category,
  st_y(location::geometry) as lat,
  st_x(location::geometry) as lng,
  profile_card_slot_count
from landmarks;

grant select on landmarks_map_view to anon, authenticated;

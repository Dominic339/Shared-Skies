-- landmarks.location is a PostGIS geography(Point) column, which
-- PostgREST serializes as raw EWKB hex over the wire -- fine for the
-- Python importer (which already has EWKB encode/decode helpers), but
-- not something worth hand-parsing binary geometry for in GDScript when
-- Postgres can just hand back plain floats instead.
--
-- security_invoker means this view has NO policies of its own -- it
-- evaluates landmarks' existing RLS policies (landmarks_public_read) as
-- whichever role is actually querying, so there's exactly one place
-- ("is this landmark visible") to keep correct, not two.
create view landmarks_map_view
  with (security_invoker = true) as
select
  id,
  code,
  name,
  category,
  st_y(location::geometry) as lat,
  st_x(location::geometry) as lng
from landmarks;

grant select on landmarks_map_view to anon, authenticated;

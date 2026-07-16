class_name GeoProjection
extends RefCounted

# Web Mercator (EPSG:3857) projection -- the same projection standard map
# tiles use, including our own Planetiler-generated ones. Centralizing on
# real Web Mercator here (instead of the tangent-plane approximation this
# replaces) means Landmark/player positions and tile road/water geometry
# share one coordinate system by construction, not two independently-
# approximated ones that could quietly drift apart as the game scales
# past a single town. See map_pipeline/export_cooked_tiles.py for the
# matching Python-side implementation -- the constants and formulas below
# MUST stay identical to that file.
#
# Raw Web Mercator meters are NOT true ground distance away from the
# equator (Mercator's scale factor is 1/cos(lat)) -- to_local() multiplies
# by cos(ORIGIN_LAT) to undo that distortion, so 1 Godot unit stays 1 real
# meter at our origin's latitude. Fine at single-town scale, same
# assumption the tangent-plane approach already made.
#
# Convention: +X = east, -Z = north -- so a marker north of the origin
# sits further "into the distance" from the camera, matching how a
# top-down map normally reads.

const EARTH_RADIUS_METERS := 6378137.0  # WGS84 semi-major axis (Web Mercator's sphere radius)

# Origin is currently hardcoded to Nashua's Community center as a Phase 1
# stand-in. Once Landmark fetching takes the real fetched
# communities.center_point, this should come from that instead.
const ORIGIN_LAT := 42.7654
const ORIGIN_LNG := -71.4676


static func _mercator_x(lng_deg: float) -> float:
	return EARTH_RADIUS_METERS * deg_to_rad(lng_deg)


static func _mercator_y(lat_deg: float) -> float:
	var lat_rad := deg_to_rad(lat_deg)
	return EARTH_RADIUS_METERS * log(tan(PI / 4.0 + lat_rad / 2.0))


static func to_local(lat: float, lng: float) -> Vector3:
	var scale := cos(deg_to_rad(ORIGIN_LAT))
	var dx := (_mercator_x(lng) - _mercator_x(ORIGIN_LNG)) * scale
	var dz := -(_mercator_y(lat) - _mercator_y(ORIGIN_LAT)) * scale
	return Vector3(dx, 0.0, dz)


# Inverse of to_local()'s east/north component, for turning a local
# movement step (fake-GPS WASD input) back into a lat/lng delta.
# Reduces to a simple, exact local linearization at the origin latitude
# -- same precision the tangent-plane approach already had for this use.
static func local_delta_to_lat_lng(east_meters: float, north_meters: float) -> Vector2:
	var origin_lat_rad := deg_to_rad(ORIGIN_LAT)
	var delta_lat_rad := north_meters / EARTH_RADIUS_METERS
	var delta_lng_rad := east_meters / (EARTH_RADIUS_METERS * cos(origin_lat_rad))
	return Vector2(rad_to_deg(delta_lat_rad), rad_to_deg(delta_lng_rad))


# Standard slippy-map (z/x/y) tile index containing (lat, lng) at zoom z
# -- used to figure out which cooked tile files to load around the player.
static func tile_index(lat: float, lng: float, z: int) -> Vector2i:
	var n := pow(2.0, z)
	var lat_rad := deg_to_rad(lat)
	var tx := int((lng + 180.0) / 360.0 * n)
	var ty := int((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n)
	return Vector2i(tx, ty)

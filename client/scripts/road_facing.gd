class_name RoadFacing
extends RefCounted

# Auto-orients a Landmark sign toward the nearest road, reusing the same
# cooked tile JSON map_tile_loader.gd already streams (see
# map_pipeline/export_cooked_tiles.py) -- read directly from disk here
# instead of depending on MapTileLoader's player-position-driven
# streaming, since a Landmark can be loaded before the player has ever
# been anywhere near its tile. Only used as a fallback when a Landmark's
# facing_degrees is null (no manual override set in the database yet).

const ZOOM := 14
const TILE_DIR := "res://assets/map_tiles/nashua/"
# The Landmark's own tile plus one ring of neighbors -- a road can be the
# closest one to a point sitting right at a tile's edge even though the
# road itself is drawn in the adjacent tile.
const SEARCH_RADIUS_TILES := 1

# Above this distance, the "nearest" road found isn't actually the road
# this Landmark sits in front of -- it's just whatever happened to be
# closest within the search radius, which can be 60-70m away in areas the
# cooked tile export has little/no road data for (confirmed on Nashua
# Public Library / Old Stone Well / The Nashua Riverwalk, all ~3 landmarks
# clustered where the nearest road is 60+m off). Committing to a bearing
# toward a road that far away produces a essentially arbitrary facing,
# not a real "front" -- better to report null here so the caller's own
# 0.0 last-resort default kicks in, an obviously-a-placeholder value
# instead of one confident-looking but wrong.
const MAX_ROAD_DISTANCE_METERS := 25.0


# Returns a compass-style yaw in degrees (same atan2(x, z) convention
# landmark_marker.gd's rotation.y and the old ambient face-camera code
# both already used), or null if no road data is available near this
# Landmark at all (e.g. outside the currently-exported map area), or if
# the nearest road found is too far away to plausibly be this Landmark's
# actual front-facing road (see MAX_ROAD_DISTANCE_METERS above).
static func compute_facing_degrees(lat: float, lng: float) -> Variant:
	var local_pos := GeoProjection.to_local(lat, lng)
	var origin := Vector2(local_pos.x, local_pos.z)
	var tile := GeoProjection.tile_index(lat, lng, ZOOM)

	var closest_point: Vector2 = Vector2.ZERO
	var closest_dist_sq := INF
	var found := false

	for dx in range(-SEARCH_RADIUS_TILES, SEARCH_RADIUS_TILES + 1):
		for dy in range(-SEARCH_RADIUS_TILES, SEARCH_RADIUS_TILES + 1):
			var path := "%s%d_%d_%d.json" % [TILE_DIR, ZOOM, tile.x + dx, tile.y + dy]
			if not FileAccess.file_exists(path):
				continue
			var file := FileAccess.open(path, FileAccess.READ)
			var data: Variant = JSON.parse_string(file.get_as_text())
			if data == null:
				continue

			for road: Dictionary in data.get("roads", []):
				var points: Array = road.get("points", [])
				for i in range(points.size() - 1):
					var a := Vector2(points[i][0], points[i][1])
					var b := Vector2(points[i + 1][0], points[i + 1][1])
					var candidate: Vector2 = Geometry2D.get_closest_point_to_segment(origin, a, b)
					var dist_sq := origin.distance_squared_to(candidate)
					if dist_sq < closest_dist_sq:
						closest_dist_sq = dist_sq
						closest_point = candidate
						found = true

	if not found:
		return null
	if closest_dist_sq > MAX_ROAD_DISTANCE_METERS * MAX_ROAD_DISTANCE_METERS:
		return null

	var to_road := closest_point - origin
	return rad_to_deg(atan2(to_road.x, to_road.y))

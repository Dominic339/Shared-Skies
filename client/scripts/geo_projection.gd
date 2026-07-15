class_name GeoProjection
extends RefCounted

# Small-area local-tangent-plane projection -- accurate enough at a single
# Community's scale (a town, a few km across), far simpler than a real
# Mercator/UTM projection, and good enough unless a Community ever spans a
# distance where earth curvature actually starts to matter.
#
# Origin is currently hardcoded to Nashua's Community center as a Phase 1
# stand-in. Once Landmark fetching (step 7) lands, this should take the
# real fetched communities.center_point instead of a constant.
#
# Convention: +X = east, -Z = north -- so a marker north of the origin
# sits further "into the distance" from the camera, matching how a
# top-down map normally reads.

const ORIGIN_LAT := 42.7654
const ORIGIN_LNG := -71.4676
const METERS_PER_DEGREE_LAT := 111320.0


static func to_local(lat: float, lng: float) -> Vector3:
	var meters_per_degree_lng := METERS_PER_DEGREE_LAT * cos(deg_to_rad(ORIGIN_LAT))
	var dx := (lng - ORIGIN_LNG) * meters_per_degree_lng
	var dz := -(lat - ORIGIN_LAT) * METERS_PER_DEGREE_LAT
	return Vector3(dx, 0.0, dz)


# Inverse of to_local()'s east/north component, for turning a local
# movement step (fake-GPS WASD input) back into a lat/lng delta. Shares
# the same constants as to_local() on purpose -- computing the inverse
# independently would risk the two silently drifting out of sync.
static func local_delta_to_lat_lng(east_meters: float, north_meters: float) -> Vector2:
	var meters_per_degree_lng := METERS_PER_DEGREE_LAT * cos(deg_to_rad(ORIGIN_LAT))
	var delta_lat := north_meters / METERS_PER_DEGREE_LAT
	var delta_lng := east_meters / meters_per_degree_lng
	return Vector2(delta_lat, delta_lng)

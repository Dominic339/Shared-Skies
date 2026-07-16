extends Node3D

# Loads cooked tile JSON (see map_pipeline/export_cooked_tiles.py) for a
# small grid around the player's current position and builds plain
# meshes from it -- no MVT/protobuf parsing here, that already happened
# offline. Ground (the existing flat plane) stays as-is; this layers
# water and roads on top of it by height, not by real terrain cutting --
# fine for proving alignment/streaming, not meant to be the final look.

const ZOOM := 14
const LOAD_RADIUS := 1  # 3x3 grid around the player's current tile
const TILE_DIR := "res://assets/map_tiles/nashua/"

const ROAD_WIDTH_METERS := 6.0  # exaggerated for legibility at map-view zoom, not literal road width
const ROAD_Y := 0.05
const WATER_Y := 0.02

const ROAD_COLOR := Color(0.55, 0.52, 0.48)
const WATER_COLOR := Color(0.25, 0.5, 0.85)

var _loaded_tiles: Dictionary = {}  # "z_x_y" -> Node3D
var _current_tile: Vector2i = Vector2i(-999999, -999999)


func _process(_delta: float) -> void:
	var tile := GeoProjection.tile_index(DevLocation.current_lat, DevLocation.current_lng, ZOOM)
	if tile == _current_tile:
		return
	_current_tile = tile
	_update_loaded_tiles(tile)


func _update_loaded_tiles(center: Vector2i) -> void:
	var wanted: Dictionary = {}
	for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dy in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			var key := "%d_%d_%d" % [ZOOM, center.x + dx, center.y + dy]
			wanted[key] = true
			if not _loaded_tiles.has(key):
				_load_tile(center.x + dx, center.y + dy, key)

	for key: String in _loaded_tiles.keys().duplicate():
		if not wanted.has(key):
			_loaded_tiles[key].queue_free()
			_loaded_tiles.erase(key)

	print("MapTileLoader: %d tile(s) loaded, centered on %s" % [_loaded_tiles.size(), center])


func _load_tile(x: int, y: int, key: String) -> void:
	var path := "%s%d_%d_%d.json" % [TILE_DIR, ZOOM, x, y]
	if not FileAccess.file_exists(path):
		return  # no cooked data for this tile (edge of the exported area) -- fine, leave it empty

	var file := FileAccess.open(path, FileAccess.READ)
	var data: Variant = JSON.parse_string(file.get_as_text())
	if data == null:
		return

	var tile_node := Node3D.new()
	tile_node.name = key
	add_child(tile_node)
	_loaded_tiles[key] = tile_node

	var road_list: Array = data.get("roads", [])
	var water_list: Array = data.get("water", [])
	print("  [%s] parsed %d road(s), %d water polygon(s) from JSON" % [key, road_list.size(), water_list.size()])

	var road_meshes_built := 0
	for road: Dictionary in road_list:
		if _add_road_mesh(tile_node, road):
			road_meshes_built += 1
	print("  [%s] built %d road mesh(es), tile_node now has %d child(ren)" % [key, road_meshes_built, tile_node.get_child_count()])

	for water: Dictionary in water_list:
		_add_water_mesh(tile_node, water)


func _add_road_mesh(parent: Node3D, road: Dictionary) -> bool:
	var points: Array = road.get("points", [])
	if points.size() < 2:
		return false

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		var dir := (b - a).normalized()
		var side := Vector2(-dir.y, dir.x) * (ROAD_WIDTH_METERS * 0.5)

		var a0 := Vector3(a.x + side.x, ROAD_Y, a.y + side.y)
		var a1 := Vector3(a.x - side.x, ROAD_Y, a.y - side.y)
		var b0 := Vector3(b.x + side.x, ROAD_Y, b.y + side.y)
		var b1 := Vector3(b.x - side.x, ROAD_Y, b.y - side.y)

		st.add_vertex(a0)
		st.add_vertex(b0)
		st.add_vertex(a1)
		st.add_vertex(a1)
		st.add_vertex(b0)
		st.add_vertex(b1)

	st.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = st.commit()
	var material := StandardMaterial3D.new()
	material.albedo_color = ROAD_COLOR
	# Disabled culling as a direct test of a real hypothesis: if the ribbon
	# triangles' winding order is inverted, their visible face could point
	# down into the ground instead of up at the camera -- which would look
	# exactly like "hidden under the ground" without being a data or
	# position bug at all. Ruling this out directly rather than re-deriving
	# the winding math by hand a second time.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = material
	parent.add_child(mesh_instance)
	return true


func _add_water_mesh(parent: Node3D, water: Dictionary) -> void:
	var points: Array = water.get("points", [])
	if points.size() < 3:
		return

	var poly := PackedVector2Array()
	for p: Array in points:
		poly.append(Vector2(p[0], p[1]))

	var indices := Geometry2D.triangulate_polygon(poly)
	if indices.is_empty():
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in indices:
		var p: Vector2 = poly[i]
		st.add_vertex(Vector3(p.x, WATER_Y, p.y))

	st.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = st.commit()
	var material := StandardMaterial3D.new()
	material.albedo_color = WATER_COLOR
	mesh_instance.material_override = material
	parent.add_child(mesh_instance)

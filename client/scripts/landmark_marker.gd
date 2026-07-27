class_name LandmarkMarker
extends Area3D

signal tapped(marker: LandmarkMarker)
# Fired after a direct in-world interaction changes this Landmark's own
# card slots (a collect) -- lets main.gd tell whichever UI happens to be
# showing this same Landmark (the ambient board overlay, the popup) to
# refresh their own badges/slot lists too, since those aren't reloaded
# automatically just because the physical card object changed.
signal card_state_changed(marker: LandmarkMarker)

# Color-coded tag, not unique per-category art -- deliberately simple
# until there's a reason to invest in real category iconography.
const CATEGORY_COLORS := {
	"park": Color(0.3, 0.7, 0.3),
	"trail": Color(0.55, 0.4, 0.2),
	"museum": Color(0.6, 0.3, 0.7),
	"historic_site": Color(0.65, 0.5, 0.25),
	"garden": Color(0.4, 0.8, 0.4),
	"overlook": Color(0.4, 0.6, 0.8),
	"beach": Color(0.9, 0.8, 0.5),
	"business": Color(0.5, 0.5, 0.5),
	"memorial": Color(0.6, 0.6, 0.65),
	"covered_bridge": Color(0.6, 0.35, 0.15),
	"other": Color(0.7, 0.7, 0.7),
}

const NAME_COLOR := Color(1, 1, 1)
const NAME_COLOR_SELECTED := Color(1, 0.85, 0.3)

# Fixed scale, not distance-compensated -- an earlier version grew the
# sign as the camera pulled back to counteract perspective shrinkage, but
# that made it visibly resize/shrink relative to the camera in a way that
# read as wrong rather than helpful. Signs are just a set size now, same
# as everything else in the world. 2x true model scale for a bigger visual
# presence (closer to how prominent Pokestop/gym markers read in Pokemon
# GO), not real-world accuracy -- if this scales the whole marker,
# remember STRUCTURE_TOP_HEIGHT_METERS below and main.gd's
# FOCUS_TARGET_HEIGHT_METERS are world-space constants added to
# global_position directly (not local child transforms), so they need to
# scale by the same factor to still point at the sign's actual top/center.
const SIGN_SCALE := 2.0

var landmark_id: String = ""
var code: String = ""
var landmark_name: String = ""
var category: String = ""
var facing_degrees: float = 0.0

var in_range: bool = false
var visited: bool = false
var selected: bool = false

@onready var in_range_indicator: MeshInstance3D = $InRangeIndicator
@onready var visited_indicator: MeshInstance3D = $VisitedIndicator
@onready var category_tag: MeshInstance3D = $CategoryTag
@onready var name_label: Label3D = $NameLabel3D
@onready var sign_model: Node3D = $SignModel
@onready var card_holders: Node3D = $CardHolders
@onready var wind_swirl: GPUParticles3D = $WindSwirl

const ToonShader := preload("res://shaders/toon.gdshader")
const ProfileCardHolderScene := preload("res://assets/models/profile_card_holder.glb")
const ProfileCardScene := preload("res://assets/models/profile_card.glb")

const OWN_CARD_TINT := Color(1, 0.85, 0.3)
const COLLECTED_CARD_TINT := Color(0.45, 0.45, 0.45)

# How close (in the marker's own local, unscaled space) a click's world hit
# point has to land to a card holder's position to count as hitting it. Read
# straight off the world-space point Godot's physics picking already hands
# _on_input_event -- not a separate Area3D per holder, since multiple
# overlapping pickable colliders at effectively the same depth (a card
# holder sitting right on the board's own front face) is exactly the kind of
# thing Godot's closest-hit object picking can get ambiguous about. One
# collision shape (the existing sign body), one input_event, geometry-based
# dispatch.
#
# The quick-collect button and the description "read more" both used to be
# hotspots here too, but moved to the 2D board overlay UI instead (see
# landmark_board_overlay.gd) -- a hotspot on the physical sign that isn't
# reliably discoverable/clickable (this sign's flat wood board has no
# printed text or button art at all yet) isn't actually more "in-world" than
# a UI button, it's just a UI button you can't see.
const CARD_HOTSPOT_RADIUS := 0.15

# One row (from profile_card_slots_view) per card slot, refreshed whenever
# this Landmark's own cards might have changed -- lets the physical holders
# show real occupancy instead of always sitting empty, and lets a direct
# tap on an occupied holder know whether there's actually something
# collectible there without a UI popup being open at all.
var _slot_rows: Array = []
# Static per-slot hotspot centers, built once when the holders themselves
# are spawned (position doesn't depend on fetched data, only on slot count).
var _holder_hotspots: Array = []

# Card/holder models are each authored at their own local origin (0,0,0)
# in their own files -- they don't carry a baked position relative to
# the sign, so placement has to happen here. FIRST_SLOT_POSITION is a
# real reference point (converted from Blender Z-up to Godot Y-up:
# X same, Y<-Blender Z, Z<-(-Blender Y)) taken from an example
# arrangement Dominic had in his working scene, not a guess -- but
# SLOT_SPACING (the vertical gap between stacked holders) IS an
# estimate, derived from the card's own ~6.9cm height plus a small gap,
# since no second reference point was available to measure spacing
# directly. Check both once visible in Godot.
# Z shifted by +1.173 along with every other child in LandmarkMarker.tscn
# (SignModel included) -- the sign model's own local origin turned out to
# sit at its edge (mesh Z spans -2.301..-0.045, center -1.173), not its
# visual center, which is what made the marker rotate like a door hinge
# instead of spinning in place, and made camera-focus/panel-anchor code
# aim at that edge instead of the board. Shifting everything the same
# amount re-centers the origin on the sign without moving anything
# relative to the model itself.
const FIRST_SLOT_POSITION := Vector3(0.04, 1.7999, -1.0884)
const SLOT_SPACING := 0.09

# Real measured height of the sign structure (parsed directly from
# landmark_sign.glb's mesh accessor bounds + its node transform, not a
# screenshot estimate): ~2.54m tall at true (1x) scale, ~2.26m wide.
# Multiplied by SIGN_SCALE since this is a world-space offset added to
# global_position directly, not a local child transform -- it doesn't
# get scaled automatically the way the sign mesh and other child nodes
# do. Used as the anchor height for the info panel so it tracks the
# actual sign top instead of the marker's ground-level origin --
# anchoring to ground was what let the panel overlap the sign as it got
# closer/bigger on screen.
const STRUCTURE_TOP_HEIGHT_METERS := 2.54 * SIGN_SCALE


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)
	in_range_indicator.visible = false
	visited_indicator.visible = false
	scale = Vector3.ONE * SIGN_SCALE
	_apply_toon_demo_material(sign_model)


# TEMPORARY: applies toon/cel-shading on top of the sign model's own
# authored colors (read from each surface's original imported material)
# rather than forcing one hardcoded tint -- preserves whatever Dominic
# actually set up per material slot in Blender (e.g. the board's dark
# wood body vs. its lighter trim color) while still adding the banded
# lighting response. Revisit once the sign's real materials/textures are
# finalized -- this is a reasonable default, not the final art pass.
func _apply_toon_demo_material(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		for surface_idx in mesh_instance.mesh.get_surface_count():
			var original := mesh_instance.mesh.surface_get_material(surface_idx) as StandardMaterial3D
			var material := ShaderMaterial.new()
			material.shader = ToonShader
			material.set_shader_parameter(
				"albedo_tint", original.albedo_color if original else Color(0.4, 0.27, 0.15)
			)
			material.set_shader_parameter("use_vertex_color", false)
			material.set_shader_parameter("light_bands", 3)
			material.set_shader_parameter("band_softness", 0.15)
			# The whole sign is built from flat boards, no curved
			# surfaces -- see use_flat_face_normal's own comment in
			# toon.gdshader for why this is needed to stop each flat
			# board's two triangles from banding into visibly different
			# shades of the same face.
			material.set_shader_parameter("use_flat_face_normal", true)
			mesh_instance.set_surface_override_material(surface_idx, material)
	for child in node.get_children():
		_apply_toon_demo_material(child)


# Single entry point for populating a freshly-instantiated marker --
# keeps the 3D name tag/category color in sync with the data instead of
# needing every caller to remember to update them separately.
func setup(
	p_landmark_id: String, p_code: String, p_name: String, p_category: String,
	p_slot_count: int = 3, p_facing_degrees: float = 0.0
) -> void:
	landmark_id = p_landmark_id
	code = p_code
	landmark_name = p_name
	category = p_category
	facing_degrees = p_facing_degrees

	name_label.text = landmark_name
	# Set once, here, and never touched again -- signs are static world
	# objects like Pokestops, not billboards that track the camera.
	# FRONT_AXIS_CORRECTION_DEGREES compensates for the sign model's
	# authored front direction not lining up with facing_degrees=0.
	rotation.y = deg_to_rad(facing_degrees) + deg_to_rad(FRONT_AXIS_CORRECTION_DEGREES)
	# Sub-resources (like this material) are shared across every instance
	# of a scene by default -- duplicate before mutating, or every marker
	# would end up the same color as whichever was set up last.
	var tag_material := (category_tag.get_surface_override_material(0) as StandardMaterial3D).duplicate() as StandardMaterial3D
	tag_material.albedo_color = CATEGORY_COLORS.get(category, CATEGORY_COLORS["other"])
	category_tag.set_surface_override_material(0, tag_material)

	_spawn_card_holders(p_slot_count)
	refresh_card_slots()


# One holder per profile_card_slot_count -- as a Landmark upgrades and
# gains slots, this just spawns more holders stacked above the first,
# not a new system. Holders are permanent sign fixtures; what's actually
# sitting in one (a real card, or nothing) is separate, data-driven state
# -- see refresh_card_slots()/_rebuild_card_visuals().
#
# Fit-tested position for a profile_card.glb instance inside a holder's
# pocket -- no rotation correction needed (the card model has its upright
# + 20 deg forward lean pre-baked to match the holder).
const CARD_FIT_POSITION := Vector3(0.002, 0.03, 0)


func _spawn_card_holders(slot_count: int) -> void:
	for existing in card_holders.get_children():
		existing.queue_free()
	_holder_hotspots.clear()
	for i in slot_count:
		var holder := ProfileCardHolderScene.instantiate()
		card_holders.add_child(holder)
		var holder_position := FIRST_SLOT_POSITION + Vector3(0, SLOT_SPACING * i, 0)
		holder.position = holder_position
		_holder_hotspots.append({"slot_index": i, "position": holder_position})
		# Real cards are spawned/removed by _rebuild_card_visuals() based on
		# profile_card_slots_view data (see refresh_card_slots()), not here
		# -- holders are permanent sign fixtures, but what's sitting in them
		# depends on who's actually left/collected a card.


# Re-fetches this Landmark's own card slots and rebuilds the physical card
# objects in each holder to match -- called once on setup(), and again after
# a direct in-world collect (see _collect_card()) or whenever main.gd is told
# some other UI changed this same Landmark's slots.
func refresh_card_slots() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"profile_card_slots_view",
		(
			"select=slot_id,slot_index,placement_id,is_own_card,already_collected,occupied"
			+ "&landmark_id=eq.%s&order=slot_index" % landmark_id
		)
	)
	_slot_rows = rows
	_rebuild_card_visuals()


func _slot_row_for_index(index: int) -> Variant:
	for row: Dictionary in _slot_rows:
		if row.get("slot_index", -1) == index:
			return row
	return null


func _rebuild_card_visuals() -> void:
	for i in card_holders.get_child_count():
		var holder: Node3D = card_holders.get_child(i)
		var existing_card := holder.get_node_or_null("Card")
		if existing_card:
			# queue_free() is deferred -- the freed node still holds the name
			# "Card" until the end of the frame, so the fresh card added
			# below would get silently renamed to "Card2" by Godot's name
			# collision handling. That's exactly why the collect animation
			# only ever played once: every _collect_card() after the first
			# looked up holder.get_node_or_null("Card") and found this
			# already-freed node instead of the real, currently-visible one.
			# Renaming it first frees up the name immediately (renames are
			# synchronous even though the actual deletion isn't).
			existing_card.name = "CardPendingFree"
			existing_card.queue_free()

		var row: Variant = _slot_row_for_index(i)
		if row == null or not row.get("occupied", false):
			continue

		var card := ProfileCardScene.instantiate()
		card.name = "Card"
		holder.add_child(card)
		card.position = CARD_FIT_POSITION
		# Own card: gold, so you can spot it as yours. Someone else's card
		# you've already collected your copy of: dimmed -- still a real
		# object other players can still collect from, just not you again.
		# Anything else here is a fresh, collectible card in its natural color.
		if row.get("is_own_card", false):
			_tint_card(card, OWN_CARD_TINT)
		elif row.get("already_collected", false):
			_tint_card(card, COLLECTED_CARD_TINT)


func _tint_card(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		for surface_idx in mesh_instance.mesh.get_surface_count():
			var original := mesh_instance.mesh.surface_get_material(surface_idx) as StandardMaterial3D
			var duped := (original.duplicate() as StandardMaterial3D) if original else StandardMaterial3D.new()
			duped.albedo_color = tint
			mesh_instance.set_surface_override_material(surface_idx, duped)
	for child in node.get_children():
		_tint_card(child, tint)


func _hotspot_slot_index(local_point: Vector3) -> int:
	for hotspot: Dictionary in _holder_hotspots:
		if local_point.distance_to(hotspot["position"]) <= CARD_HOTSPOT_RADIUS:
			return hotspot["slot_index"]
	return -1


# Tapping directly on an occupied, not-yet-collected, not-your-own card is
# the direct-interaction equivalent of the popup's "Collect" button. Empty
# slots and your own card don't do anything on a direct tap yet -- leaving
# your own card still goes through the popup's "Leave My Card" button until
# that also moves out here (a later phase).
func _on_slot_hotspot_clicked(slot_index: int) -> void:
	if not in_range:
		return
	var row: Variant = _slot_row_for_index(slot_index)
	if row == null:
		return
	if row.get("occupied", false) and not row.get("is_own_card", false) and not row.get("already_collected", false):
		_collect_card(row.get("placement_id", ""), slot_index)


# Called from the board overlay's "Collect" button (see
# landmark_board_overlay.gd) -- collects the first available card without
# the player needing to find/tap the exact right holder themselves.
func quick_collect() -> void:
	if not in_range:
		return
	for row: Dictionary in _slot_rows:
		if row.get("occupied", false) and not row.get("is_own_card", false) and not row.get("already_collected", false):
			_collect_card(row.get("placement_id", ""), row.get("slot_index", 0))
			return
	# Nothing collectible right now -- silently a no-op. The ambient board
	# overlay's "Card available" badge is the real indicator of whether this
	# button will actually do anything.


# Whether quick_collect() would actually do anything right now -- lets the
# board overlay disable its "Collect" button instead of it silently no-oping.
func has_collectible_card() -> bool:
	for row: Dictionary in _slot_rows:
		if row.get("occupied", false) and not row.get("is_own_card", false) and not row.get("already_collected", false):
			return true
	return false


func _collect_card(placement_id: String, slot_index: int) -> void:
	var holder: Node3D = card_holders.get_child(slot_index)
	var card: Node3D = holder.get_node_or_null("Card")

	var row := await SupabaseClient.insert_row("profile_card_collections", {
		"placement_id": placement_id,
		"collected_by": SupabaseClient.user_id,
	})
	if row.is_empty():
		print("Failed to collect card for placement %s" % placement_id)
		return

	if card:
		await _play_collect_animation(card)
	await refresh_card_slots()
	card_state_changed.emit(self)


# "Up and out" -- lifts straight up out of the holder pocket first (reads as
# physically freeing the card), then arcs further up and away from the sign
# while shrinking to nothing, rather than just vanishing in place.
func _play_collect_animation(card: Node3D) -> void:
	var start_position := card.position
	var tween := create_tween()
	tween.tween_property(card, "position", start_position + Vector3(0, 0.15, 0), 0.2)
	tween.tween_property(card, "position", start_position + Vector3(0, 0.55, 0.45), 0.4)
	tween.parallel().tween_property(card, "scale", Vector3.ZERO, 0.4)
	await tween.finished
	card.queue_free()


func set_in_range(value: bool) -> void:
	# Rising edge only -- a one-shot burst when you actually arrive, not a
	# permanent ambient loop (was always emitting before, regardless of
	# distance). Re-entering range later (walk away, come back) plays it
	# again via restart(), same as the first arrival.
	if value and not in_range:
		wind_swirl.restart()
	in_range = value
	in_range_indicator.visible = value


func set_visited(value: bool) -> void:
	visited = value
	visited_indicator.visible = value


func set_selected(value: bool) -> void:
	selected = value
	# The floating in-world name tag is sized for browsing from a distance
	# -- at focus range it's many times wider than the sign itself (a long
	# name at Label3D's world scale dwarfs the ~2.26m board), and the info
	# panel already shows the name up close, so keeping both up is both
	# redundant and what was actually overflowing the screen on focus.
	name_label.visible = not value
	name_label.modulate = NAME_COLOR_SELECTED if value else NAME_COLOR
	# While focused, every interaction (collect, recommend, read more) now
	# lives on the 2D popup/board overlay instead -- leaving this sign's own
	# 3D collider pickable at the same time let clicks meant for those UI
	# buttons land on the sign underneath instead (or in addition), since
	# the focused camera view sits the sign directly behind that UI.
	# Disabling it here, and re-enabling on unfocus, means direct-on-sign
	# interaction (tapping a card to collect it) only has to work in the
	# one state -- not focused -- where nothing else is competing for the
	# same clicks.
	input_ray_pickable = not value


# Degrees added on top of facing_degrees to correct for the sign model's
# authored front direction not matching Godot's look_at() default (local
# -Z is "forward"). If the sign ends up facing the wrong way once tested,
# this is the one number to change -- try 90, -90, or 180.
const FRONT_AXIS_CORRECTION_DEGREES := -90.0


func _on_input_event(
	_camera: Node, event: InputEvent, click_position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	var pressed: bool = (
		(event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
		or (event is InputEventScreenTouch and event.pressed)
	)
	if not pressed:
		return

	# click_position is the world-space point Godot's physics picking hit on
	# this sign's own collision shape -- converting to local space and
	# checking it against the card holders' positions lets this one collider
	# serve both "tap a card to collect it" and "tap the sign to focus it"
	# without a separate Area3D (and its overlapping-collider ambiguity) per
	# holder.
	var local_point := to_local(click_position)

	var slot_index := _hotspot_slot_index(local_point)
	if slot_index != -1:
		_on_slot_hotspot_clicked(slot_index)
		return

	tapped.emit(self)

extends Node

# Thin REST wrapper over Supabase's Auth + PostgREST endpoints, using
# Godot's built-in HTTPRequest -- no third-party SDK. Deliberately minimal:
# our surface is small enough (a handful of tables, RLS doing the access
# control) that a full client library would add dependency risk without
# saving meaningful code.
#
# SUPABASE_ANON_KEY below is the "publishable" key -- safe to ship inside
# the client, all it can do is what RLS policies already allow anonymously.
# The project's secret/service-role key must NEVER appear in this file or
# anywhere else under client/ -- it bypasses RLS entirely and belongs only
# to server-side/importer tooling, never to code that ships inside the app.

const SUPABASE_URL := "https://iqqfglzlmtnriojgxgpr.supabase.co"
const SUPABASE_ANON_KEY := "sb_publishable_9rngqcx4H_l67iS2rNPsDw_FCzCYQFu"

const SESSION_PATH := "user://session.json"

signal authenticated

var access_token: String = ""
var refresh_token: String = ""
var user_id: String = ""
var is_ready: bool = false
# Dev-only: lets multiple anonymous test accounts be switched between
# under different labels (see switch_to_test_account) without clearing
# session data -- needed to test player-to-player features like profile
# card placement/collection, which require two separate identities.
var current_test_label: String = "default"


func _ready() -> void:
	# Anonymous auth needs to persist across app restarts -- otherwise every
	# launch mints a brand new anonymous identity and silently orphans
	# whatever the player collected last time. Try to resume a saved
	# session first; only mint a fresh anonymous user if that fails.
	var saved_refresh_token := _load_saved_refresh_token(current_test_label)
	if saved_refresh_token != "":
		if await _refresh_session(saved_refresh_token):
			return
	await _sign_in_anonymously()


# Dev-only: switches to a separate anonymous account under `label`,
# minting a brand new one the first time that label is used and resuming
# it on every later switch back -- lets two-player features be tested by
# swapping identities in the same running game instead of reinstalling or
# clearing session data.
func switch_to_test_account(label: String) -> void:
	current_test_label = label
	is_ready = false
	var saved := _load_saved_refresh_token(label)
	if saved != "":
		if await _refresh_session(saved):
			return
	await _sign_in_anonymously()


func _sign_in_anonymously() -> bool:
	var response := await _post_auth("/auth/v1/signup", {})
	return _apply_session_response(response)


func _refresh_session(token: String) -> bool:
	var response := await _post_auth(
		"/auth/v1/token?grant_type=refresh_token", {"refresh_token": token}
	)
	return _apply_session_response(response)


func _apply_session_response(response: Dictionary) -> bool:
	if response.is_empty() or not response.has("access_token"):
		return false
	access_token = response["access_token"]
	refresh_token = response["refresh_token"]
	user_id = response.get("user", {}).get("id", "")
	_save_refresh_token(current_test_label, refresh_token)
	is_ready = true
	authenticated.emit()
	return true


func _post_auth(path: String, body: Dictionary) -> Dictionary:
	var headers := [
		"apikey: " + SUPABASE_ANON_KEY,
		"Content-Type: application/json",
	]
	return await _request(SUPABASE_URL + path, headers, HTTPClient.METHOD_POST, JSON.stringify(body))


# Authenticated GET against a PostgREST table, e.g.
# get_table("landmarks", "select=id,name,category&community_id=eq.<uuid>")
func get_table(table: String, query: String = "") -> Array:
	var headers := [
		"apikey: " + SUPABASE_ANON_KEY,
		"Authorization: Bearer " + access_token,
	]
	var url := "%s/rest/v1/%s" % [SUPABASE_URL, table]
	if query != "":
		url += "?" + query
	var result: Variant = await _request(url, headers, HTTPClient.METHOD_GET)
	return result if result is Array else []


# Authenticated INSERT against a PostgREST table. Returns the inserted
# row (Prefer: return=representation), or an empty Dictionary on failure
# -- callers use .is_empty() to check success rather than a separate
# error path, since RLS rejection and network failure both just come
# back as "nothing was written."
func insert_row(table: String, data: Dictionary) -> Dictionary:
	var headers := [
		"apikey: " + SUPABASE_ANON_KEY,
		"Authorization: Bearer " + access_token,
		"Content-Type: application/json",
		"Prefer: return=representation",
	]
	var url := "%s/rest/v1/%s" % [SUPABASE_URL, table]
	var result: Variant = await _request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(data))
	return result[0] if result is Array and result.size() > 0 else {}


func _request(url: String, headers: PackedStringArray, method: HTTPClient.Method, body: String = "") -> Variant:
	var http_request := HTTPRequest.new()
	add_child(http_request)

	var error := http_request.request(url, headers, method, body)
	if error != OK:
		http_request.queue_free()
		push_error("Supabase request failed to send (%s): %s" % [url, error])
		return {}

	var result: Array = await http_request.request_completed
	http_request.queue_free()

	var response_code: int = result[1]
	var body_bytes: PackedByteArray = result[3]
	var parsed: Variant = JSON.parse_string(body_bytes.get_string_from_utf8())

	if response_code >= 400 or parsed == null:
		push_error("Supabase request failed (%d) at %s: %s" % [
			response_code, url, body_bytes.get_string_from_utf8()
		])
		return {}

	return parsed


func _load_saved_refresh_token(label: String) -> String:
	if not FileAccess.file_exists(SESSION_PATH):
		return ""
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return ""
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		# Pre-multi-account format: a single top-level refresh_token,
		# always the "default" label.
		if label == "default" and parsed.has("refresh_token"):
			return parsed["refresh_token"]
		var tokens: Variant = parsed.get("tokens", {})
		if tokens is Dictionary and tokens.has(label):
			return tokens[label]
	return ""


func _save_refresh_token(label: String, token: String) -> void:
	# Preserves whatever other labels' tokens already exist (including a
	# pre-multi-account "default" token) instead of clobbering them --
	# switching to a new test account shouldn't lose the ability to
	# switch back to ones already saved.
	var tokens := {}
	if FileAccess.file_exists(SESSION_PATH):
		var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
		if file != null:
			var parsed: Variant = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				if parsed.has("refresh_token"):
					tokens["default"] = parsed["refresh_token"]
				var existing: Variant = parsed.get("tokens", {})
				if existing is Dictionary:
					tokens.merge(existing, true)
	tokens[label] = token
	var file := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"tokens": tokens}))

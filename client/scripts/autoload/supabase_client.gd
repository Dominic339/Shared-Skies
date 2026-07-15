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


func _ready() -> void:
	# Anonymous auth needs to persist across app restarts -- otherwise every
	# launch mints a brand new anonymous identity and silently orphans
	# whatever the player collected last time. Try to resume a saved
	# session first; only mint a fresh anonymous user if that fails.
	var saved_refresh_token := _load_saved_refresh_token()
	if saved_refresh_token != "":
		if await _refresh_session(saved_refresh_token):
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
	_save_refresh_token(refresh_token)
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


func _load_saved_refresh_token() -> String:
	if not FileAccess.file_exists(SESSION_PATH):
		return ""
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return ""
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.has("refresh_token"):
		return parsed["refresh_token"]
	return ""


func _save_refresh_token(token: String) -> void:
	var file := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"refresh_token": token}))

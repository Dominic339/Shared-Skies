extends Node

# Thin REST wrapper over Supabase's Auth + PostgREST endpoints, using
# Godot's built-in HTTPRequest -- no third-party SDK. Deliberately minimal:
# our surface is small enough (a handful of tables, RLS doing the access
# control) that a full client library would add dependency risk without
# saving meaningful code.
#
# Stub for now -- filled in during Phase 1 step 3/4 (anonymous auth +
# authenticated REST calls). Left as an autoload so scenes can reference
# `SupabaseClient` from anywhere without wiring it up per-scene.

const SUPABASE_URL := ""
const SUPABASE_ANON_KEY := ""

var access_token: String = ""

-- Real security gap found while testing Community recommendations: a
-- normal player could call approve_recommendation directly and get a
-- business-logic error ("ticket not found") instead of a permission
-- error -- meaning the function actually EXECUTED for them. All four
-- moderation functions only ever revoked execute from PUBLIC, never
-- explicitly from anon/authenticated -- Supabase grants EXECUTE on new
-- functions to anon/authenticated directly at creation time (separate
-- from the PUBLIC pseudo-role), so revoking only from PUBLIC leaves
-- that direct grant untouched. award_waymarks got this right from the
-- start (revokes from public, anon, AND authenticated); these four
-- didn't match that pattern. Fixing all four now -- none of them should
-- ever be callable by a player, only from the SQL editor as postgres.
revoke all on function approve_rumor(uuid, text, text) from anon;
revoke all on function approve_rumor(uuid, text, text) from authenticated;

revoke all on function reject_rumor(uuid, text, text) from anon;
revoke all on function reject_rumor(uuid, text, text) from authenticated;

revoke all on function approve_recommendation(uuid, text, text) from anon;
revoke all on function approve_recommendation(uuid, text, text) from authenticated;

revoke all on function reject_recommendation(uuid, text, text) from anon;
revoke all on function reject_recommendation(uuid, text, text) from authenticated;

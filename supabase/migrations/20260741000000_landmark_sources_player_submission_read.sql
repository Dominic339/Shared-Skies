-- landmark_sources had RLS enabled with NO select policy at all (an
-- "admin only, append-only provenance log" by original design) -- but
-- landmarks_rumor_read and rumor_landmarks_view both need to check
-- EXISTS (select ... from landmark_sources ...) to distinguish a
-- genuine player submission from the pipeline-import backlog. RLS
-- policy expressions run under the CALLING role's own privileges even
-- when referencing another table, so with zero policies that EXISTS
-- check silently evaluated false for every real player -- not just
-- excluding the import backlog (the intended fix), but excluding
-- EVERY genuine Rumor too, including a player's own fresh submission.
--
-- Scoped narrowly: only source_type = 'player_submission' rows become
-- readable (submitted_by, landmark_id, imported_at -- external_ref/
-- raw_payload are always null for these anyway, submit_rumor() never
-- sets them). Import-pipeline provenance (osm_import/government_dataset/
-- wikipedia_match, which can carry raw_payload/external_ref) stays
-- fully locked down, unchanged from the original design.
create policy landmark_sources_player_submission_read on landmark_sources
  for select using (source_type = 'player_submission');

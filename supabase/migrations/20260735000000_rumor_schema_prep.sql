-- Tunable defaults for new Rumor submissions -- required_verifications
-- is still stored per-landmark (matching the schema's existing design,
-- landmarks.required_verifications), this just controls what NEW Rumors
-- get stamped with at submission time, without a migration each time it
-- needs adjusting.
insert into app_settings (key, value, description) values
  ('rumors.required_confirmations', '5', 'Default landmarks.required_verifications for a newly submitted Rumor.'),
  ('rumors.confirmation_radius_meters', '50', 'How close a confirming wayfinder must physically be to a Rumor to confirm it. Wider than a curated Landmark''s visit radius since a Rumor''s coordinates come from wherever the submitter happened to be standing.')
on conflict (key) do nothing;

-- landmarks_public_read (publication_state = 'published') deliberately
-- excludes Rumors -- a Rumor is explicitly NOT published yet, but still
-- needs to be visible to any nearby player so they can confirm it.
-- Additive with the existing policy (multiple permissive policies OR
-- together): a caller can now see published Landmarks OR rumor-state
-- ones, same pattern as profile_card_placements_public_read.
create policy landmarks_rumor_read on landmarks
  for select using (lifecycle_state = 'rumor');

-- submission_tickets had no field for the SUBMITTER's own explanation --
-- resolution_notes is reserved for the resolver's outcome, not the
-- input. report_category distinguishes the specific reasons a Rumor can
-- be reported for (unsafe/inaccessible/duplicate/inappropriate), only
-- populated for report-type tickets.
alter table submission_tickets add column submitter_notes text;
alter table submission_tickets add column report_category text
  check (report_category in ('unsafe', 'inaccessible', 'duplicate', 'inappropriate'));

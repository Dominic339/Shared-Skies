-- Fixes a dead RLS policy discovered while starting the Godot client work.
--
-- landmarks carried two overlapping status fields: lifecycle_state (the
-- real one -- every importer/enrichment/apply_enrichment tool reads and
-- writes only this) and publication_state (a generic draft/pending_review/
-- published/archived field copied onto every content table by convention,
-- but never actually set anywhere for landmarks). The original
-- landmarks_public_read policy checked publication_state = 'published',
-- which is always false for every row we've ever written -- a client
-- would see zero Landmarks regardless of real review state.
--
-- lifecycle_state already has the right vocabulary for this ('seeded' is
-- explicitly defined as "imported and live without needing community
-- verification" -- see the enum comment in the initial schema). Dropping
-- the redundant column rather than syncing two fields that would only
-- drift again.
drop policy landmarks_public_read on landmarks;

alter table landmarks drop column publication_state;

create policy landmarks_public_read on landmarks
  for select using (
    lifecycle_state in ('seeded', 'published') and archived_at is null
  );

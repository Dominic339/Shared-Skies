-- Three small, cheap additions to landmark_image_candidates:
--
-- status: otherwise there's no way to tell "already looked at this and
-- rejected it" from "haven't looked yet" without inferring it later.
--
-- discovered_by: everything today comes from the automated importer, but
-- this is the field that avoids a schema change once a player-submission
-- or manual-moderator-search path exists.
--
-- confidence: not every candidate is equally trustworthy even within
-- today's harvester -- a direct OSM image tag or a Wikidata P18 claim is
-- a deliberate, curated link; a Commons category's "first" file (picked
-- arbitrarily, not for quality) is a weaker signal. Lets a review queue
-- sort highest-confidence first once one exists.
alter table landmark_image_candidates
  add column status text not null default 'pending'
    check (status in ('pending', 'accepted', 'rejected')),
  add column discovered_by text not null default 'importer'
    check (discovered_by in ('importer', 'manual', 'player')),
  add column confidence numeric(5, 2);

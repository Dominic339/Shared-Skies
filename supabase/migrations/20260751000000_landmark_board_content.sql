-- Kiosk board content, Phase 1: the physical sign becomes a real
-- information surface (name, cover photo, short description, quick-
-- read tags, tiny visited/recommended status) instead of a blank
-- placeholder board. Deliberately NOT stored on landmarks_map_view/
-- atlas_view -- those feed the map pin list and Atlas at boot and
-- don't need player-specific state; a dedicated view below covers the
-- one-per-focused-Landmark board fetch instead, same "base list vs.
-- richer per-item fetch" split already used for card slots.

alter table landmarks add column short_description text;
alter table landmarks add column long_description text;
-- Plain URL string rather than inventing a Storage/asset-reference
-- system for this alone -- a res:// path today (client-bundled test
-- art), a real http(s) URL once the enrichment/import pipeline picks
-- real photos later. The client resolves either the same way rumor
-- photos already distinguish "local placeholder" from "real fetch".
alter table landmarks add column cover_image_url text;

-- A fixed, curated vocabulary (like category/report reasons elsewhere
-- in this schema) rather than freeform tags -- these are meant to be
-- quick-read, high-trust facts on a public sign, not arbitrary text.
-- Extend the allowed list in a follow-up migration whenever a new tag
-- is actually needed.
alter table landmarks add column tags text[] not null default '{}';
alter table landmarks add constraint landmarks_tags_valid check (
  tags <@ array[
    'wheelchair_accessible', 'family_friendly', 'historic', 'scenic',
    'outdoors', 'good_for_photos', 'pet_friendly'
  ]::text[]
);

-- security_invoker relies on: communities_public_read (unconditional),
-- landmarks_public_read (lifecycle_state seeded/published,
-- unconditional), visits' existing self-read policy (wayfinder_id =
-- auth.uid(), matched exactly by this left join's own auth.uid()
-- filter), and community_recommendations_public_read (status =
-- 'published', unconditional) -- no RLS-gap risk, same reasoning as
-- every other player-progress view this project already has.
create or replace view landmark_board_view
  with (security_invoker = true) as
select
  l.id,
  l.code,
  l.name,
  l.category,
  c.name as community_name,
  l.short_description,
  l.long_description,
  l.tags,
  l.cover_image_url,
  (v.landmark_id is not null) as visited,
  (
    select count(*) from community_recommendations cr
    where cr.landmark_id = l.id and cr.status = 'published'
  ) as recommendation_count,
  exists (
    select 1 from community_recommendations cr
    where cr.landmark_id = l.id and cr.author_wayfinder_id = auth.uid() and cr.status = 'published'
  ) as recommended_by_me
from landmarks l
join communities c on c.id = l.community_id
left join visits v on v.landmark_id = l.id and v.wayfinder_id = auth.uid()
where l.lifecycle_state in ('seeded', 'published');

grant select on landmark_board_view to authenticated;

-- Test content for the one Landmark with real art so far -- AI-
-- generated to match how every future Landmark's description will
-- actually be produced by the enrichment pipeline (hand-writing this
-- one would read as inconsistent once the pipeline exists). Grounded
-- in the real monument (Wikipedia/HMdb: cornerstone laid May 30 1889,
-- dedicated October 15 1889, at the Concord/Amherst/Nashville Streets
-- triangle in central Nashua) rather than invented details.
update landmarks set
  short_description = 'A Civil War memorial honoring the soldiers and sailors of Nashua who served during the War of the Rebellion, crowned by a bronze figure of Victory.',
  long_description = 'Dedicated on October 15, 1889, the Soldiers'' and Sailors'' Monument stands where Concord, Amherst, and Nashville Streets meet in the heart of Nashua. Its square granite column rises to a bronze figure of Victory in classical robes, bearing an American shield and laurel wreath. At the base, bronze statues of a soldier and a sailor stand watch beside relief panels depicting the reconciliation of North and South, the emancipation of the enslaved, and the sinking of the CSS Alabama by the USS Kearsarge -- with a cavalry saddle cast at the front and Civil War-era weapons at the rear. It was raised by the people of Nashua in honor of those who served their country from 1861 to 1865.',
  tags = array['historic', 'scenic', 'good_for_photos', 'outdoors'],
  cover_image_url = 'res://assets/landmark_photos/Nashua_NH_Soldiers_and_Sailors_Monument_Icon.jpg'
where id = 'd1252c75-6ae1-4e8f-9d31-235cf9b22435';

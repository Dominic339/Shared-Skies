-- "Cards I've collected from other wayfinders" -- the collection-facing
-- half of the profile card loop, distinct from the Atlas (places visited)
-- and Postcards (souvenirs from first visits).
--
-- Deliberately NOT security_invoker, unlike most views in this codebase.
-- profile_card_placements only grants read access to its owner (all rows)
-- or to anyone for currently-ACTIVE rows (removed_at is null) -- but a
-- placement the caller collected often becomes inactive later, once its
-- 3rd copy is collected by someone (maybe not even the caller). Under
-- security_invoker, that join would silently vanish from the collector's
-- own history the moment the card sells out, which would be a real bug:
-- your own collection screen losing entries because SOMEONE ELSE finished
-- collecting the same card. Running as the view owner instead sidesteps
-- that placement-visibility gap entirely, same reasoning as
-- public_profiles_view -- but that means the collected_by = auth.uid()
-- filter below is doing the ONLY access control here, not RLS, so it
-- must never be dropped.
create or replace view profile_card_collection_view as
select
  c.id as collection_id,
  c.collected_at,
  p.placed_by,
  pr.display_name as placed_by_display_name,
  l.id as landmark_id,
  l.name as landmark_name,
  l.code as landmark_code
from profile_card_collections c
join profile_card_placements p on p.id = c.placement_id
join landmarks l on l.id = p.landmark_id
left join public_profiles_view pr on pr.id = p.placed_by
where c.collected_by = auth.uid();

grant select on profile_card_collection_view to authenticated;

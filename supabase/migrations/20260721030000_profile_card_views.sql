-- Public, minimal-column view of profiles -- deliberately NOT
-- security_invoker, unlike every other view in this codebase.
-- profiles_self_rw only lets a wayfinder read their OWN row, but a card
-- holder needs to show WHOSE card is in it regardless of who's looking.
-- This view runs with the privileges of its owner (the migration role)
-- instead of the caller's, which is what lets any caller see any
-- player's display name here without opening up the rest of the
-- profiles table (bio_text, role, etc. stay private).
create or replace view public_profiles_view as
select id, display_name, home_community_id from profiles;

grant select on public_profiles_view to anon, authenticated;

-- Per-slot state for a Landmark's card holders in one query: whether
-- it's occupied, by whom, how many copies remain, and whether the
-- calling wayfinder already collected it or placed it themselves (so the
-- client can disable the wrong buttons without a wasted round-trip).
-- security_invoker so the profile_card_placements/profile_card_collections
-- joins still respect the calling wayfinder's own RLS.
create or replace view profile_card_slots_view
  with (security_invoker = true) as
select
  s.id as slot_id,
  s.landmark_id,
  s.slot_index,
  p.id as placement_id,
  p.placed_by,
  pr.display_name as placed_by_display_name,
  p.remaining_copies,
  (p.id is not null) as occupied,
  (p.placed_by = auth.uid()) as is_own_card,
  exists (
    select 1 from profile_card_collections c
    where c.placement_id = p.id and c.collected_by = auth.uid()
  ) as already_collected
from profile_card_slots s
left join profile_card_placements p on p.slot_id = s.id and p.removed_at is null
left join public_profiles_view pr on pr.id = p.placed_by;

grant select on profile_card_slots_view to authenticated;

-- is_own_card compared p.placed_by = auth.uid() directly -- for an empty
-- slot (p.placed_by is null via the left join), that comparison evaluates
-- to SQL NULL, not false, which PostgREST serializes as JSON null. The
-- Godot client's Dictionary.get("is_own_card", false) only falls back to
-- its default when the KEY is absent, not when the key is present with a
-- null value, so every empty slot broke the client with a real (not
-- defaulted) null. coalesce() forces the well-defined false instead.
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
  coalesce(p.placed_by = auth.uid(), false) as is_own_card,
  exists (
    select 1 from profile_card_collections c
    where c.placement_id = p.id and c.collected_by = auth.uid()
  ) as already_collected
from profile_card_slots s
left join profile_card_placements p on p.slot_id = s.id and p.removed_at is null
left join public_profiles_view pr on pr.id = p.placed_by;

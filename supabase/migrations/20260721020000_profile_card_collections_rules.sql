-- profile_card_collections had a self-read policy but no insert policy
-- at all -- nothing could actually collect a card. A wayfinder can only
-- insert a collection row for themselves, on an ACTIVE placement, that
-- isn't their own ("players cannot collect their own card").
create policy profile_card_collections_insert on profile_card_collections
  for insert
  with check (
    auth.uid() = collected_by
    and exists (
      select 1 from profile_card_placements p
      where p.id = placement_id
        and p.placed_by != auth.uid()
        and p.removed_at is null
    )
  );

-- Decrements remaining_copies on each collection and closes out the
-- placement (removed_at) once it hits zero, freeing the slot -- "after
-- the third collection, the placement disappears and the holder becomes
-- empty." security definer because the collector (not the original
-- placer) triggers this, and profile_card_placements_owner_rw would
-- otherwise block a non-owner from updating someone else's placement row
-- -- same reasoning as handle_new_user() needing elevated privilege to
-- write on another user's behalf.
create or replace function handle_profile_card_collection()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update profile_card_placements
  set remaining_copies = remaining_copies - 1,
      removed_at = case when remaining_copies - 1 <= 0 then now() else removed_at end
  where id = new.placement_id;
  return new;
end;
$$;

create trigger trg_profile_card_collection_decrement
  after insert on profile_card_collections
  for each row execute function handle_profile_card_collection();

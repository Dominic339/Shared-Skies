-- profile_card_slots existed in the schema from day one but nothing ever
-- populated it. Backfills one row per slot for every existing Landmark
-- (per its own profile_card_slot_count), and keeps future Landmarks in
-- sync automatically regardless of how they get inserted (import
-- pipeline, admin tooling, etc.) -- same server-side-derived-side-effect
-- pattern as handle_new_user().
insert into profile_card_slots (landmark_id, slot_index)
select l.id, gs.i
from landmarks l
cross join lateral generate_series(0, l.profile_card_slot_count - 1) as gs(i)
on conflict (landmark_id, slot_index) do nothing;

create or replace function create_profile_card_slots_for_landmark()
returns trigger
language plpgsql
as $$
begin
  insert into profile_card_slots (landmark_id, slot_index)
  select new.id, gs.i
  from generate_series(0, new.profile_card_slot_count - 1) as gs(i);
  return new;
end;
$$;

create trigger trg_landmarks_create_card_slots
  after insert on landmarks
  for each row execute function create_profile_card_slots_for_landmark();

-- profile_card_slots had RLS enabled from day one but no policy at all,
-- meaning nothing could read it -- players need to see which slots exist
-- and whether they're occupied before leaving/collecting a card, same as
-- landmarks being public-read.
create policy profile_card_slots_public_read on profile_card_slots
  for select using (true);

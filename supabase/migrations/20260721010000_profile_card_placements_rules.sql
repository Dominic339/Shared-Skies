-- landmark_id is denormalized from slot_id's own landmark_id purely to
-- support a real DB-enforced rule: a wayfinder can only have one active
-- placement per Landmark (not per slot) -- "cannot leave duplicate
-- placements at the same Landmark unless the earlier one has emptied."
-- Postgres partial unique indexes can't reference a joined table's
-- column directly, so this needs to live on the row itself. Table is
-- empty (never used yet), so this can be NOT NULL immediately -- the
-- trigger below always populates it before the NOT NULL check runs.
alter table profile_card_placements
  add column landmark_id uuid references landmarks (id) on delete cascade;

create or replace function set_placement_landmark_id()
returns trigger
language plpgsql
as $$
begin
  select landmark_id into new.landmark_id from profile_card_slots where id = new.slot_id;
  return new;
end;
$$;

create trigger trg_profile_card_placements_set_landmark_id
  before insert on profile_card_placements
  for each row execute function set_placement_landmark_id();

alter table profile_card_placements alter column landmark_id set not null;

-- "A player cannot leave duplicate placements at the same Landmark
-- unless the earlier one has expired or emptied" -- enforced at the DB
-- level, not just client-side, since removed_at is null scopes this to
-- only the currently-active placement.
create unique index profile_card_placements_active_landmark_idx
  on profile_card_placements (landmark_id, placed_by) where removed_at is null;

-- profile_card_placements only had an owner-only policy (see
-- profile_card_placements_owner_rw in the initial schema) -- other
-- wayfinders need to see active placements too, to know a slot is
-- occupied and choose whose card to collect. Additive with the existing
-- owner policy (multiple permissive policies OR together), so a
-- wayfinder still sees all of their own placements (any state) plus any
-- active placement from anyone else.
create policy profile_card_placements_public_read on profile_card_placements
  for select using (removed_at is null);

-- Postcards were previously a one-time-ever souvenir gated on
-- visits.is_first_visit -- this replaces that with a repeatable "gift"
-- drop (same shape as Pokemon GO's Pokestop spins): any visit can grant
-- a fresh postcard as long as the wayfinder's last SELF-collected
-- postcard from this specific Landmark was more than 5 minutes ago,
-- letting regulars collect multiple over time from places they visit
-- often, rather than exactly one forever.
--
-- This also fixes a real gap the previous first-visit-only design had:
-- a wayfinder who received a postcard via mail (original_collector_id =
-- the SENDER, not them) but had never personally gotten their own copy
-- of that Landmark's postcard would never get one from visiting in
-- person either, since is_first_visit was already false (a visits row
-- already existed from before the postcard system existed at all, back
-- when there was nothing to backfill it from). Keying the cooldown off
-- original_collector_id specifically -- not "do I hold any postcard for
-- this Landmark" -- means a gifted copy never blocks earning your own.
drop trigger if exists trg_visits_create_postcard on visits;
drop function if exists create_postcard_on_first_visit();

create or replace function create_postcard_on_visit()
returns trigger
language plpgsql
as $$
begin
  insert into postcards (holder_wayfinder_id, original_collector_id, landmark_id, community_id, season, weather, time_of_day)
  select new.wayfinder_id, new.wayfinder_id, l.community_id, 'summer', 'clear', 'day'
  from landmarks l
  where l.id = new.landmark_id
    and not exists (
      select 1 from postcards p
      where p.original_collector_id = new.wayfinder_id
        and p.landmark_id = new.landmark_id
        and p.collected_at > now() - interval '5 minutes'
    );
  return new;
end;
$$;

create trigger trg_visits_create_postcard
  after insert on visits
  for each row execute function create_postcard_on_visit();

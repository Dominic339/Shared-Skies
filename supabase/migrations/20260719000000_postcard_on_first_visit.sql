-- First postcard/collectible: a Postcard is automatically created the
-- first time a wayfinder visits a Landmark, reusing the Community's art
-- (per the earlier design decision to reuse Community-level postcard art
-- rather than generating per-Landmark art from day one) -- season/
-- weather/time_of_day are fixed placeholders until real simulation
-- exists.
--
-- Lives as a trigger on visits, same pattern as handle_new_user()
-- creating a profiles row, rather than a second insert from the client:
-- guaranteed to fire exactly once per genuine first visit regardless of
-- client behavior, and doesn't require exposing community_id to the
-- client at all. The `not exists` guard is a deliberate belt-and-braces
-- check independent of trusting the client's is_first_visit flag --
-- visits.is_first_visit is only enforced at the app layer (see the
-- comment on the visits table), not a DB constraint, so nothing stops a
-- buggy/duplicate client insert from setting it true twice.
create or replace function create_postcard_on_first_visit()
returns trigger
language plpgsql
as $$
begin
  insert into postcards (holder_wayfinder_id, landmark_id, community_id, season, weather, time_of_day)
  select new.wayfinder_id, new.landmark_id, l.community_id, 'summer', 'clear', 'day'
  from landmarks l
  where l.id = new.landmark_id
    and not exists (
      select 1 from postcards p
      where p.holder_wayfinder_id = new.wayfinder_id and p.landmark_id = new.landmark_id
    );
  return new;
end;
$$;

create trigger trg_visits_create_postcard
  after insert on visits
  for each row
  when (new.is_first_visit)
  execute function create_postcard_on_first_visit();

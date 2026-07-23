-- Bug in the previous migration: the INSERT's column list had 7 columns
-- (holder_wayfinder_id, original_collector_id, landmark_id, community_id,
-- season, weather, time_of_day) but the SELECT list only supplied 6
-- values -- new.landmark_id was dropped by mistake when
-- original_collector_id was added alongside holder_wayfinder_id. Because
-- this trigger fires synchronously inside the same transaction as every
-- visits insert, its "INSERT has more target columns than expressions"
-- error aborted the ENTIRE visit -- not just the postcard -- which is
-- why visits stopped recording at all after the previous migration.
create or replace function create_postcard_on_visit()
returns trigger
language plpgsql
as $$
begin
  insert into postcards (holder_wayfinder_id, original_collector_id, landmark_id, community_id, season, weather, time_of_day)
  select new.wayfinder_id, new.wayfinder_id, new.landmark_id, l.community_id, 'summer', 'clear', 'day'
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

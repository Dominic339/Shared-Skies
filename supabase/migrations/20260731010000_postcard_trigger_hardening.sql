-- system_error_log: admin-only (no policies at all, same locked-down
-- shell pattern as payment_orders/submission_tickets) -- records
-- trigger/background failures for a human (or later, the Operations
-- Console) to review, without ever surfacing to or blocking a player.
create table system_error_log (
  id uuid primary key default gen_random_uuid(),
  source text not null,
  error_message text not null,
  context jsonb,
  created_at timestamptz not null default now()
);
alter table system_error_log enable row level security;
-- Deliberately no policies -- only the service role should ever read this.

-- Reads the cooldown from app_settings instead of a hardcoded interval,
-- and wraps the whole postcard-generation attempt in its own exception
-- handler. A postcard is a bonus collectible, not a core guarantee -- a
-- bug here (like the column-count mismatch that took down every visit
-- insert earlier) must never take the actual Landmark visit down with
-- it again. Errors are logged for a human to notice, not re-raised.
create or replace function create_postcard_on_visit()
returns trigger
language plpgsql
as $$
declare
  v_cooldown_minutes integer;
begin
  begin
    select value::integer into v_cooldown_minutes from app_settings where key = 'postcards.cooldown_minutes';
    v_cooldown_minutes := coalesce(v_cooldown_minutes, 5);

    insert into postcards (holder_wayfinder_id, original_collector_id, landmark_id, community_id, season, weather, time_of_day)
    select new.wayfinder_id, new.wayfinder_id, new.landmark_id, l.community_id, 'summer', 'clear', 'day'
    from landmarks l
    where l.id = new.landmark_id
      and not exists (
        select 1 from postcards p
        where p.original_collector_id = new.wayfinder_id
          and p.landmark_id = new.landmark_id
          and p.collected_at > now() - (v_cooldown_minutes || ' minutes')::interval
      );
  exception when others then
    insert into system_error_log (source, error_message, context)
    values (
      'create_postcard_on_visit',
      sqlerrm,
      jsonb_build_object('visit_id', new.id, 'wayfinder_id', new.wayfinder_id, 'landmark_id', new.landmark_id)
    );
  end;

  return new;
end;
$$;

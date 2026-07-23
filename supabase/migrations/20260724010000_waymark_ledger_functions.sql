-- award_waymarks mints currency -- it must NEVER be callable directly by
-- a player, even for testing, because "hide the button in release
-- builds" does not stop a direct RPC call. The dev-only allowlist below
-- is the actual boundary, not client-side visibility.
alter table profiles add column dev_grants_enabled boolean not null default false;
-- profiles_self_rw lets a wayfinder update every OTHER column of their
-- own row -- without this, a player could just PATCH their own profile
-- row via PostgREST and flip this flag themselves, defeating the
-- allowlist entirely. Column-level privilege is the only thing that
-- actually blocks that while leaving the rest of self-editing intact.
revoke update (dev_grants_enabled) on profiles from authenticated;

-- Mints a brand-new currency lot and records the awarding operation.
-- Only ever called internally (by dev_grant_waymarks below, and later by
-- real trusted server-side events like a verified store purchase or a
-- claim_bounty() function that has already checked eligibility) -- never
-- exposed to anon/authenticated directly. p_user_id is a parameter (not
-- derived from auth.uid()) specifically because trusted server-side
-- callers act on OTHER users' behalf (e.g. a purchase completing while
-- that user isn't even the one making the request).
create or replace function award_waymarks(
  p_user_id uuid,
  p_amount integer,
  p_source_type text,
  p_context_type text,
  p_context_id uuid,
  p_description text,
  p_idempotency_key text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_operation_id uuid;
  v_lot_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'award amount must be positive';
  end if;

  if p_idempotency_key is not null then
    begin
      insert into wallet_operations (user_id, operation_type, total_amount, context_type, context_id, description, idempotency_key)
      values (p_user_id, 'award', p_amount, p_context_type, p_context_id, p_description, p_idempotency_key)
      returning id into v_operation_id;
    exception when unique_violation then
      -- Same idempotency key already processed (e.g. a retried request
      -- after a dropped connection) -- return the existing result
      -- instead of awarding twice.
      select id into v_operation_id from wallet_operations where idempotency_key = p_idempotency_key;
      return v_operation_id;
    end;
  else
    insert into wallet_operations (user_id, operation_type, total_amount, context_type, context_id, description)
    values (p_user_id, 'award', p_amount, p_context_type, p_context_id, p_description)
    returning id into v_operation_id;
  end if;

  insert into currency_lots (user_id, source_type, original_amount, remaining_amount)
  values (p_user_id, p_source_type, p_amount, p_amount)
  returning id into v_lot_id;

  insert into wallet_transactions (operation_id, currency_lot_id, amount)
  values (v_operation_id, v_lot_id, p_amount);

  return v_operation_id;
end;
$$;

revoke all on function award_waymarks(uuid, integer, text, text, uuid, text, text) from public;
revoke all on function award_waymarks(uuid, integer, text, text, uuid, text, text) from anon;
revoke all on function award_waymarks(uuid, integer, text, text, uuid, text, text) from authenticated;
grant execute on function award_waymarks(uuid, integer, text, text, uuid, text, text) to service_role;

-- The only award path exposed to players, and only for accounts the
-- developer has explicitly flipped dev_grants_enabled on for (a manual,
-- out-of-band step -- there's no way to tell "this is one of my test
-- accounts" apart from a real player's purely anonymous session
-- otherwise). Any other account calling this gets rejected regardless
-- of whether the client shows a button for it.
create or replace function dev_grant_waymarks(
  p_amount integer,
  p_description text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allowed boolean;
begin
  select dev_grants_enabled into v_allowed from profiles where id = auth.uid();
  if not coalesce(v_allowed, false) then
    raise exception 'this account is not allowlisted for developer Waymark grants';
  end if;

  return award_waymarks(auth.uid(), p_amount, 'admin', 'dev_grant', null, p_description, null);
end;
$$;

grant execute on function dev_grant_waymarks(integer, text) to authenticated;

-- Spends the calling wayfinder's OWN currency -- safe to expose broadly
-- since it can never draw down more than auth.uid() actually has, and it
-- always derives the account from the JWT rather than trusting a
-- supplied user_id. Consumes non-paid lots before paid ones, oldest lot
-- first within each tier (so a real-money purchase stays intact as long
-- as possible, both for player fairness and to keep it easier to refund
-- later), locking every candidate lot up front so a concurrent spend
-- can't race this one for the same currency.
create or replace function spend_waymarks(
  p_amount integer,
  p_context_type text,
  p_context_id uuid,
  p_description text,
  p_idempotency_key text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_operation_id uuid;
  v_remaining_to_spend integer := p_amount;
  v_lot record;
  v_take integer;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to spend Waymarks';
  end if;
  if p_amount <= 0 then
    raise exception 'spend amount must be positive';
  end if;

  if p_idempotency_key is not null then
    begin
      insert into wallet_operations (user_id, operation_type, total_amount, context_type, context_id, description, idempotency_key)
      values (v_user_id, 'spend', p_amount, p_context_type, p_context_id, p_description, p_idempotency_key)
      returning id into v_operation_id;
    exception when unique_violation then
      select id into v_operation_id from wallet_operations where idempotency_key = p_idempotency_key;
      return v_operation_id;
    end;
  else
    insert into wallet_operations (user_id, operation_type, total_amount, context_type, context_id, description)
    values (v_user_id, 'spend', p_amount, p_context_type, p_context_id, p_description)
    returning id into v_operation_id;
  end if;

  -- (source_type = 'paid') orders false before true, i.e. every
  -- non-paid lot before any paid one; created_at within that breaks ties
  -- oldest-first.
  for v_lot in
    select id, remaining_amount from currency_lots
    where user_id = v_user_id and remaining_amount > 0
    order by (source_type = 'paid'), created_at
    for update
  loop
    exit when v_remaining_to_spend <= 0;
    v_take := least(v_lot.remaining_amount, v_remaining_to_spend);

    update currency_lots set remaining_amount = remaining_amount - v_take where id = v_lot.id;
    insert into wallet_transactions (operation_id, currency_lot_id, amount) values (v_operation_id, v_lot.id, -v_take);

    v_remaining_to_spend := v_remaining_to_spend - v_take;
  end loop;

  -- Raising here rolls back the whole function call, including the
  -- wallet_operations insert and every deduction already applied in the
  -- loop above -- Postgres runs a plpgsql function body as part of the
  -- caller's transaction, so an unhandled exception undoes all of it.
  if v_remaining_to_spend > 0 then
    raise exception 'insufficient Waymark balance';
  end if;

  return v_operation_id;
end;
$$;

grant execute on function spend_waymarks(integer, text, uuid, text, text) to authenticated;

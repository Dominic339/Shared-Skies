-- Sends one of the caller's own held postcards to another wayfinder.
-- Wrapped in a single function rather than two raw client writes (update
-- postcards + insert postcard_mailings) purely for atomicity -- RLS
-- would technically permit the sender to do both directly, but a partial
-- failure between them would leave a postcard marked mailed with no
-- mailing record, or vice versa.
create or replace function mail_postcard(
  p_postcard_id uuid,
  p_recipient_id uuid,
  p_message_kind text,
  p_canned_message_key text,
  p_message_text text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender_id uuid := auth.uid();
  v_postcard record;
  v_freetext_enabled boolean;
  v_mailing_id uuid;
begin
  if v_sender_id is null then
    raise exception 'must be authenticated to mail a postcard';
  end if;
  if p_recipient_id = v_sender_id then
    raise exception 'cannot mail a postcard to yourself';
  end if;
  if not exists (select 1 from profiles where id = p_recipient_id) then
    raise exception 'recipient does not exist';
  end if;

  select * into v_postcard from postcards where id = p_postcard_id for update;
  if v_postcard.id is null then
    raise exception 'postcard not found';
  end if;
  -- IS DISTINCT FROM, not != -- a postcard already mailed away by
  -- someone else has holder_wayfinder_id null, and a plain != against
  -- NULL evaluates to NULL (neither true nor a clean rejection) instead
  -- of the definite "no, this isn't yours" this check needs.
  if v_postcard.holder_wayfinder_id is distinct from v_sender_id then
    raise exception 'you do not hold this postcard';
  end if;
  if v_postcard.status != 'held' then
    raise exception 'this postcard has already been mailed';
  end if;

  if p_message_kind = 'freetext' then
    select enabled into v_freetext_enabled from feature_flags where key = 'mail.freetext_enabled';
    if not coalesce(v_freetext_enabled, false) then
      raise exception 'free-text mail is not enabled yet';
    end if;
    if p_message_text is null or length(trim(p_message_text)) = 0 then
      raise exception 'message_text is required for a freetext message';
    end if;
  elsif p_message_kind = 'canned' then
    if p_canned_message_key is null then
      raise exception 'canned_message_key is required for a canned message';
    end if;
  else
    raise exception 'invalid message_kind: %', p_message_kind;
  end if;

  -- holder_wayfinder_id goes null (not to the recipient) -- the postcard
  -- is "in transit" until deliver_postcard() below actually hands it
  -- over; status stays 'mailed' permanently afterward even once
  -- delivered, since a postcard makes this trip exactly once (no
  -- re-mailing a card someone sent you further along).
  update postcards set status = 'mailed', holder_wayfinder_id = null where id = p_postcard_id;

  insert into postcard_mailings (
    postcard_id, sender_id, recipient_id, message_kind, canned_message_key, message_text
  ) values (
    p_postcard_id, v_sender_id, p_recipient_id, p_message_kind, p_canned_message_key, p_message_text
  ) returning id into v_mailing_id;

  return v_mailing_id;
end;
$$;

grant execute on function mail_postcard(uuid, uuid, text, text, text) to authenticated;

-- Marks a piece of mail delivered and hands the physical postcard over
-- to its recipient. Must be its own function, not a raw client update --
-- postcard_mailings_participant_rw's WITH CHECK only allows auth.uid() =
-- sender_id, so the recipient (the only one who should ever be able to
-- mark something delivered) cannot satisfy that policy directly.
-- Returns the delivered postcard's id rather than void -- a void-
-- returning function risks PostgREST replying with an empty/204
-- response that the client's generic RPC helper would misread as a
-- failure (it treats a null-parsed body the same as an error), same as
-- every other function in this session returning a concrete uuid.
create or replace function deliver_postcard(p_mailing_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_mailing record;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to collect mail';
  end if;

  select * into v_mailing from postcard_mailings where id = p_mailing_id for update;
  if v_mailing.id is null then
    raise exception 'mailing not found';
  end if;
  if v_mailing.recipient_id != v_user_id then
    raise exception 'this mail is not addressed to you';
  end if;
  if v_mailing.delivered_at is not null then
    raise exception 'already collected';
  end if;

  update postcard_mailings set delivered_at = now() where id = p_mailing_id;
  update postcards set holder_wayfinder_id = v_user_id where id = v_mailing.postcard_id;

  return v_mailing.postcard_id;
end;
$$;

grant execute on function deliver_postcard(uuid) to authenticated;

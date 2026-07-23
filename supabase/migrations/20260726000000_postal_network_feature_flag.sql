-- feature_flags was created with RLS never enabled at all -- not "no
-- policies" (which would deny everyone), but genuinely open, meaning the
-- normal anon/authenticated table grants applied with no row-level
-- restriction whatsoever. Since flags gate real behavior (mail.freetext
-- below, and whatever else uses this table later), any player could
-- currently read AND write every flag directly via PostgREST. Fixing
-- this now since Postal Network is the first real feature to depend on
-- a flag actually being trustworthy.
alter table feature_flags enable row level security;
create policy feature_flags_public_read on feature_flags
  for select using (true);
-- Deliberately no write policy for anon/authenticated -- flags should
-- only change via a migration or (later) the admin console's own
-- service-role access, never a client request.

insert into feature_flags (key, enabled, description) values (
  'mail.freetext_enabled',
  false,
  'Allows composing a free-text postcard message instead of only canned ones. Off by default -- moderation/reporting for player-authored text does not exist yet.'
)
on conflict (key) do nothing;

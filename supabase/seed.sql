-- Shared Skies — Seed data for local dev / fresh environments.
-- Applied automatically by `supabase db reset` after migrations run.

insert into regions (iso_code, name, short_name, country_code, launch_status) values
  ('US-MA', 'Massachusetts', 'The Bay State', 'US', 'seeded'),
  ('US-NH', 'New Hampshire', 'The Granite State', 'US', 'seeded'),
  ('US-ME', 'Maine', 'The Pine Tree State', 'US', 'seeded'),
  ('US-VT', 'Vermont', 'The Green Mountain State', 'US', 'seeded'),
  ('US-RI', 'Rhode Island', 'The Ocean State', 'US', 'seeded'),
  ('US-CT', 'Connecticut', 'The Constitution State', 'US', 'seeded');

-- Free-text player-to-player letters ship disabled at launch. Postcards and
-- canned messages ("Greetings from __", "Check out __") remain fully live —
-- this flag only gates postcard_mailings.message_kind = 'freetext'.
insert into feature_flags (key, enabled, description) values
  ('mail.freetext_enabled', false, 'Free-text letters/postcard messages between wayfinders. Disabled until there is a large enough player base to justify the moderation surface.'),
  ('mail.canned_messages_enabled', true, 'Pre-written postcard messages (e.g. "Greetings from __"). Safe to enable immediately — zero free-text abuse surface.');

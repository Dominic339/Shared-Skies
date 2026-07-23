-- Generic tunable settings, distinct from feature_flags (which is
-- specifically on/off switches) -- this is for numeric/text values that
-- need to change without a migration once the Operations Console
-- exists. Stored as text and cast by whatever reads it, since settings
-- won't all be the same type.
create table app_settings (
  key text primary key,
  value text not null,
  description text,
  updated_at timestamptz not null default now()
);
create trigger trg_app_settings_updated_at before update on app_settings
  for each row execute function set_updated_at();

alter table app_settings enable row level security;
create policy app_settings_public_read on app_settings
  for select using (true);
-- No write policy for anon/authenticated -- same reasoning as
-- feature_flags: only a migration or (later) the admin console's own
-- service-role access should ever change a setting.

insert into app_settings (key, value, description) values (
  'postcards.cooldown_minutes',
  '5',
  'Minimum minutes between self-collected postcards from the same Landmark for the same wayfinder. A testing value, not necessarily the launch value.'
)
on conflict (key) do nothing;

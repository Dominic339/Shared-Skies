-- visits (and every other player-owned table) reference profiles(id),
-- not auth.users(id) directly -- but nothing ever created a profiles
-- row when a user signs in, anonymous or otherwise. Every write to
-- visits/item_instances/postcards/etc. was failing its foreign key
-- silently until the first real write attempt actually surfaced it.
--
-- security definer is required: this fires on insert into auth.users
-- (owned by the supabase_auth_admin role), and needs elevated
-- privilege to insert into public.profiles on that role's behalf.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, 'New Wayfinder');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Backfill: any auth.users row created before this trigger existed
-- (e.g. the anonymous test user from earlier sessions) still needs a
-- matching profiles row, or it's stuck the same way.
insert into public.profiles (id, display_name)
select id, 'New Wayfinder'
from auth.users
where id not in (select id from public.profiles);

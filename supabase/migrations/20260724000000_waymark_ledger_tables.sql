-- Provenance-aware Waymark economy: a flat balance column can't answer
-- "which purchase funded this spend" after the fact, and that question
-- has to be answerable for refunds later -- there's no way to backfill
-- lot-level history onto transactions that already happened as a single
-- number. This gets the hard-to-retrofit part right before any bounty
-- or shop code starts calling into it.
--
-- payment_orders is a locked-down shell for now -- no real payment
-- provider is wired up yet (no Apple/Google product setup, no Edge
-- Functions in this project at all), so there is nothing to reference
-- with provider fields beyond a stable id to hang currency_lots off of.
-- Same "administration table, no policies" pattern as submission_tickets
-- -- only the service role can touch it, which is correct since only a
-- verified server-side purchase flow should ever write here.
create table payment_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  provider text,
  store_product_id text,
  provider_transaction_id text,
  status text not null default 'completed' check (status in ('completed', 'refunded', 'partially_refunded')),
  purchased_at timestamptz not null default now(),
  refunded_at timestamptz
);

-- One row per discrete inflow of currency -- an award mints a new lot
-- rather than adding to an existing one, since "how much of THIS
-- specific grant/purchase is left" is exactly the question a refund
-- needs answered later. source_type distinguishes real-money currency
-- (paid) from everything else (earned/promotional/admin), which is what
-- the spend-ordering rule and the gold/silver UI split both key off of.
create table currency_lots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  source_type text not null check (source_type in ('earned', 'promotional', 'admin', 'paid')),
  payment_order_id uuid references payment_orders (id) on delete set null,
  original_amount integer not null check (original_amount > 0),
  remaining_amount integer not null check (remaining_amount >= 0),
  created_at timestamptz not null default now()
);
create index currency_lots_spend_order_idx on currency_lots (user_id, created_at) where remaining_amount > 0;

-- The player-facing "thing that happened" -- one row per award or spend,
-- regardless of how many lots it touched. total_amount is always the
-- positive magnitude; direction comes from operation_type.
-- reversal_of_operation_id is unused today (no refund flow exists yet)
-- but is here now for the same reason payment_orders is: adding it after
-- real operations exist would mean retrofitting, adding it now costs
-- nothing.
create table wallet_operations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  operation_type text not null check (operation_type in ('award', 'spend', 'reversal')),
  total_amount integer not null check (total_amount > 0),
  context_type text,
  context_id uuid,
  description text,
  idempotency_key text,
  reversal_of_operation_id uuid references wallet_operations (id),
  created_at timestamptz not null default now()
);
-- Lets a retried request (e.g. after a dropped connection) recognize
-- "this already happened" and return the prior result instead of
-- awarding/spending twice -- only enforced when a caller actually
-- supplies a key, since not every operation needs one yet (ad-hoc dev
-- grants/spends have nothing meaningful to key on).
create unique index wallet_operations_idempotency_key_idx
  on wallet_operations (idempotency_key) where idempotency_key is not null;

-- Exact per-lot allocation for a single operation -- "this spend of 150
-- pulled 100 from earned lot A and 50 from paid lot B." This is what
-- makes a later refund tool able to trace real-money currency all the
-- way to what it was actually spent on, instead of just knowing a spend
-- happened.
create table wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null references wallet_operations (id) on delete cascade,
  currency_lot_id uuid not null references currency_lots (id) on delete cascade,
  amount integer not null check (amount != 0),
  created_at timestamptz not null default now()
);
create index wallet_transactions_operation_idx on wallet_transactions (operation_id);
create index wallet_transactions_lot_idx on wallet_transactions (currency_lot_id);

alter table payment_orders enable row level security;
alter table currency_lots enable row level security;
alter table wallet_operations enable row level security;
alter table wallet_transactions enable row level security;

-- payment_orders: deliberately no policies at all yet (see comment
-- above) -- nothing client-facing needs to read it before a real
-- purchase/refund flow exists.

-- currency_lots/wallet_operations/wallet_transactions: self-read only.
-- No insert/update/delete policies for anon/authenticated anywhere --
-- every mutation must go through award_waymarks()/spend_waymarks()/
-- dev_grant_waymarks() (security definer functions, added next
-- migration), never a raw table write from the client.
create policy currency_lots_self_read on currency_lots
  for select using (auth.uid() = user_id);
create policy wallet_operations_self_read on wallet_operations
  for select using (auth.uid() = user_id);
create policy wallet_transactions_self_read on wallet_transactions
  for select using (
    exists (
      select 1 from wallet_operations o
      where o.id = wallet_transactions.operation_id and o.user_id = auth.uid()
    )
  );

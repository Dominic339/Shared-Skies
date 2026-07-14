-- Persists every AI enrichment call, permanently -- prompt, evidence, and
-- response together, not just the final suggestion. Evidence gathering is
-- deterministic and worth keeping forever regardless of AI provider;
-- storing the response alongside it means a future model (or a fixed
-- prompt) can be compared against, or a batch can be regenerated, without
-- re-running the underlying evidence-gathering (Overpass/Wikidata/
-- Wikipedia calls) at all.
--
-- Justified now rather than deferred like other speculative schema
-- growth: this isn't a hypothetical future need, it's storing the actual
-- output of a system that already exists and already produced real
-- results against the live Nashua data.

create table enrichment_runs (
  id uuid primary key default gen_random_uuid(),
  entity_table text not null,
  entity_id uuid not null,
  provider text not null,       -- e.g. 'gemini'
  model text not null,          -- e.g. 'gemini-flash-latest' (resolved model version if known)
  prompt text not null,
  evidence jsonb not null,
  response jsonb,               -- null if the call failed outright
  confidence numeric(5, 2),
  error text,                   -- populated instead of response on failure
  created_at timestamptz not null default now()
);
create index enrichment_runs_entity_idx on enrichment_runs (entity_table, entity_id);

alter table enrichment_runs enable row level security;
-- No client-facing policy: same as the other administration tables, this
-- is written and read by importer/admin tooling via the service role only.

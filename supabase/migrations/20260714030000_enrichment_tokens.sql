-- Token usage, captured at call time -- can't be reconstructed later,
-- same reasoning as duration_ms. Needed now that API usage is billed:
-- this is what lets metrics.py report actual estimated cost instead of
-- just call counts.
alter table enrichment_runs add column input_tokens integer;
alter table enrichment_runs add column output_tokens integer;
alter table enrichment_runs add column thinking_tokens integer;

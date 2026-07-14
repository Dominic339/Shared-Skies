"""
Records every enrichment call permanently -- prompt, evidence, and
response together, win or lose. Evidence gathering (Overpass/Wikidata/
Wikipedia) is deterministic and worth keeping forever regardless of which
AI provider answered; storing the response alongside it means a future
model or an improved prompt can be compared or batch-regenerated without
re-running the underlying evidence gathering at all.
"""

from typing import Any


def record_enrichment_run(
    client,
    entity_id: str,
    provider_name: str,
    model: str,
    prompt: str,
    evidence: dict,
    response: dict | None,
    confidence: float | None,
    error: str | None = None,
    entity_table: str = "landmarks",
) -> None:
    client.table("enrichment_runs").insert(
        {
            "entity_table": entity_table,
            "entity_id": entity_id,
            "provider": provider_name,
            "model": model,
            "prompt": prompt,
            "evidence": evidence,
            "response": response,
            "confidence": confidence,
            "error": error,
        }
    ).execute()

"""
Preflight health check -- run this before an import/enrichment session,
not after something breaks. Directly motivated by today: schema drift
(twice), an exhausted API quota, and a degraded model all had to be
diagnosed by hand, one at a time, mid-batch. Every one of those would
have been caught here in five seconds.

Usage:
    python -m osm_importer.validate_pipeline
"""

import os
import sys


def check(label: str, fn) -> bool:
    try:
        detail = fn()
        print(f"  [ok] {label}" + (f" -- {detail}" if detail else ""))
        return True
    except Exception as e:
        print(f"  [FAIL] {label} -- {e}")
        return False


def check_env_vars() -> str | None:
    missing = [v for v in ("SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY") if not os.environ.get(v)]
    if missing:
        raise RuntimeError(f"missing env var(s): {', '.join(missing)}")
    return None


def check_curl() -> str:
    import subprocess

    result = subprocess.run(["curl", "--version"], capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        raise RuntimeError("curl not found or not runnable -- fetch_osm.py requires it")
    return result.stdout.splitlines()[0]


def check_supabase_connectivity() -> str:
    from .supabase_writer import get_client

    client = get_client()
    client.table("regions").select("id").limit(1).execute()
    return "connected"


def check_expected_tables() -> str:
    from .supabase_writer import get_client

    client = get_client()
    tables = [
        "regions", "communities", "landmarks", "landmark_sources", "spawn_rules",
        "item_definitions", "asset_variants", "content_packs", "pack_contents",
        "submission_tickets", "submission_images", "duplicate_candidates",
        "moderation_actions", "audit_log", "content_notes", "feature_flags",
        "enrichment_runs",
    ]
    for t in tables:
        client.table(t).select("*").limit(1).execute()  # raises if the table doesn't exist
    return f"{len(tables)} tables present"


def check_enrichment_runs_columns() -> str:
    from .supabase_writer import get_client

    client = get_client()
    columns = [
        "entity_table", "entity_id", "provider", "model", "prompt", "evidence",
        "response", "confidence", "error", "duration_ms",
        "input_tokens", "output_tokens", "thinking_tokens",
    ]
    client.table("enrichment_runs").select(",".join(columns)).limit(1).execute()
    return f"{len(columns)} columns present (incl. token tracking)"


def check_gemini_api_key() -> str:
    if not os.environ.get("GEMINI_API_KEY"):
        raise RuntimeError("GEMINI_API_KEY not set (only needed for enrichment, not plain import)")
    return "set"


def check_gemini_connectivity() -> str:
    import requests

    from .enrichment.providers.gemini import GeminiProvider

    api_key = os.environ["GEMINI_API_KEY"]
    provider = GeminiProvider()
    response = requests.post(
        f"{provider._api_url(provider.MODEL_ALIAS)}?key={api_key}",
        headers={"Content-Type": "application/json"},
        json={"contents": [{"parts": [{"text": "Reply with exactly: OK"}]}]},
        timeout=15,
    )
    if response.status_code == 429:
        raise RuntimeError("quota exceeded on primary model right now -- fallback model will be used automatically")
    if response.status_code == 503:
        raise RuntimeError("primary model temporarily overloaded -- fallback model will be used automatically")
    response.raise_for_status()
    model_version = response.json().get("modelVersion", provider.MODEL_ALIAS)
    return f"responding ({model_version})"


def main() -> int:
    print("Shared Skies importer -- pipeline validation\n")

    print("Core (required for any import):")
    core_ok = all([
        check("Required environment variables set", check_env_vars),
        check("curl available (Overpass fetch depends on it)", check_curl),
        check("Supabase connectivity", check_supabase_connectivity),
        check("Expected tables present", check_expected_tables),
        check("enrichment_runs has token-tracking columns", check_enrichment_runs_columns),
    ])

    print("\nEnrichment (only needed if running the AI classification pass):")
    if os.environ.get("GEMINI_API_KEY"):
        check("GEMINI_API_KEY set", check_gemini_api_key)
        check("Gemini API connectivity", check_gemini_connectivity)
    else:
        print("  [skip] GEMINI_API_KEY not set -- skipping enrichment checks (fine if you're only importing)")

    print()
    if core_ok:
        print("Core checks passed -- safe to run the importer.")
        return 0
    else:
        print("One or more core checks failed -- fix before running a real import.")
        return 1


if __name__ == "__main__":
    sys.exit(main())

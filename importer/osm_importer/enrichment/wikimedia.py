"""
Direct lookups against Wikidata's and Wikipedia's public REST APIs, when
an OSM object already carries a `wikidata` or `wikipedia` tag. This is
strictly better than asking an LLM to guess: when a stable external
identifier exists, pulling the real structured record is a lookup, not
an inference.

Wikimedia's API etiquette policy requires a descriptive User-Agent
identifying the application (and rejects generic/default ones, e.g.
plain python-requests) -- this isn't optional or a workaround, it's
their documented requirement.
"""

import requests

USER_AGENT = "SharedSkiesImporter/0.1 (game data enrichment; contact via project owner)"
HEADERS = {"User-Agent": USER_AGENT}


def fetch_wikidata_entity(qid: str, timeout: int = 15) -> dict | None:
    """Returns {"label": ..., "description": ...} in English, or None if
    the entity doesn't exist / has no English label."""
    url = f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"
    response = requests.get(url, headers=HEADERS, timeout=timeout)
    if response.status_code != 200:
        return None
    entity = response.json().get("entities", {}).get(qid)
    if not entity:
        return None
    label = entity.get("labels", {}).get("en", {}).get("value")
    description = entity.get("descriptions", {}).get("en", {}).get("value")
    if not label:
        return None
    return {"label": label, "description": description, "qid": qid}


def fetch_wikipedia_summary(wikipedia_tag: str, timeout: int = 15) -> dict | None:
    """wikipedia_tag is OSM's "lang:Page Title" format, e.g.
    "en:Nashville Historic District (Nashua, New Hampshire)". Returns
    {"title": ..., "extract": ..., "url": ...} or None."""
    if ":" not in wikipedia_tag:
        return None
    lang, title = wikipedia_tag.split(":", 1)
    encoded_title = requests.utils.quote(title.replace(" ", "_"))
    url = f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{encoded_title}"
    response = requests.get(url, headers=HEADERS, timeout=timeout)
    if response.status_code != 200:
        return None
    data = response.json()
    extract = data.get("extract")
    if not extract:
        return None
    return {
        "title": data.get("title", title),
        "extract": extract,
        "url": data.get("content_urls", {}).get("desktop", {}).get("page"),
    }

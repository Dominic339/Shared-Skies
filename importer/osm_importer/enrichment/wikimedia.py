"""
Direct lookups against Wikidata's, Wikipedia's, and Wikimedia Commons'
public REST/API endpoints, when an OSM object already carries a
`wikidata`/`wikipedia`/`wikimedia_commons`/`image` tag. This is strictly
better than asking an LLM to guess: when a stable external identifier
exists, pulling the real structured record (including image + license)
is a lookup, not an inference.

Wikimedia's API etiquette policy requires a descriptive User-Agent
identifying the application (and rejects generic/default ones, e.g.
plain python-requests) -- this isn't optional or a workaround, it's
their documented requirement.
"""

import requests

USER_AGENT = "SharedSkiesImporter/0.1 (game data enrichment; contact via project owner)"
HEADERS = {"User-Agent": USER_AGENT}


def fetch_wikidata_entity(qid: str, timeout: int = 15) -> dict | None:
    """Returns {"label": ..., "description": ..., "image_filename": ...}
    in English, or None if the entity doesn't exist / has no English label.
    image_filename (from claim P18) is the bare Commons filename, no
    "File:" prefix -- resolve it with fetch_commons_file_info()."""
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

    image_filename = None
    p18 = entity.get("claims", {}).get("P18")
    if p18:
        image_filename = p18[0].get("mainsnak", {}).get("datavalue", {}).get("value")

    return {"label": label, "description": description, "qid": qid, "image_filename": image_filename}


def fetch_wikipedia_summary(wikipedia_tag: str, timeout: int = 15) -> dict | None:
    """wikipedia_tag is OSM's "lang:Page Title" format, e.g.
    "en:Nashville Historic District (Nashua, New Hampshire)". Returns
    {"title": ..., "extract": ..., "url": ..., "thumbnail_url": ...,
    "original_image_url": ...} or None. The image fields are None if the
    page has no lead image."""
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
        "thumbnail_url": data.get("thumbnail", {}).get("source"),
        "original_image_url": data.get("originalimage", {}).get("source"),
    }


def commons_filename_from_url(url: str) -> str | None:
    """Extract the bare filename from an upload.wikimedia.org URL
    (handles both direct and /thumb/.../<width>px-<name> variants)."""
    if "upload.wikimedia.org" not in url:
        return None
    parts = url.rstrip("/").split("/")
    filename = parts[-1]
    # thumb URLs end in "<width>px-<original filename>"
    if "px-" in filename and "/thumb/" in url:
        filename = filename.split("px-", 1)[1]
    return requests.utils.unquote(filename)


def fetch_commons_file_info(filename: str, timeout: int = 15) -> dict | None:
    """filename is a bare Commons filename (no "File:" prefix, spaces or
    underscores both fine). Returns {"url", "license", "attribution_text",
    "source_page_url"} or None if the file doesn't exist."""
    response = requests.get(
        "https://commons.wikimedia.org/w/api.php",
        params={
            "action": "query",
            "titles": f"File:{filename}",
            "prop": "imageinfo",
            "iiprop": "url|extmetadata",
            "format": "json",
        },
        headers=HEADERS,
        timeout=timeout,
    )
    if response.status_code != 200:
        return None
    pages = response.json().get("query", {}).get("pages", {})
    page = next(iter(pages.values()), {})
    imageinfo = page.get("imageinfo")
    if not imageinfo:
        return None
    info = imageinfo[0]
    meta = info.get("extmetadata", {})
    artist_html = meta.get("Artist", {}).get("value")
    return {
        "url": info["url"],
        "license": meta.get("LicenseShortName", {}).get("value"),
        "attribution_text": artist_html,  # HTML from Commons -- strip tags before display in the game itself
        "source_page_url": f"https://commons.wikimedia.org/wiki/File:{requests.utils.quote(filename)}",
    }


def fetch_commons_category_first_file(category_title: str, timeout: int = 15) -> str | None:
    """category_title without "Category:" prefix. Returns the bare
    filename of the first file member, or None if the category is empty
    or doesn't exist. "First" per Commons' own default ordering -- not a
    quality judgment, just a starting point for a minimal harvest pass."""
    response = requests.get(
        "https://commons.wikimedia.org/w/api.php",
        params={
            "action": "query",
            "list": "categorymembers",
            "cmtitle": f"Category:{category_title}",
            "cmtype": "file",
            "cmlimit": "1",
            "format": "json",
        },
        headers=HEADERS,
        timeout=timeout,
    )
    if response.status_code != 200:
        return None
    members = response.json().get("query", {}).get("categorymembers", [])
    if not members:
        return None
    title = members[0]["title"]  # "File:X.jpg"
    return title.split(":", 1)[1] if ":" in title else title

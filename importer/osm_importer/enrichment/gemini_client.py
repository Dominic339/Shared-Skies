"""
Thin wrapper around the Gemini API's generateContent endpoint, used only
as a synthesis step over evidence this pipeline already collected --
never as the original source of a name, description, or history. See
enrich.py's prompt for the actual constraint text sent to the model.

Uses "gemini-flash-latest" (an alias Google keeps pointed at their
current recommended flash model) rather than a pinned version name, since
pinned preview/dated model names get deprecated for new API keys
relatively quickly -- confirmed directly: "gemini-2.5-flash" 404'd as
"no longer available to new users" the first time this was tested.
"""

import json
import os

import requests

MODEL = "gemini-flash-latest"
API_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"


def generate_json(prompt: str, timeout: int = 30) -> dict:
    """Sends prompt, requests a JSON response, and returns it parsed.
    Raises if the API call fails or the response isn't valid JSON --
    callers should treat that as "could not enrich this record", not
    silently substitute a guess."""
    api_key = os.environ["GEMINI_API_KEY"]
    response = requests.post(
        f"{API_URL}?key={api_key}",
        headers={"Content-Type": "application/json"},
        json={
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json"},
        },
        timeout=timeout,
    )
    response.raise_for_status()
    data = response.json()
    text = data["candidates"][0]["content"]["parts"][0]["text"]
    return json.loads(text)

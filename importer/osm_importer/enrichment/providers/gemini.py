"""
Gemini implementation of EnrichmentProvider, using the free tier
(gemini-flash-latest -- an alias Google keeps pointed at their current
recommended flash model, rather than a pinned version name; confirmed
directly that a pinned name ("gemini-2.5-flash") was already deprecated
for new API keys during testing).
"""

import json
import os

import requests

from .base import EnrichmentProvider


class GeminiProvider(EnrichmentProvider):
    name = "gemini"
    MODEL_ALIAS = "gemini-flash-latest"

    def __init__(self):
        self.api_url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.MODEL_ALIAS}:generateContent"

    def classify(self, prompt: str, timeout: int = 30) -> tuple[dict, str]:
        api_key = os.environ["GEMINI_API_KEY"]
        response = requests.post(
            f"{self.api_url}?key={api_key}",
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
        resolved_model = data.get("modelVersion", self.MODEL_ALIAS)
        return json.loads(text), resolved_model

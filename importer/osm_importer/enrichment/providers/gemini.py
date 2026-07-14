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

    def _call(self, prompt: str, timeout: int) -> tuple[str, str]:
        api_key = os.environ["GEMINI_API_KEY"]
        response = requests.post(
            f"{self.api_url}?key={api_key}",
            headers={"Content-Type": "application/json"},
            json={
                "contents": [{"parts": [{"text": prompt}]}],
                "generationConfig": {
                    "responseMimeType": "application/json",
                    # Low, not zero: this is a classification task, not creative
                    # writing, and a lower temperature both reduces the chance of
                    # malformed/trailing-content responses (observed directly --
                    # a JSON-parse failure did not reproduce on retry with the
                    # exact same prompt) and better matches "the AI should feel
                    # pressure to be correct, not to answer."
                    "temperature": 0.2,
                },
            },
            timeout=timeout,
        )
        response.raise_for_status()
        data = response.json()
        text = data["candidates"][0]["content"]["parts"][0]["text"]
        resolved_model = data.get("modelVersion", self.MODEL_ALIAS)
        return text, resolved_model

    def classify(self, prompt: str, timeout: int = 30) -> tuple[dict, str]:
        last_error: Exception | None = None
        for attempt in range(2):  # one retry: cheap, and malformed JSON has been observed not to reproduce
            text, resolved_model = self._call(prompt, timeout)
            try:
                return json.loads(text), resolved_model
            except json.JSONDecodeError as e:
                last_error = e
        raise last_error

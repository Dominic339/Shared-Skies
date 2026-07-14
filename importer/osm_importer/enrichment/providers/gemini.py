"""
Gemini implementation of EnrichmentProvider, using the free tier
(gemini-flash-latest -- an alias Google keeps pointed at their current
recommended flash model, rather than a pinned version name; confirmed
directly that a pinned name ("gemini-2.5-flash") was already deprecated
for new API keys during testing).
"""

import json
import os
import time

import requests

from .base import EnrichmentProvider, Usage


class GeminiProvider(EnrichmentProvider):
    name = "gemini"
    MODEL_ALIAS = "gemini-flash-latest"

    def __init__(self, disable_thinking: bool = True):
        self.api_url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.MODEL_ALIAS}:generateContent"
        # This is a bounded classification task, not multi-step reasoning --
        # extended "thinking" tokens showed up as a real cost factor in
        # testing (97 tokens of thinking for a one-word reply) without an
        # apparent quality need for this task. Toggle-able in case output
        # quality turns out to depend on it after all.
        self.disable_thinking = disable_thinking

    def _call(self, prompt: str, timeout: int) -> tuple[str, str, Usage]:
        api_key = os.environ["GEMINI_API_KEY"]
        generation_config = {
            "responseMimeType": "application/json",
            "temperature": 0.2,
        }
        if self.disable_thinking:
            generation_config["thinkingConfig"] = {"thinkingBudget": 0}

        response = requests.post(
            f"{self.api_url}?key={api_key}",
            headers={"Content-Type": "application/json"},
            json={"contents": [{"parts": [{"text": prompt}]}], "generationConfig": generation_config},
            timeout=timeout,
        )
        response.raise_for_status()
        data = response.json()
        text = data["candidates"][0]["content"]["parts"][0]["text"]
        resolved_model = data.get("modelVersion", self.MODEL_ALIAS)

        usage_meta = data.get("usageMetadata", {})
        usage = Usage(
            input_tokens=usage_meta.get("promptTokenCount"),
            output_tokens=usage_meta.get("candidatesTokenCount"),
            thinking_tokens=usage_meta.get("thoughtsTokenCount"),
        )
        return text, resolved_model, usage

    def classify(self, prompt: str, timeout: int = 30) -> tuple[dict, str, Usage]:
        last_error: Exception | None = None
        for attempt in range(3):
            try:
                text, resolved_model, usage = self._call(prompt, timeout)
            except requests.exceptions.HTTPError as e:
                # 503 is Google's own "usually temporary, try again" signal --
                # observed directly (recurred across several attempts today).
                # 429 (quota) is a different problem retrying won't fix, so
                # it's deliberately not caught here and propagates immediately.
                if e.response is not None and e.response.status_code == 503 and attempt < 2:
                    last_error = e
                    time.sleep(5 * (attempt + 1))
                    continue
                raise
            try:
                return json.loads(text), resolved_model, usage
            except json.JSONDecodeError as e:
                # Also retry malformed JSON once -- confirmed earlier not to
                # reproduce on an identical retry.
                last_error = e
        raise last_error

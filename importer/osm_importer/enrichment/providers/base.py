"""
The whole point of this interface: enrich.py should never know which LLM
answered its prompt. Swapping providers (Gemini -> Claude -> OpenAI ->
whatever exists in three years) should be a one-line change at the call
site, not a rewrite of the importer.
"""

from abc import ABC, abstractmethod


class EnrichmentProvider(ABC):
    name: str

    @abstractmethod
    def classify(self, prompt: str, timeout: int = 30) -> tuple[dict, str]:
        """Send prompt, return (parsed_json_response, resolved_model_version).
        The resolved model version should be the actual model that answered
        (e.g. Gemini's response includes this even when you called an alias
        like "gemini-flash-latest") -- that's what makes a stored response
        comparable later, not just "some Gemini call happened at some point."
        """
        ...

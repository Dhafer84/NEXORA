from app.ai.base import AIProvider
from app.ai.openai_compatible import OpenAICompatibleProvider
from app.ai.simulated import SimulatedProvider
from app.config import Settings


def build_provider(settings: Settings) -> AIProvider | None:
    if settings.nexora_ai_provider == "openai_compatible":
        return OpenAICompatibleProvider(settings)
    if settings.nexora_ai_provider == "simulated":
        return SimulatedProvider()
    return None

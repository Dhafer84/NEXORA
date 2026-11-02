import json
import logging

import httpx
import pytest
from app.ai.base import ProviderError
from app.ai.openai_compatible import OpenAICompatibleProvider
from app.config import Settings
from conftest import KEY, PASSWORD
from pydantic import ValidationError

AI_KEY = "nvapi-" + "z9" * 30


def make(tmp_path, handler, key: str | None = AI_KEY):
    key_file = tmp_path / "ai_api_key"
    if key is not None:
        key_file.write_text(key + "\n")
        key_file.chmod(0o600)
    settings = Settings(
        nexora_api_key=KEY,
        postgres_password=PASSWORD,
        nexora_ai_provider="openai_compatible",
        nexora_ai_api_key_file=str(key_file),
    )
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return OpenAICompatibleProvider(settings, client)


def reply(message):
    return httpx.Response(200, json={"choices": [{"message": message}]})


def test_request_format_and_tool_call_parsing(tmp_path):
    seen = {}

    def handler(request):
        seen["auth"] = request.headers["authorization"]
        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        return reply(
            {
                "content": None,
                "tool_calls": [
                    {
                        "id": "c1",
                        "type": "function",
                        "function": {"name": "server_metrics", "arguments": "{}"},
                    }
                ],
            }
        )

    provider = make(tmp_path, handler)
    tools = [{"type": "function", "function": {"name": "server_metrics", "parameters": {}}}]
    result = provider.complete([{"role": "user", "content": "CPU ?"}], tools, timeout=5)
    assert seen["auth"] == f"Bearer {AI_KEY}"
    assert seen["url"] == "https://integrate.api.nvidia.com/v1/chat/completions"
    assert seen["body"]["model"] == "nvidia/nemotron-3-ultra-550b-a55b"
    assert seen["body"]["tools"] == tools
    assert result.text == ""
    assert result.tool_calls[0].name == "server_metrics"


@pytest.mark.parametrize(
    ("response", "code"),
    [
        (httpx.Response(401, text=f"bad key {AI_KEY}"), "auth"),
        (httpx.Response(429, text="slow down"), "rate_limited"),
        (httpx.Response(503, text=f"upstream {AI_KEY}"), "unavailable"),
        (httpx.Response(400, text=f"echo {AI_KEY}"), "rejected"),
        (httpx.Response(200, text="not json"), "bad_response"),
        (httpx.Response(200, json={"choices": []}), "bad_response"),
    ],
)
def test_provider_errors_never_expose_the_key(tmp_path, caplog, response, code):
    provider = make(tmp_path, lambda request: response)
    with caplog.at_level(logging.DEBUG), pytest.raises(ProviderError) as error:
        provider.complete([{"role": "user", "content": "x"}], [], timeout=5)
    assert error.value.code == code
    assert AI_KEY not in error.value.message + str(error.value) + caplog.text


@pytest.mark.parametrize(
    ("exception", "code"),
    [(httpx.ReadTimeout("t"), "timeout"), (httpx.ConnectError("refused"), "unavailable")],
)
def test_network_failures(tmp_path, exception, code):
    def handler(request):
        raise exception

    with pytest.raises(ProviderError) as error:
        make(tmp_path, handler).complete([], [], timeout=1)
    assert error.value.code == code


def test_missing_key_file_means_not_configured(tmp_path):
    provider = make(tmp_path, lambda request: pytest.fail("No request without a key"), key=None)
    assert not provider.configured()
    with pytest.raises(ProviderError) as error:
        provider.complete([], [], timeout=1)
    assert error.value.code == "not_configured"


@pytest.mark.parametrize(
    "url", ["http://api.example.com/v1", "https://user:pw@api.example.com", "ftp://x"]
)
def test_provider_url_must_be_https_without_credentials(url):
    with pytest.raises(ValidationError):
        Settings(nexora_api_key=KEY, postgres_password=PASSWORD, nexora_ai_base_url=url)


def test_provider_timeout_is_a_total_cap(tmp_path):
    import time

    def slow(request):
        time.sleep(1.5)
        return reply({"content": "trop tard"})

    provider = make(tmp_path, slow)
    started = time.monotonic()
    with pytest.raises(ProviderError) as error:
        provider.complete([{"role": "user", "content": "x"}], [], timeout=0.4)
    assert error.value.code == "timeout"
    assert time.monotonic() - started < 0.8


def test_oversize_provider_response_is_refused(tmp_path):
    big = httpx.Response(200, content=b"x" * 1_100_000)
    with pytest.raises(ProviderError) as error:
        make(tmp_path, lambda request: big).complete([], [], timeout=5)
    assert error.value.code == "bad_response"

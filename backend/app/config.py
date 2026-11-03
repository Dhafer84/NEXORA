import re
from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

GITHUB_REPO = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", hide_input_in_errors=True)

    nexora_api_key: SecretStr
    postgres_password: SecretStr
    postgres_host: str = "db"
    postgres_port: int = Field(default=5432, ge=1, le=65535)
    postgres_user: str = "nexora"
    postgres_db: str = "nexora"
    nexora_metrics_scope: Literal["runtime", "host"] = "runtime"
    nexora_procfs_path: str = "/proc"
    nexora_disk_path: str = "/"

    # Permissions granted to the personal key, comma separated.
    nexora_permissions: str = (
        "server:read,database:read,test:execute,automation:read,automation:write,"
        "notifications:read,github:read"
    )
    nexora_approval_ttl_seconds: int = Field(default=600, ge=30, le=86400)
    nexora_max_request_bytes: int = Field(default=32768, ge=1024, le=1048576)

    # Automation scheduler: one thread in the backend process, independent of the AI.
    nexora_scheduler_enabled: bool = True
    nexora_scheduler_poll_seconds: float = Field(default=20, ge=1, le=300)

    # Read-only GitHub reports: allow-list "owner/name,owner/name" (empty = off).
    # Optional token file (fine-grained, read-only) for private repositories.
    nexora_github_repos: str = ""
    nexora_github_token_file: str = "/run/secrets/github_token"

    # "none" keeps the assistant disabled; "simulated" is a test double, never a real AI.
    nexora_ai_provider: Literal["none", "simulated", "openai_compatible"] = "none"
    nexora_ai_base_url: str = "https://integrate.api.nvidia.com/v1"
    nexora_ai_model: str = Field(default="nvidia/nemotron-3-ultra-550b-a55b", min_length=1)
    nexora_ai_api_key_file: str = "/run/secrets/ai_api_key"
    nexora_ai_timeout_seconds: float = Field(default=30, gt=0, le=120)
    nexora_ai_turn_deadline_seconds: float = Field(default=90, gt=0, le=300)
    nexora_ai_max_tool_calls: int = Field(default=4, ge=0, le=10)
    nexora_ai_max_iterations: int = Field(default=5, ge=1, le=10)
    nexora_ai_max_input_chars: int = Field(default=4000, ge=100, le=20000)
    nexora_ai_max_output_tokens: int = Field(default=1024, ge=64, le=8192)
    nexora_ai_history_messages: int = Field(default=20, ge=1, le=100)

    @field_validator("nexora_api_key", "postgres_password")
    @classmethod
    def validate_secret(cls, value: SecretStr) -> SecretStr:
        raw = value.get_secret_value()
        if (
            len(raw) < 32
            or not raw.isascii()
            or any(char.isspace() for char in raw)
            or raw.lower().startswith(("change", "replace", "example"))
        ):
            raise ValueError("Un secret ASCII sans espaces d’au moins 32 caractères est requis")
        return value

    @field_validator("nexora_ai_base_url")
    @classmethod
    def validate_base_url(cls, value: str) -> str:
        url = urlsplit(value)
        local = url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}
        if (url.scheme != "https" and not local) or url.username or url.password or url.query:
            raise ValueError("URL du fournisseur IA : HTTPS sans identifiants requis")
        return value.rstrip("/")

    @field_validator("nexora_github_repos")
    @classmethod
    def validate_github_repos(cls, value: str) -> str:
        repos = [item.strip() for item in value.split(",") if item.strip()]
        if len(repos) > 10 or any(not GITHUB_REPO.match(repo) for repo in repos):
            raise ValueError("NEXORA_GITHUB_REPOS : 10 dépôts « propriétaire/nom » au plus")
        return ",".join(repos)

    @property
    def github_repos(self) -> list[str]:
        return [repo for repo in self.nexora_github_repos.split(",") if repo]

    @property
    def permissions(self) -> frozenset[str]:
        items = (item.strip() for item in self.nexora_permissions.split(","))
        return frozenset(item for item in items if item)

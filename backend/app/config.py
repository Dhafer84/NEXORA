from typing import Literal

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


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

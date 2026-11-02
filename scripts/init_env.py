"""Create local configuration without printing secrets or replacing an existing file."""

import os
import secrets
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / ".env"
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit(".env existe déjà : aucune modification effectuée.") from None
with os.fdopen(fd, "w") as stream:
    stream.write(
        f"NEXORA_API_KEY={secrets.token_hex(32)}\n"
        f"POSTGRES_PASSWORD={secrets.token_hex(32)}\n"
        "NEXORA_HTTP_PORT=8100\n"
    )
(root / ".runtime" / "host-disk").mkdir(parents=True, exist_ok=True)
print("Configuration créée dans .env (permissions 600). Aucun secret affiché.")

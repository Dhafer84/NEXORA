"""Probe a local or HTTPS deployment; credentials never enter command arguments."""

import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[1]
base = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8100").rstrip("/")
url = urlsplit(base)
if url.username or url.password or url.query or url.fragment or url.path:
    raise SystemExit("Utiliser une URL de base sans chemin ni identifiants.")
if url.scheme != "https" and not (
    url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}
):
    raise SystemExit("HTTPS obligatoire hors boucle locale.")
key = os.environ.get("NEXORA_API_KEY")
if not key:
    for line in (root / ".env").read_text().splitlines():
        if line.startswith("NEXORA_API_KEY="):
            key = line.split("=", 1)[1]
if not key:
    raise SystemExit("Clé locale absente.")
with urlopen(base + "/health/live", timeout=10) as response:
    assert response.status == 200
try:
    urlopen(base + "/api/v1/server/metrics", timeout=10)
except HTTPError as error:
    assert error.code == 401, f"Code inattendu : {error.code}"
else:
    raise SystemExit("ÉCHEC : les métriques ne sont pas protégées.")
for path in ("/health/ready", "/api/v1/auth/check", "/api/v1/server/metrics"):
    request = Request(base + path, headers={"Authorization": f"Bearer {key}"})
    with urlopen(request, timeout=10) as response:
        payload = json.load(response)
        assert response.status == 200
        print(path, json.dumps(payload))
print("Vérifications réussies : accès protégé, PostgreSQL disponible, métriques lisibles.")

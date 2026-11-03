"""Probe a local or HTTPS deployment; credentials never enter command arguments.

Usage: python3 scripts/check_api.py [BASE_URL] [--parcours] [--automatisation]
--parcours also runs a tool, an approval cycle and, when configured, an AI message.
It writes a test conversation and a harmless test approval into the database.
--automatisation creates a suspended disk check with a 1 % test threshold, runs it
by hand (alert + notification, seen by phones with alerts on), then deletes it.
"""

import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[1]
args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
full = "--parcours" in sys.argv[1:]
automation = "--automatisation" in sys.argv[1:]
base = (args[0] if args else "http://127.0.0.1:8100").rstrip("/")
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


def call(method: str, path: str, body: dict | None = None, expected: int = 200) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    request = Request(base + path, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=120) as response:
            raw = response.read()
            status, payload = response.status, json.loads(raw) if raw else {}
    except HTTPError as error:
        status, payload = error.code, (json.load(error) if error.code != 204 else {})
    assert status == expected, f"{method} {path} : HTTP {status} au lieu de {expected}"
    return payload


with urlopen(base + "/health/live", timeout=10) as response:
    assert response.status == 200
try:
    urlopen(base + "/api/v1/server/metrics", timeout=10)
except HTTPError as error:
    assert error.code == 401, f"Code inattendu : {error.code}"
else:
    raise SystemExit("ÉCHEC : les métriques ne sont pas protégées.")
for path in ("/health/ready", "/api/v1/auth/check", "/api/v1/server/metrics"):
    print(path, json.dumps(call("GET", path)))
tools = call("GET", "/api/v1/tools")
print("/api/v1/tools", [tool["name"] for tool in tools])
ai = call("GET", "/api/v1/ai/status")
print("/api/v1/ai/status", json.dumps(ai, ensure_ascii=False))
print("Vérifications réussies : accès protégé, PostgreSQL disponible, métriques lisibles.")

if full:
    run = call("POST", "/api/v1/tools/database_status/invoke", {})
    assert run["status"] == "succeeded" and run["result"]["available"], run
    print("Outil database_status :", json.dumps(run["result"]))
    call("POST", "/api/v1/tools/run_shell/invoke", {}, expected=404)
    arguments = {"label": "verification deploiement", "value": 1}
    pending = call("POST", "/api/v1/tools/test_action/invoke", {"arguments": arguments}, 202)
    approval = pending["approval"]
    call("POST", f"/api/v1/approvals/{approval['id']}/execute", {"arguments": arguments}, 409)
    call(
        "POST",
        f"/api/v1/approvals/{approval['id']}/approve",
        {"arguments_hash": approval["arguments_hash"]},
    )
    changed = {"label": "verification deploiement", "value": 2}
    call("POST", f"/api/v1/approvals/{approval['id']}/execute", {"arguments": changed}, 409)
    done = call("POST", f"/api/v1/approvals/{approval['id']}/execute", {"arguments": arguments})
    again = call("POST", f"/api/v1/approvals/{approval['id']}/execute", {"arguments": arguments})
    assert done["status"] == "succeeded" and again["replayed"], (done, again)
    assert again["execution_id"] == done["execution_id"]
    print("Validation : refus avant approbation, paramètres modifiés refusés, exécution unique.")
    conversation = call("POST", "/api/v1/conversations", {"title": "Vérification"}, 201)
    if ai["configured"]:
        turn = call(
            "POST",
            f"/api/v1/conversations/{conversation['id']}/messages",
            {"content": "Quelle est l’utilisation actuelle du processeur et de la mémoire ?"},
        )
        print("Fournisseur :", json.dumps(turn["provider"]), "— statut :", turn["status"])
        print("Outils appelés :", [e["tool"] for e in turn["tool_executions"]])
        print("Réponse :", turn["messages"][-1]["content"])
    else:
        message = {"content": "Bonjour"}
        call("POST", f"/api/v1/conversations/{conversation['id']}/messages", message, 503)
        print("Conversation créée ; fournisseur IA non configuré : réponse 503 attendue.")
    history = call("GET", f"/api/v1/conversations/{conversation['id']}")
    print("Historique :", len(history["messages"]), "message(s)")
    print("Parcours complet réussi.")

if automation:
    body = {
        "name": "Essai de déploiement",
        "threshold_percent": 1,
        "interval_minutes": 60,
        "timezone": "Europe/Paris",
        "enabled": False,
    }
    task = call("POST", "/api/v1/automations", body, 201)
    before = call("GET", "/api/v1/notifications?limit=1")["latest_id"]
    run = call("POST", f"/api/v1/automations/{task['id']}/run")
    assert run["status"] == "alert" and run["notified"], run
    again = call("POST", f"/api/v1/automations/{task['id']}/run")
    assert again["status"] == "alert" and not again["notified"], again
    page = call("GET", f"/api/v1/notifications?after_id={before}")
    assert [item["level"] for item in page["items"]] == ["alert"], page
    assert len(call("GET", f"/api/v1/automations/{task['id']}/runs")) == 2
    call("DELETE", f"/api/v1/automations/{task['id']}", expected=204)
    print("Automatisation : mesure", run["measured_percent"], "% ; une alerte ; tâche supprimée.")

# NEXORA — Personal AI Automation Agent

Assistant personnel Android et serveur Ubuntu. Le backend FastAPI protégé fournit
PostgreSQL, les métriques CPU, RAM et disque, un registre d’outils contrôlés, des
validations persistantes et un moteur de conversation indépendant du fournisseur
IA. L’application Android Flutter (`mobile/flutter_app/`) donne accès aux
conversations, aux validations et à l’état du serveur : voir son
[guide](mobile/flutter_app/README.md).

## Démarrage local

Prérequis : Python 3.12 pour le développement ; Docker avec Compose v2 ou ultérieur.
Depuis la racine du dépôt :

```sh
python3 scripts/init_env.py
docker compose --env-file .env -f infrastructure/compose.yml build
docker compose --env-file .env -f infrastructure/compose.yml run --rm backend python -m app.migrate up
docker compose --env-file .env -f infrastructure/compose.yml up -d --wait
python3 scripts/check_api.py --parcours
```

Le backend écoute uniquement sur `127.0.0.1:8100`. PostgreSQL n’expose aucun port
hôte. Les secrets générés sont dans `.env`, exclu de Git et accessible seulement
au propriétaire. Les mesures du lancement local portent sur l’environnement
d’exécution ; pour les mesures du serveur Ubuntu, utiliser le fichier de
configuration complémentaire décrit dans le [guide de déploiement](docs/DEPLOIEMENT.md).

## API

| Route | Protection | Fonction |
| --- | --- | --- |
| `GET /health/live` | Réseau privé, sans clé | Vérifie que le processus répond |
| `GET /health/ready` | Clé + `database:read` | Vérifie une connexion et une requête PostgreSQL |
| `GET /api/v1/auth/check` | Clé Bearer | Vérifie la clé d’accès |
| `GET /api/v1/server/metrics` | Clé + `server:read` | CPU, RAM, disque, unités, date et périmètre |
| `GET /api/v1/tools`, `POST /api/v1/tools/{nom}/invoke` | Clé Bearer | Registre et exécution contrôlée des outils |
| `/api/v1/approvals…` | Clé Bearer | Consultation, approbation, refus et exécution unique |
| `/api/v1/conversations…` | Clé Bearer | Conversations, messages et historique |
| `GET /api/v1/ai/status` | Clé Bearer | Fournisseur IA sélectionné et configuration |
| `/api/v1/automations…` | Clé + `automation:read` / `automation:write` | Tâches planifiées (vérification du disque), exécution manuelle, historique |
| `GET /api/v1/notifications` | Clé + `notifications:read` | Alertes produites par les tâches, lues par le téléphone |
| `GET /api/v1/github` | Clé + `github:read` | Rapport en lecture seule des dépôts autorisés |

Détails, codes d’erreur, limites et exemples : [docs/API.md](docs/API.md).

L’authentification utilise une clé aléatoire personnelle, associée à une liste de
permissions (`NEXORA_PERMISSIONS`). Le modèle IA ne voit que les outils déclarés
et autorisés ; aucun accès SSH, aucune commande libre ni appel de fonction
arbitraire ne lui est exposé. L’application Android utilise la même clé, gardée dans
le stockage sécurisé du téléphone ; il n’y a pas encore de comptes ni de sessions.

## Fournisseur IA

`NEXORA_AI_PROVIDER` vaut `none` (par défaut), `simulated` (règles fixes pour les
tests, jamais présentées comme une IA) ou `openai_compatible` : toute API de type
Chat Completions avec appels d’outils (NVIDIA par défaut, Grok/xAI possible en
changeant `NEXORA_AI_BASE_URL` et `NEXORA_AI_MODEL`). La clé est lue dans un
fichier secret, jamais dans `.env` ni Git : voir le
[guide de déploiement](docs/DEPLOIEMENT.md#fournisseur-ia).

## Développement et tests

```sh
python3.12 -m venv .venv
.venv/bin/pip install --require-hashes -r backend/requirements-dev.txt
.venv/bin/ruff check .
.venv/bin/ruff format --check .
.venv/bin/pytest -q
```

Les tests de persistance, de validation et de concurrence utilisent un vrai
PostgreSQL jetable, dont le schéma public est **effacé** à chaque test. Ne jamais
les diriger vers la base de production. Exemple local :

```sh
docker run -d --rm --name nexora-testdb -e POSTGRES_USER=nexora -e POSTGRES_DB=nexora \
  -e POSTGRES_PASSWORD=local-test-password-0000000000000000 -p 127.0.0.1:55432:5432 postgres:17-bookworm
NEXORA_TEST_POSTGRES_PASSWORD=local-test-password-0000000000000000 NEXORA_TEST_POSTGRES_PORT=55432 \
  NEXORA_REQUIRE_DB_TESTS=1 .venv/bin/pytest -q
```

Sans ces variables, ces tests sont ignorés ; la CI les rend obligatoires.

Les dépendances Python sont verrouillées avec leurs empreintes. Les fichiers
`requirements.in` déclarent les dépendances directes ; les fichiers `.txt` sont
générés avec `uv pip compile --generate-hashes`. Toute mise à jour doit passer les
tests et la construction de l’image. Les images de base utilisent des versions
majeures explicites et reçoivent les mises à jour de leur série.

## Organisation

- `backend/app/` : configuration, sécurité, base, métriques et routes.
- `backend/app/tools/` : registre, permissions, exécution et validations.
- `backend/app/ai/` : interface fournisseur, adaptateur compatible OpenAI, simulateur, moteur.
- `backend/app/migrations/` : migrations SQL versionnées (`python -m app.migrate`).
- `backend/tests/` : accès, permissions, validations, concurrence, fournisseur, secrets.
- `mobile/flutter_app/` : application Android Flutter, ses tests et son guide.
- `infrastructure/` : Compose, métriques Ubuntu et fournisseur IA facultatif.
- `scripts/` : génération locale des secrets et vérification de l’API.
- `docs/` : API, déploiement et choix techniques.

Le cahier des charges v1.1 reste dans l’espace documentaire local,
`../04_LIVRABLES/CAHIER_DES_CHARGES_NEXORA_v1.1.md`, extérieur à ce dépôt.

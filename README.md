# NEXORA — Personal AI Automation Agent

Assistant personnel Android et serveur Ubuntu. Le premier lot fournit une API
FastAPI protégée, PostgreSQL et la lecture des métriques CPU, RAM et disque.
L’IA et l’application mobile seront développées dans les lots suivants.

## Démarrage local

Prérequis : Python 3.12 pour le développement ; Docker avec Compose v2 ou ultérieur.
Depuis la racine du dépôt :

```sh
python3 scripts/init_env.py
docker compose --env-file .env -f infrastructure/compose.yml up --build -d --wait
python3 scripts/check_api.py
```

Le backend écoute uniquement sur `127.0.0.1:8100`. PostgreSQL n’expose aucun port
hôte. Les secrets générés sont dans `.env`, exclu de Git et accessible seulement
au propriétaire. Les mesures du lancement local portent sur l’environnement
d’exécution ; pour les mesures du serveur Ubuntu, utiliser le fichier de
configuration complémentaire décrit dans le [guide de déploiement](docs/DEPLOIEMENT.md).

## API

| Route GET | Protection | Fonction |
| --- | --- | --- |
| `/health/live` | Réseau privé, sans clé | Vérifie que le processus répond |
| `/health/ready` | Clé Bearer | Vérifie une connexion et une requête PostgreSQL |
| `/api/v1/auth/check` | Clé Bearer | Vérifie la clé d’accès |
| `/api/v1/server/metrics` | Clé Bearer | Retourne CPU, RAM, disque, unités, date et périmètre |

L’authentification initiale utilise une clé aléatoire personnelle. Ce lot ne
fournit pas encore de comptes, de sessions mobiles ni de permissions par outil.
L’accès distant prévu passe par HTTPS dans le réseau privé Tailscale.

## Développement et tests

```sh
python3.12 -m venv .venv
.venv/bin/pip install --require-hashes -r backend/requirements-dev.txt
.venv/bin/ruff check .
.venv/bin/ruff format --check .
.venv/bin/pytest -q
```

Les dépendances Python sont verrouillées avec leurs empreintes. Les fichiers
`requirements.in` déclarent les dépendances directes ; les fichiers `.txt` sont
générés avec `uv pip compile --generate-hashes`. Toute mise à jour doit passer les
tests et la construction de l’image. Les images de base utilisent des versions
majeures explicites et reçoivent les mises à jour de leur série.

## Organisation

- `backend/app/` : configuration, sécurité, connexion à la base, métriques et API.
- `backend/tests/` : accès, défaillances, secrets et initialisation.
- `mobile/flutter_app/` : emplacement de la future application.
- `infrastructure/` : Compose et configuration des métriques Ubuntu.
- `scripts/` : génération locale des secrets et vérification de l’API.
- `docs/` : déploiement et choix techniques.

Le cahier des charges v1.1 reste dans l’espace documentaire local,
`../04_LIVRABLES/CAHIER_DES_CHARGES_NEXORA_v1.1.md`, extérieur à ce dépôt.

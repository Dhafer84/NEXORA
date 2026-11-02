# Déployer NEXORA sur Ubuntu

## Prérequis

- Ubuntu avec Docker Engine et Compose installés ; utilisateur autorisé à utiliser Docker.
- Serveur et appareil client connectés au même réseau privé Tailscale.
- HTTPS Tailscale activé et droit de configurer Serve sur le serveur.
- Git, Python 3 et ports locaux `8100` et HTTPS `8101` disponibles.

Le dépôt ne contient ni adresse personnelle de serveur ni secret. Les commandes
ci-dessous supposent un clone dans `~/nexora`. Adapter le chemin si nécessaire.

## Installation

```sh
git clone https://github.com/Dhafer84/NEXORA.git ~/nexora
cd ~/nexora
python3 scripts/init_env.py
C="docker compose --env-file .env -f infrastructure/compose.yml -f infrastructure/compose.host.yml"
$C config --quiet
$C build
$C run --rm backend python -m app.migrate up
$C up -d --wait
python3 scripts/check_api.py
sudo tailscale serve --bg --https=8101 http://127.0.0.1:8100
tailscale serve status
```

Ouvrir l’URL HTTPS affichée par Tailscale avec le chemin `/health/live` depuis un
appareil connecté au réseau privé. La route renvoie `{"status":"ok"}`. Utiliser
`python3 scripts/check_api.py https://NOM_DNS_DU_SERVEUR:8101` depuis le serveur
pour vérifier aussi la clé, la base et les métriques en HTTPS. Les certificats
sont vérifiés ; ne pas désactiver leur validation.

Serve doit être configuré sur un port libre sans remplacer les services déjà
présents. Ne pas utiliser Funnel : l’accès prévu reste privé. Les règles du réseau
Tailscale doivent limiter l’accès aux appareils de l’utilisateur.

## Mesures du serveur

Le complément `compose.host.yml` monte en lecture seule `/proc/stat` et
`/proc/meminfo`, ainsi qu’un dossier vide `.runtime/host-disk`. Les mesures CPU et
mémoire correspondent à l’hôte Linux. Le disque mesuré est le système de fichiers
contenant ce dossier : vérifier avec `df -h .runtime/host-disk` qu’il correspond au
disque voulu. Sur une installation dans le répertoire personnel d’une partition
séparée, il ne représente pas nécessairement `/`.

Le backend n’a accès ni au socket Docker ni à l’arborescence complète de l’hôte.
Il fonctionne sans privilèges, avec un système de fichiers en lecture seule et
des limites de mémoire/CPU. La base reste sur un réseau interne isolé. Le backend rejoint également un
réseau dédié permettant la publication du port sur la boucle locale ; ses
connexions sortantes ne sont pas bloquées par cette configuration.

Les métriques ne sont pas encore historisées.

## Clé et rotation

La clé est stockée dans `~/nexora/.env` avec les permissions `600`. Le script
`check_api.py` la lit sans l’afficher. La conserver dans un gestionnaire de secrets
pour un futur client ; ne pas l’ajouter au dépôt, à une URL ou à un journal.

Pour la rotation, remplacer uniquement `NEXORA_API_KEY` dans `.env` par une nouvelle
valeur aléatoire de 64 caractères hexadécimaux puis recréer le backend avec Compose.
L’ancienne clé devient invalide. Aucun mécanisme de récupération de compte n’est
prévu pour cette première authentification personnelle.

Ne pas simplement changer `POSTGRES_PASSWORD` dans `.env` après l’initialisation :
le mot de passe du rôle PostgreSQL existant doit être changé séparément, puis la
configuration synchronisée. Le script d’initialisation refuse tout écrasement.

## Exploitation

Depuis la racine du dépôt :

```sh
docker compose --env-file .env -f infrastructure/compose.yml -f infrastructure/compose.host.yml ps
docker compose --env-file .env -f infrastructure/compose.yml -f infrastructure/compose.host.yml logs --tail=100 backend
```

`/health/live` mesure le processus ; `/health/ready` mesure sa connexion à la base.
Le contrôle Docker du backend utilise la première route. Une panne PostgreSQL
peut donc laisser le conteneur marqué sain : surveiller aussi la disponibilité
applicative protégée. Les contrôles restent indépendants de tout LLM.

Pour arrêter uniquement NEXORA, utiliser la même configuration avec `stop`. Ne pas
supprimer les volumes pour une simple mise à jour.

## Migrations

Le schéma est versionné dans `backend/app/migrations/` : `NNNN_nom.up.sql` et son
retour arrière `NNNN_nom.down.sql`. La table `schema_migrations` enregistre version,
nom, empreinte SHA-256 et date. Un verrou PostgreSQL empêche deux exécutions
simultanées ; chaque lancement est transactionnel (tout ou rien). Une migration
déjà appliquée puis modifiée dans le code est refusée.

```sh
$C run --rm backend python -m app.migrate status
$C run --rm backend python -m app.migrate up
$C run --rm backend python -m app.migrate down 0   # retour à la version 0
```

| Version | Contenu | Retour arrière |
| --- | --- | --- |
| 0001 | `conversations`, `messages`, `tool_executions`, `approval_requests`, index et contraintes | Supprime ces quatre tables **et leurs données** |

Les migrations ne sont pas lancées au démarrage de l’API : elles sont une étape
explicite, après la sauvegarde. Les routes de santé et de métriques fonctionnent
même si le schéma n’est pas à jour ; les routes métier répondent alors `503`.

## Mise à jour

Depuis `~/nexora`, avec `$C` défini comme ci-dessus :

```sh
git fetch && git log --oneline -1 origin/main
( umask 077; mkdir -p backups
  $C exec -T db pg_dump -U nexora -d nexora -Fc < /dev/null > backups/nexora_avant_maj_$(date +%Y%m%d_%H%M%S).dump
  git rev-parse HEAD > backups/commit_avant_maj.txt )
git pull --ff-only
$C build
$C run --rm backend python -m app.migrate up
$C up -d --wait
python3 scripts/check_api.py https://NOM_DNS_DU_SERVEUR:8101 --parcours
```

Le `umask 077` reste limité à la sous-commande de sauvegarde : appliqué au
`git pull`, il rendrait les fichiers du dépôt illisibles pour les autres comptes.
L’image corrige de toute façon les droits de lecture de `app/` à la construction.
`< /dev/null` empêche `exec -T` de consommer l’entrée d’un script.

`--parcours` exécute un outil, un cycle de validation complet avec l’action de test
sans effet, et crée une conversation « Vérification ». Il écrit donc ces traces dans
la base. Sans fournisseur IA configuré, il vérifie que l’envoi de message répond
`503` sans empêcher le reste.

## Retour arrière

1. Code seul (schéma compatible) : `git checkout <commit précédent>` puis `$C build`
   et `$C up -d --wait`.
2. Schéma : avec le code actuel, qui contient les fichiers `down`, annuler les
   migrations postérieures à la version visée
   (`$C run --rm backend python -m app.migrate down <version>`), puis revenir au
   code visé, `build` et `up`. Retour à l’étape 1 : `down 0` puis
   `git checkout d42f6f1`. Cette annulation supprime conversations, validations
   et traces : sauvegarder avant.
3. Restauration complète : arrêter le backend (`$C stop backend`), restaurer la
   sauvegarde dans une base de test pour la vérifier, puis dans `nexora` avec
   `pg_restore --clean --if-exists`, ensuite redémarrer le code correspondant.

Ne jamais supprimer le volume `postgres_data` lors d’un retour arrière.

## Fournisseur IA

Le moteur parle à toute API compatible OpenAI Chat Completions avec appels
d’outils. Configuration retenue : NVIDIA (`https://integrate.api.nvidia.com/v1`,
modèle `nvidia/nemotron-3-ultra-550b-a55b`). Le catalogue NVIDIA évolue : un modèle retiré répond `HTTP 410` ou `404` (`ai_rejected`). Lister les modèles disponibles avec `GET https://integrate.api.nvidia.com/v1/models` et changer `NEXORA_AI_MODEL`. Alternative rapide vérifiée : `nvidia/nemotron-3.5-lightning-30b-a3b`. Grok/xAI : `NEXORA_AI_BASE_URL=https://api.x.ai/v1`
et le modèle voulu, par exemple dans `.env` (valeurs non secrètes).

Créer la clé **sur le serveur**, sans la passer en argument de commande ni
l’afficher :

```sh
cd ~/nexora
install -d -m 700 secrets
( umask 077; read -rs -p "Clé API : " K; echo; printf '%s' "$K" > secrets/ai_api_key; unset K )
ls -l secrets/ai_api_key   # -rw------- dhafer
```

Puis activer le complément `compose.ai.yml`, qui monte ce fichier en secret Docker
en lecture seule dans `/run/secrets/ai_api_key` et exécute le backend avec l’uid du
propriétaire du fichier (`NEXORA_UID`/`NEXORA_GID`, 1000 par défaut ; vérifier
avec `id -u`) :

```sh
C="$C -f infrastructure/compose.ai.yml"
$C up -d --wait
python3 scripts/check_api.py https://NOM_DNS_DU_SERVEUR:8101 --parcours
```

Ne pas ajouter `compose.ai.yml` tant que le fichier n’existe pas : Compose refuserait
de démarrer. La clé est relue à chaque appel ; pour une rotation, remplacer le
fichier de la même façon. Sans ce complément, `NEXORA_AI_PROVIDER` vaut `none` :
l’API, la santé, les métriques et les outils restent disponibles.
`GET /api/v1/ai/status` indique l’état sans contacter le fournisseur.

Les réponses du fournisseur ne sont jamais journalisées ; les erreurs ne
contiennent qu’un code et un message générique. Le coût est borné par les limites
du moteur (voir [API.md](API.md#conversations)) : ajuster si besoin
`NEXORA_AI_MAX_TOOL_CALLS`, `NEXORA_AI_MAX_ITERATIONS`, `NEXORA_AI_MAX_OUTPUT_TOKENS`
et `NEXORA_AI_TURN_DEADLINE_SECONDS`.

## Permissions

`NEXORA_PERMISSIONS` (défaut `server:read,database:read,test:execute`) liste les
permissions de la clé personnelle. Retirer une permission retire l’outil
correspondant du modèle et fait refuser toute exécution, y compris d’une action
déjà approuvée. Les routes historiques suivent les mêmes règles :
`/api/v1/server/metrics` exige `server:read` et `/health/ready` exige
`database:read`. `/health/live` reste sans clé pour le contrôle Docker et
`scripts/check_api.py` suppose les permissions par défaut.

## Sauvegarde et vérification de restauration

La procédure est manuelle ; aucune sauvegarde planifiée n’est
activée automatiquement. Définir fréquence, rétention et stockage externe avant
d’ajouter des données personnelles importantes.

```sh
umask 077   # dans un terminal dédié à la sauvegarde, pas avant un git pull
mkdir -p backups
docker compose --env-file .env -f infrastructure/compose.yml exec -T db pg_dump -U nexora -d nexora -Fc > backups/nexora.dump
docker compose --env-file .env -f infrastructure/compose.yml exec -T db createdb -U nexora nexora_restore_test
docker compose --env-file .env -f infrastructure/compose.yml exec -T db pg_restore -U nexora -d nexora_restore_test --exit-on-error < backups/nexora.dump
docker compose --env-file .env -f infrastructure/compose.yml exec -T db psql -U nexora -d nexora_restore_test -c 'SELECT current_database();'
```

Choisir un nouveau nom de base de test si celui-ci existe déjà. Après inspection,
supprimer uniquement la base de restauration de test. La sauvegarde de la base
ne contient ni `.env` ni `secrets/` : conserver les secrets séparément dans un
stockage sûr. Vérifier les tables et nombres de lignes attendus, par exemple
`SELECT version FROM schema_migrations;` et `SELECT count(*) FROM messages;`, pas
seulement la connexion. Copier les sauvegardes hors du serveur selon la
politique retenue. Ne jamais inclure `.env` ou les dumps dans Git.

## Références techniques

- [FastAPI : outils de sécurité](https://fastapi.tiangolo.com/reference/security/)
- [Docker Compose : ordre de démarrage](https://docs.docker.com/compose/how-tos/startup-order/)
- [psutil : métriques système](https://psutil.readthedocs.io/stable/)
- [Tailscale Serve : HTTPS privé](https://tailscale.com/docs/reference/tailscale-cli/serve)

# Déployer les fondations sur Ubuntu

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
docker compose --env-file .env -f infrastructure/compose.yml -f infrastructure/compose.host.yml config --quiet
docker compose --env-file .env -f infrastructure/compose.yml -f infrastructure/compose.host.yml up --build -d --wait
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

Les métriques ne sont pas encore historisées. La base est persistante mais les
tables métier seront ajoutées avec leurs migrations dans les lots suivants.

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

Pour une mise à jour : récupérer le code puis relancer la commande `up --build -d
--wait`. Pour arrêter uniquement NEXORA, utiliser la même configuration avec
`stop`. Ne pas supprimer les volumes pour une simple mise à jour.

## Sauvegarde et vérification de restauration

Le premier lot inclut une procédure manuelle ; aucune sauvegarde planifiée n’est
activée automatiquement. Définir fréquence, rétention et stockage externe avant
d’ajouter des données personnelles importantes.

```sh
umask 077
mkdir -p backups
docker compose --env-file .env -f infrastructure/compose.yml exec -T db pg_dump -U nexora -d nexora -Fc > backups/nexora.dump
docker compose --env-file .env -f infrastructure/compose.yml exec -T db createdb -U nexora nexora_restore_test
docker compose --env-file .env -f infrastructure/compose.yml exec -T db pg_restore -U nexora -d nexora_restore_test --exit-on-error < backups/nexora.dump
docker compose --env-file .env -f infrastructure/compose.yml exec -T db psql -U nexora -d nexora_restore_test -c 'SELECT current_database();'
```

Choisir un nouveau nom de base de test si celui-ci existe déjà. Après inspection,
supprimer uniquement la base de restauration de test. La sauvegarde de la base
ne contient pas `.env` : conserver les secrets séparément dans un stockage sûr.
Pour les données métier futures, vérifier les tables et nombres de lignes attendus,
pas seulement la connexion. Copier les sauvegardes hors du serveur selon la
politique retenue. Ne jamais inclure `.env` ou les dumps dans Git.

## Références techniques

- [FastAPI : outils de sécurité](https://fastapi.tiangolo.com/reference/security/)
- [Docker Compose : ordre de démarrage](https://docs.docker.com/compose/how-tos/startup-order/)
- [psutil : métriques système](https://psutil.readthedocs.io/stable/)
- [Tailscale Serve : HTTPS privé](https://tailscale.com/docs/reference/tailscale-cli/serve)

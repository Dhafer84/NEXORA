# API NEXORA — version 1

Toutes les routes sauf `/health/live` exigent l’en-tête
`Authorization: Bearer <clé personnelle>`. Les erreurs métier ont la forme
`{"detail": {"code": "...", "message": "..."}}`. Les corps de requête sont limités
à 32 Kio (`413` au-delà). Aucune documentation interactive n’est publiée.

Dans les exemples, la clé est lue depuis `.env` sans être affichée :

```sh
export NEXORA_API_KEY="$(grep '^NEXORA_API_KEY=' .env | cut -d= -f2-)"
API=https://serveur.taildc501a.ts.net:8101
H="Authorization: Bearer $NEXORA_API_KEY"
```

## Santé et serveur

| Méthode et route | Permission | Fonction |
| --- | --- | --- |
| `GET /health/live` | aucune (sans clé) | Processus actif, sans base |
| `GET /health/ready` | `database:read` | Connexion et requête PostgreSQL |
| `GET /api/v1/auth/check` | clé seule | Vérifie la clé |
| `GET /api/v1/server/metrics` | `server:read` | CPU, mémoire, disque, unités, date et périmètre |

Ces routes ne dépendent ni du fournisseur IA ni des tables métier. Elles exigent
la même permission que l’outil équivalent du registre (`database_status`,
`server_metrics`) : sans elle, `403 permission_denied`.

## Outils

| Méthode et route | Fonction |
| --- | --- |
| `GET /api/v1/tools` | Registre : description, schémas des paramètres et du résultat, permissions, risque, validation, délai, `allowed` |
| `POST /api/v1/tools/{nom}/invoke` | Demande d’exécution `{"arguments": {...}}` |

Outils enregistrés :

| Outil | Permission | Risque | Validation | Délai |
| --- | --- | --- | --- | --- |
| `server_metrics` | `server:read` | faible | non | 5 s |
| `database_status` | `database:read` | faible | non | 5 s |
| `test_action` | `test:execute` | moyen | **oui** | 5 s |

`test_action` (paramètres `label` 1–80 caractères simples, `value` 0–1000) n’a
aucun effet sur le serveur : il sert à éprouver le circuit de validation.

Réponses de `invoke` : `200` exécuté (`status` = `succeeded`, `failed` ou
`timed_out`) ; `202` validation créée (`status` = `pending_approval`, objet
`approval`) ; `404 unknown_tool` ; `403 permission_denied` ; `422
invalid_arguments` (les valeurs soumises ne sont jamais renvoyées). Chaque demande,
même refusée, est tracée dans `tool_executions`.

```sh
curl -s -H "$H" -X POST "$API/api/v1/tools/server_metrics/invoke" -d '{}' -H 'Content-Type: application/json'
```

## Validations

| Méthode et route | Fonction |
| --- | --- |
| `GET /api/v1/approvals?status=pending&limit=50` | Liste (statuts : `pending`, `approved`, `rejected`, `expired`, `consumed`) |
| `GET /api/v1/approvals/{id}` | Détail : action exacte, paramètres, empreinte, résumé, risque, expiration |
| `POST /api/v1/approvals/{id}/approve` | `{"arguments_hash": "<empreinte affichée>"}` |
| `POST /api/v1/approvals/{id}/reject` | `{"reason": "facultatif"}` ; possible tant que l’action n’est pas exécutée |
| `POST /api/v1/approvals/{id}/execute` | `{"arguments": {...}}` : les paramètres exacts approuvés |

Règles :

- L’empreinte est le SHA-256 de `{"tool", "arguments"}` en JSON canonique.
  L’approbation doit fournir l’empreinte présentée : elle prouve que la décision
  porte sur ces paramètres.
- L’exécution revalide les paramètres et recalcule l’empreinte. Toute différence
  donne `409 approval_arguments_mismatch` : il faut une nouvelle demande.
- Expiration par défaut : 10 minutes (`NEXORA_APPROVAL_TTL_SECONDS`). Une demande
  expirée donne `410 approval_expired` puis `409`.
- Avant approbation : `409 approval_pending` ; après refus : `409 approval_rejected`.
- Une validation est consommée une seule fois, sous verrou de ligne PostgreSQL. Une
  reprise réseau ou un appel concurrent renvoie le résultat stocké avec
  `"replayed": true`, sans réexécuter l’action. Un index unique empêche aussi une
  seconde exécution en base.
- Les permissions sont revérifiées au moment de l’exécution.

```sh
A=$(curl -s -H "$H" -H 'Content-Type: application/json' -X POST "$API/api/v1/tools/test_action/invoke" \
  -d '{"arguments":{"label":"essai","value":3}}')
ID=$(echo "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["approval"]["id"])')
HASH=$(echo "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["approval"]["arguments_hash"])')
curl -s -H "$H" -H 'Content-Type: application/json' -X POST "$API/api/v1/approvals/$ID/approve" -d "{\"arguments_hash\":\"$HASH\"}"
curl -s -H "$H" -H 'Content-Type: application/json' -X POST "$API/api/v1/approvals/$ID/execute" -d '{"arguments":{"label":"essai","value":3}}'
```

## Conversations

| Méthode et route | Fonction |
| --- | --- |
| `POST /api/v1/conversations` | `{"title": "..."}` → `201` |
| `GET /api/v1/conversations?limit=20` | Conversations récentes |
| `GET /api/v1/conversations/{id}?limit=100` | Conversation et messages (`user`, `assistant`, `tool`) |
| `POST /api/v1/conversations/{id}/messages` | `{"content": "Quelle est la charge du serveur ?"}` |
| `GET /api/v1/ai/status` | Fournisseur, modèle, `real`, `configured` ; ne contacte pas le fournisseur |

Réponse d’un message : `status` = `completed`, `pending_approval` ou
`limit_reached`, nouveaux `messages`, `tool_executions` et `provider`
(`name`, `model`, `real`). Le fournisseur simulé a `real: false` et chacune de ses
réponses commence par « [Mode simulé — aucune IA réelle] ».

Le moteur n’expose au modèle que les outils autorisés par les permissions. Chaque
appel proposé par le modèle passe par le même contrôle que `invoke`. Une action
soumise à validation arrête le tour : la réponse indique l’identifiant et
l’expiration de la demande. Après `execute`, le résultat est ajouté à la
conversation.

À chaque message, le serveur fournit au modèle l’état actuel des 10 dernières
actions de la conversation (outil, paramètres, statut d’exécution et de
validation, résultat ou code d’erreur), lu en base après mise à jour des
expirations. Cet état fait foi : une action approuvée puis exécutée, refusée ou
expirée est connue du modèle au tour suivant, sans réexécution. Les anciens avis
« Validation requise » de l’historique sont annotés avec le nouvel état.

Limites par défaut : 4 000 caractères par message ; 4 appels d’outils et
5 échanges avec le modèle par message ; 30 s par appel au fournisseur et 90 s
par tour ; 20 messages d’historique ; 1 024 jetons de réponse ; 1 Mo par réponse
du fournisseur.

Durées : le délai d’un appel au fournisseur est un plafond total (connexion,
envoi et lecture), et non un délai d’inactivité. Le budget du tour est revérifié
avant chaque outil : aucun outil ne démarre après l’échéance, et l’attente d’un
outil est limitée au temps restant. Un outil déjà démarré qui dépasse sa limite
est marqué `timed_out` ; son résultat est ignoré mais son fil se termine en
arrière-plan, borné par les limites internes des outils de lecture (requête
PostgreSQL de 5 s au plus). Le dépassement total d’un tour se limite donc à
l’enregistrement final (quelques dizaines de millisecondes). Un seul tour à la
fois par conversation (`409 turn_in_progress`).

Erreurs : `503 ai_not_configured` (aucun fournisseur ou clé absente) ;
`503 ai_<code>` en cas d’échec du fournisseur (`unavailable`, `timeout`, `auth`,
`rate_limited`, `rejected`, `bad_response`). Le message de l’utilisateur et une
réponse d’erreur restent dans l’historique. `404 conversation_not_found`.

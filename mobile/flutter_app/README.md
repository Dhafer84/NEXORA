# NEXORA — application Android

Client Flutter du backend NEXORA : conversations avec l’assistant, validations des
actions sensibles, état du serveur et réglages. Interface en français, thèmes clair
et sombre, heures affichées dans le fuseau du téléphone.

## Utilisation

1. Activer **Tailscale** sur le téléphone : le serveur NEXORA est privé et reste
   injoignable sans lui.
2. Ouvrir NEXORA, saisir l’adresse HTTPS du serveur (exemple :
   `https://mon-serveur.mon-tailnet.ts.net:8101`) et la clé personnelle.
3. **Tester la connexion** : l’application vérifie d’abord l’adresse et le
   certificat (sans clé), puis la clé. Les messages distinguent serveur
   injoignable, certificat refusé et clé refusée.
4. **Enregistrer**. La clé n’est plus jamais affichée ; elle peut être remplacée
   (nouveau champ) ou supprimée de ce téléphone (elle reste valable côté serveur).

Onglets :

| Onglet | Contenu |
| --- | --- |
| Messages | Liste des discussions, création, historique, envoi. Pendant un tour (jusqu’à 2 min), l’envoi est bloqué. Une réponse du fournisseur simulé est marquée « Simulation — pas une IA réelle ». |
| Serveur | Disponibilité du backend et de PostgreSQL, CPU, RAM et disque avec date de mesure, état du fournisseur IA. Un refus 403 est expliqué (permission absente pour cette clé) sans masquer les autres blocs. |
| Validations | Demandes en attente (badge sur l’onglet) ou toutes. Détail : outil, résumé, paramètres exacts, empreinte, risque, expiration. |
| Réglages | Adresse, clé, test, suppression de la clé. |

### Validations

Rien n’est approuvé ni exécuté automatiquement. **Approuver** (avec confirmation)
enregistre la décision liée à l’empreinte des paramètres affichés ; **Exécuter
maintenant** (seconde confirmation) lance l’action une seule fois avec ces
paramètres. Le statut est toujours relu sur le serveur après chaque action :
expirée, refusée, déjà exécutée (résultat enregistré réaffiché, jamais relancé).
Le résultat est ajouté à la conversation d’origine.

### Réponses incertaines

Si la connexion tombe ou si le délai expire après l’envoi d’un message ou d’une
exécution, l’application ne renvoie **rien** automatiquement : elle recharge
l’historique ou le statut et invite à vérifier avant de réessayer. Si le
fournisseur IA échoue (HTTP 503), le message est déjà enregistré par le serveur :
l’historique est rechargé.

### Indicateur de validations

Le badge est mis à jour à l’ouverture de l’application puis toutes les 30 s tant
qu’elle est au premier plan. Il n’y a **pas de notification push** : une
validation demandée pendant que l’application est fermée n’est vue qu’à sa
réouverture.

## Sécurité

- Clé personnelle dans le stockage sécurisé Android (Keystore), jamais dans les
  journaux, les URL ni les sauvegardes (`allowBackup=false`, règles d’extraction
  vides).
- HTTPS obligatoire avec validation normale des certificats ; aucune exception TLS.
  Les versions de débogage acceptent en plus HTTP vers `10.0.2.2`, `localhost` et
  `127.0.0.1`, pour un backend local de test ; la version release le refuse.
- Aucune clé de fournisseur IA dans l’application ; aucune adresse de serveur
  imposée par défaut.
- Redirections HTTP non suivies (la clé ne part jamais vers une autre adresse).

## Architecture

| Dossier | Rôle |
| --- | --- |
| `lib/src/api/` | Client HTTP unique, modèles typés, erreurs centralisées (`ApiError`) et délais : 15 s pour les lectures, 150 s pour un tour IA ou une exécution. |
| `lib/src/storage/` | Stockage des identifiants (`flutter_secure_storage`). |
| `lib/src/state/` | État de l’application (`AppState`, badge) et d’une conversation (`ChatController`, garde contre le double envoi). |
| `lib/src/ui/` | Écrans, thème, formats français. |
| `test/` | Tests unitaires et d’écrans ; `test/support/fake_backend.dart` imite le backend en mémoire. |

Dépendances figées (`pubspec.lock`) : `http`, `flutter_secure_storage`, `intl`,
`flutter_localizations`. Gestion d’état : `ChangeNotifier` et `InheritedNotifier`,
sans bibliothèque supplémentaire.

## Développement

Prérequis : Flutter 3.41.3 (Dart 3.11.1), JDK 17, SDK Android.

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Les tests n’ouvrent aucune connexion réseau et n’appellent jamais un fournisseur IA.

### Essai sur émulateur avec un backend local simulé

Lancer le backend avec `NEXORA_AI_PROVIDER=simulated` sur `127.0.0.1:8765` (voir
le README du dépôt), puis :

```sh
flutter run --debug
```

Dans l’application, adresse `http://10.0.2.2:8765` et la clé du backend local.
Ne jamais saisir la clé du serveur réel dans un émulateur partagé.

### APK de test

```sh
flutter build apk --release
```

Il est signé avec la clé de débogage locale : utile pour essayer sur un téléphone,
pas pour une distribution. Aucune clé de signature de distribution n’existe encore.
Identifiant provisoire : `app.nexora.mobile` ; Android 8.0 (API 26) minimum.

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
   Elle est liée à l’adresse saisie : changer d’adresse exige la clé de la
   nouvelle adresse, l’ancienne n’est jamais envoyée ailleurs.

Onglets :

| Onglet | Contenu |
| --- | --- |
| Messages | Écran principal : la discussion courante, avec l’indicateur de connexion. Menu ⋮ : liste des discussions, nouvelle discussion, recharger, ouvrir dans la bulle. Pendant un tour (jusqu’à 2 min), l’envoi est bloqué. Les résultats d’outils s’affichent en cartes (« Espace disque » avec jauge, base de données, GitHub, action de démonstration) ; un ancien message non structuré garde son texte. Une réponse du fournisseur simulé est marquée « Simulation — pas une IA réelle ». |
| Serveur | Disponibilité du backend et de PostgreSQL, CPU, RAM et disque avec date de mesure, état du fournisseur IA. Un refus 403 est expliqué (permission absente pour cette clé) sans masquer les autres blocs. |
| Tâches | Automatisations et classement des fichiers (voir plus bas). |
| Réglages | Adresse, clé, test, suppression de la clé ; voix ; bulle. |

**Validations** : bouclier dans l’en-tête de chaque onglet, ambre avec le nombre de
demandes en attente. Dans la discussion, une carte « Validation requise » n’apparaît
que pour une demande réellement en attente ; « Voir la demande » ouvre son détail
(outil, résumé, paramètres exacts, empreinte, risque, expiration).

### Voix

- **Dictée** : bouton micro à côté du champ (aussi dans le mini-chat). Le texte
  reconnu (français) est placé dans le champ, à corriger puis à envoyer : rien
  n’est envoyé automatiquement. Arrêter ou annuler pendant l’écoute ; un résultat
  arrivé après l’annulation est ignoré.
- Reconnaissance **sur l’appareil** quand le téléphone la propose en français
  (Android 12+). Sinon, le service du téléphone peut envoyer l’audio à son éditeur :
  il n’est utilisé qu’après l’avoir autorisé dans Réglages (son nom y est affiché).
- Permission micro demandée au premier usage ; refus expliqué, lien vers les
  réglages Android si le refus est définitif. Aucune écoute continue ni en arrière-
  plan, aucun fichier audio : l’écoute s’arrête en quittant l’écran ou l’application
  et avant toute lecture. La lecture en cours s’arrête avant d’écouter.
- **Écouter** sur chaque réponse de NEXORA (Arrêter pendant la lecture), avec une
  voix française hors ligne uniquement. Lecture automatique facultative, désactivée
  par défaut.

### Bulle (mini-chat)

- Bulle de conversation Android (Android 11+), activée dans Réglages → Bulle. Pas
  d’autorisation « Afficher par-dessus les autres applications ». Au premier essai,
  Android peut demander de toucher l’icône de bulle de la notification NEXORA.
- Mini-chat : discussion courante et son historique, saisie, dictée, envoi, écoute.
  Agrandir ouvre l’application sur la même discussion avec le brouillon. Android
  replie la bulle (icône, toucher à côté, Retour) ; il n’existe pas d’interface
  pour qu’une application la replie elle-même.
- Une demande sensible s’ouvre dans l’écran de validation habituel en plein écran ;
  rien n’est approuvé ni exécuté depuis la bulle.
- Les deux fenêtres partagent l’adresse, la clé et les brouillons ; pendant qu’une
  fenêtre attend une réponse, l’autre ne peut pas envoyer dans la même discussion
  et recharge l’historique ensuite.
- Sans bulle : « Raccourci vers le chat » épingle un raccourci qui ouvre la
  discussion.

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
qu’elle est au premier plan. Une validation demandée pendant que l’application
est fermée n’est vue qu’à sa réouverture.

### Automatisations (onglet « Tâches »)

- Créer, modifier, suspendre, reprendre ou supprimer une vérification de l’espace
  disque du serveur : seuil d’alerte (un seuil de 1 % sert d’essai), fréquence
  (15 min à 24 h). Le fuseau horaire est celui du téléphone ; la prochaine
  vérification est affichée à l’heure locale.
- « Vérifier maintenant » lance une mesure immédiate et affiche son résultat ;
  l’historique montre chaque exécution (heure, valeur, seuil, résultat, échec,
  notification envoyée, créneaux manqués pendant un arrêt du serveur).
- **Alertes sur ce téléphone** : un travail Android (WorkManager) interroge le
  serveur environ toutes les 15 minutes, même application fermée et après un
  redémarrage du téléphone, et affiche les nouvelles notifications (seuil atteint,
  retour sous le seuil, mesure impossible). Délai réel : 15 à 45 minutes (Android regroupe les tâches réseau), plus en
  économie d’énergie ; Tailscale doit rester connecté ; un **arrêt forcé** de
  l’application suspend les alertes jusqu’à sa réouverture. Sur Huawei, régler
  NEXORA en « Gestion manuelle » dans *Lancement des applications*. Android 13 et
  plus demandent l’autorisation des notifications ; un refus est expliqué.
- Pas de notification « push » instantanée : voir les questions de T04 (ntfy).

### Projets GitHub (onglet « Serveur »)

État des dépôts autorisés sur le serveur (`NEXORA_GITHUB_REPOS`) : dernier
résultat GitHub Actions, issues ouvertes, dernier commit. Lecture seule.

### Classement des fichiers (depuis « Tâches »)

- NEXORA n’accède qu’à **un dossier choisi** dans le sélecteur Android (Storage
  Access Framework), sans permission de stockage générale ; l’accès peut être
  retiré dans l’écran.
- Le sélecteur s’ouvre sur Téléchargements, après une explication : Android
  refuse la racine de Téléchargements et du stockage (« Impossible d’utiliser
  ce dossier ») ; choisir ou créer un sous-dossier, par exemple
  `Download/NEXORA`. L’accès durable en lecture et écriture est vérifié, et
  revérifié à l’ouverture (accès retiré signalé). Aucune permission
  `MANAGE_EXTERNAL_STORAGE`.
- *Choisir des fichiers* (sélecteur `ACTION_OPEN_DOCUMENT`) : déplacement ou
  renommage seulement pour un fichier situé dans le dossier autorisé ; un fichier
  hors du dossier reçoit une note (le déplacer avec l’application Fichiers),
  jamais une copie suivie d’une suppression.
- Propositions calculées sur le téléphone, sans serveur ni IA : rangement par
  type dans des sous-dossiers (Documents, Tableurs, Présentations, Images,
  Vidéos, Audio, Archives, Applications) et noms lisibles pour les photos et
  captures.
- **Chaque** déplacement ou renommage s’effectue seulement après sa propre
  confirmation, qui affiche le fichier et la destination (le nouveau nom peut être
  modifié). Rien n’est supprimé, copié ni remplacé : un nom déjà pris ou un
  stockage qui refuse le déplacement donne une erreur sans modification. Chaque
  résultat est rapporté dans « Opérations effectuées ».

### Diagnostic santé (Réglages, prototype de l’étape 5)

- Lit **Health Connect** sur le téléphone (Android 14 et plus : intégré ; avant :
  application Health Connect). Accessible aussi avant la configuration du
  serveur : il n’en a pas besoin.
- **Une permission de lecture par catégorie**, demandée seulement quand on
  appuie sur son bouton : pas d’abord ; sommeil, fréquence cardiaque et
  entraînements après une lecture des pas réussie. Aucune permission d’écriture
  en release (les versions de débogage peuvent écrire des entrées d’essai de
  NEXORA pour l’émulateur).
- Une **journée terminée** (hier par défaut, jamais aujourd’hui), de 00:00 à
  24:00 dans le fuseau du téléphone, affiché à l’écran.
- Pour chaque catégorie : *Données lues*, *Permission refusée*, *Aucune donnée
  disponible*, *Health Connect indisponible* ou erreur de lecture.
- Pas : total des entrées de **Health Sync** (paquet `nl.appyhapps.healthsync`,
  à confirmer sur l’appareil), total Health Connect (doublons retirés selon la
  priorité des applications), somme brute, détail par application et appareil
  (paquet, nombre d’entrées, heures ; appareil et modèle seulement s’ils figurent
  dans l’entrée, sinon « Health Sync » seul) et **avertissement de chevauchement** quand
  deux sources couvrent la même période (pour ne pas additionner la montre et le
  téléphone).
- *Historique accessible* : date de la plus ancienne entrée lisible.
- **Confidentialité** : valeurs gardées en mémoire de l’écran seulement ; aucune
  écriture sur disque, aucun journal (Dart ou Kotlin), aucun envoi au serveur
  NEXORA ni au fournisseur IA. Titres et notes des entraînements ne sont pas lus.
  `HealthPrivacyActivity` explique cet usage depuis Health Connect.

### Activité (onglet, étape 6)

- Onglet **Activité** (présent quand Health Connect est géré) : pas, sommeil,
  fréquence cardiaque et entraînements sur 60 jours au plus, **une permission
  de lecture par catégorie** demandée au geste (les entraînements demandent aussi
  la distance). Une catégorie refusée reste « Non autorisée » sans bloquer les
  autres.
- **Copie locale chiffrée** (stockage sécurisé Android, une entrée par
  catégorie), remplacée en entier à chaque lecture : relire ne double rien.
  Permission retirée, même application fermée : la copie de la catégorie est
  effacée au prochain lancement. *Effacer la copie locale* supprime aussi les
  exports temporaires.
- Règles : un jour sans donnée n’est jamais compté zéro ; aujourd’hui et un jour
  dont la dernière entrée finit avant 21:00 sont **partiels** ; comparaison avec
  la période précédente seulement si les deux couvrent au moins 70 % des jours
  et ont des nombres de jours proches ; une nuit compte au jour du réveil
  (union de ses intervalles) ; fréquence cardiaque pondérée par le nombre de
  mesures ; deux séances qui se recouvrent à 50 % ou plus comptent une fois ;
  pas de Health Sync par défaut, sinon total Health Connect, jamais de somme des
  sources.
- Courbes 7 / 30 / 60 jours : jours manquants marqués, jours partiels en creux,
  bande min–max, détail d’un point au toucher.
- **Analyser avec l’IA** : résumé chiffré calculé sur le téléphone (sans
  appareil ni paquet), affiché tel quel avec le destinataire
  (`GET /api/v1/analysis/recipient`) ; envoi seulement après la case de
  consentement, liée à ce texte et à ce destinataire (changer de période
  l’annule). `409 recipient_changed` : nouvelle confirmation, jamais de renvoi.
  Aucune conversation créée.
- **Exporter pour ChatGPT** : CSV ou JSON, agrégats par jour par défaut ; le
  détail des entrées (horaires, sources, modèle d’appareil) est un choix
  distinct. Aperçu exact du fichier ; *Enregistrer* (sélecteur Android
  `ACTION_CREATE_DOCUMENT`) ou *Partager* (copie temporaire dans le cache via
  `FileProvider`, effacée au partage suivant). Rien ne passe par le serveur.

## Sécurité

- Adresse et clé enregistrées ensemble dans une seule entrée du stockage sécurisé,
  en une écriture : une interruption laisse l’ancienne paire ou la nouvelle,
  jamais une clé associée à une autre adresse.
- Clé personnelle dans le stockage sécurisé Android (Keystore), jamais dans les
  journaux, les URL ni les sauvegardes (`allowBackup=false`, règles d’extraction
  vides).
- HTTPS obligatoire avec validation normale des certificats ; aucune exception TLS.
  Les versions de débogage acceptent en plus HTTP vers `10.0.2.2`, `localhost` et
  `127.0.0.1`, pour un backend local de test ; la version release le refuse.
- Aucune clé de fournisseur IA dans l’application ; aucune adresse de serveur
  imposée par défaut.
- Redirections HTTP non suivies (la clé ne part jamais vers une autre adresse).
- Toute réponse hors contrat devient une erreur lisible ; après un envoi ou une
  exécution, elle est traitée comme une issue incertaine (aucun renvoi).

## Architecture

| Dossier | Rôle |
| --- | --- |
| `lib/src/api/` | Client HTTP unique, modèles typés, erreurs centralisées (`ApiError`) et délais : 15 s pour les lectures, 150 s pour un tour IA ou une exécution. |
| `lib/src/storage/` | Stockage des identifiants (`flutter_secure_storage`). |
| `lib/src/alerts/` | Alertes en arrière-plan : curseur des notifications du serveur, travail WorkManager, notifications locales. |
| `lib/src/files/` | Classement des fichiers : accès au dossier choisi (canal vers `MainActivity.kt`), règles de proposition. |
| `lib/src/state/` | État de l’application (`AppState`, badge, connexion) et d’une conversation (`ChatController`, garde contre le double envoi, y compris entre les deux fenêtres). |
| `lib/src/session/` | Brouillons et préférences partagés entre fenêtres (`SharedPreferencesAsync`) ; tour en cours partagé (`TurnLock`, canal vers `SessionHub.kt`). |
| `lib/src/voice/` | Dictée et lecture (`VoiceController`, canal vers `VoiceBridge.kt` : `SpeechRecognizer`, `TextToSpeech`). |
| `lib/src/health/` | Diagnostic Health Connect : canal vers `HealthBridge.kt` (permissions, lecture d’une journée, agrégats), classement des sources et chevauchements (`health_summary.dart`). |
| `lib/src/activity/` | Module Activité : modèles, calculs (`activity_stats.dart`), copie chiffrée (`activity_store.dart`), contrôleur, résumé IA et export (`activity_report.dart`) ; lecture native par plage dans `HealthRange.kt`. |
| `lib/src/bubble/` | Bulle (canal vers `BubbleBridge.kt`) ; le mini-chat tourne dans `BubbleActivity` avec le point d’entrée `bubbleMain`. |
| `lib/src/ui/` | Écrans, mini-chat, cartes de résultats, thème (couleurs, espacements, rayons dans `theme.dart`), marque N (`design/nexora_mark.svg`), formats français. |
| `test/` | Tests unitaires et d’écrans ; `test/support/fake_backend.dart` imite le backend en mémoire. |

Dépendances figées (`pubspec.lock`) : `http`, `flutter_secure_storage`, `intl`,
`flutter_localizations`, `workmanager`, `flutter_local_notifications`,
`flutter_timezone`, `shared_preferences` ; côté Android `androidx.health.connect:connect-client` 1.1.0 et `kotlinx-coroutines-android`. Gestion d’état : `ChangeNotifier` et `InheritedNotifier`,
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

Lancer le backend avec `NEXORA_AI_PROVIDER=simulated` sur `127.0.0.1:8000` (voir
le README du dépôt), puis :

```sh
flutter run --debug
```

Dans l’application, adresse `http://10.0.2.2:8000` et la clé du backend local.
Ne jamais saisir la clé du serveur réel dans un émulateur partagé.

### APK de test

```sh
flutter build apk --release
```

Il est signé avec la clé de débogage locale : utile pour essayer sur un téléphone,
pas pour une distribution. Aucune clé de signature de distribution n’existe encore.
Identifiant provisoire : `app.nexora.mobile` ; Android 8.0 (API 26) minimum.

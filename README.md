# NEXORA — Personal AI Automation Agent

Assistant IA personnel pour Android, avec backend sur serveur Ubuntu.

## État
Dépôt initialisé ; aucun composant applicatif n’est encore implémenté.

## Organisation
- `backend/app/` : API FastAPI, moteur IA, outils et automatisations.
- `backend/tests/` : tests des fonctions critiques.
- `mobile/flutter_app/` : future application Flutter/Dart.
- `infrastructure/` : futur déploiement Docker Compose.
- `docs/` : documentation technique versionnée avec le code.

## Référence fonctionnelle
Le cahier des charges v1.1 est conservé dans l’espace documentaire local :
`../04_LIVRABLES/CAHIER_DES_CHARGES_NEXORA_v1.1.md`.
Ce document est extérieur au dépôt et n’est pas inclus dans un clone autonome.

## Premier lot
Construire les fondations du backend : FastAPI, PostgreSQL, authentification,
accès sécurisé et consultation des métriques autorisées du serveur.

## Configuration
Ne pas versionner de secrets ni de données personnelles. Les futurs paramètres
seront documentés dans `.env.example`, avec des valeurs fictives uniquement.

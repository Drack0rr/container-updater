# Changelog

## 2.2.0 — 2026-10-04

- Surveille par défaut les services Swarm sans label ; ajoute `--unlabeled-policy ignore`.
- Respecte `autoupdate=false` et signale les labels invalides, services arrêtés et jobs.
- Compare le digest de l'index et les manifests de plateforme via Docker Buildx ;
  prend aussi en charge les manifests simples, met en cache les résultats du registre
  et conserve les erreurs hors des sous-shells.
- Supprime le fallback Swarm par téléchargement local, source de faux résultats
  sur les managers et en simulation ; signale les digests non vérifiables.
- Épingle le digest vérifié pour une mise à jour directe et vérifie sa convergence,
  ses répliques et ses tâches ; détecte les rollbacks et changements concurrents.
- Contrôle les statuts HTTP des webhooks, refuse les redirections et déduplique les
  webhooks partagés ; sépare demande soumise et mise à jour vérifiée.
- Bloque les envois Zabbix en simulation et signale les vérifications incomplètes
  dans les notifications et codes de sortie.
- Ajoute Buildx à l'image Docker, des tests de régression et les fins de ligne LF.

Les services sans label ne deviennent pas automatiquement modifiables. Le script
reste limité au tag configuré et ne met pas à jour le Compose source dans Portainer.

# container-updater

Script Bash pour détecter et appliquer des mises à jour de workloads Docker via labels (`monitor`, `docker-compose`, `Portainer`), avec notifications Discord et métriques Zabbix optionnelles.

## Nouveautés

- Script durci: `set -Eeuo pipefail`, quoting strict, gestion d'erreurs centralisée.
- Logs structurés (`text` ou `json`) et mode `--dry-run`.
- Intégration `.env` standard (`.env.example` fourni).
- Dockerfile moderne avec `HEALTHCHECK`.
- `compose.yaml` exemple (Docker Compose v2).
- CI GitHub Actions: lint shell, build image, scans Trivy.

## Prérequis

- `bash`
- `docker` (daemon accessible)
- `jq`
- `curl`
- `zabbix_sender` (uniquement si Zabbix est activé)

## Usage local

```bash
chmod +x ./container-updater.sh
./container-updater.sh --help
```

Exemple:

```bash
./container-updater.sh \
  -d "$DISCORD_WEBHOOK" \
  -z "$ZABBIX_SERVER" \
  -n "prod-host" \
  --no-system-update
```

## Variables d'environnement

Copier le modèle:

```bash
cp .env.example .env
```

Variables principales:

- `DISCORD_WEBHOOK`: webhook Discord.
- `ZABBIX_SERVER`: serveur Zabbix.
- `ZABBIX_HOST`: nom d'hôte envoyé à Zabbix.
- `GHCR_USERNAME`, `GHCR_TOKEN`: auth GHCR (images privées).
- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`: auth Docker Hub (évite les limites anonymes).
- `UPDATE_SYSTEM_PACKAGES`: `true|false` (apt/dnf).
- `BLACKLIST`: liste CSV de paquets.
- `DRY_RUN`: `true|false`.
- `LOG_FORMAT`: `text|json`.

## Mode d'exécution (auto-détection)

Le script détecte automatiquement son mode:

- `standalone`: scan des conteneurs locaux via `docker ps` (comportement historique).
- `swarm-manager`: scan des services via `docker service ls`.
- `swarm-worker`: aucune mise à jour Swarm, warning explicite puis sortie en succès.
- `docker-unavailable`: skip des vérifications Docker.

En mode `swarm-manager`, seul le flux Swarm est exécuté (pas de double scan `docker ps`).

## Labels supportés (standalone + swarm)

En Swarm, les labels sont lus avec cette priorité:

1. `Spec.Labels` (labels de service `deploy.labels`)
2. `Spec.TaskTemplate.ContainerSpec.Labels` (fallback)

### Monitoring uniquement

```yaml
labels:
  - "autoupdate=monitor"
```

### Mise à jour automatique via Docker Compose

```yaml
labels:
  - "autoupdate=true"
  - "autoupdate.docker-compose=/path/to/compose.yaml"
```

Note Swarm: `autoupdate.docker-compose` est ignoré volontairement (warning dans les logs).  
Raison: `docker compose up` n'est pas un mécanisme sûr pour mettre à jour un service Swarm.

### Mise à jour automatique via webhook Portainer

```yaml
labels:
  - "autoupdate=true"
  - "autoupdate.webhook=https://..."
```

### Méthode par défaut en Swarm (sans webhook)

Si `autoupdate=true` et qu'aucun webhook n'est défini, le script applique:

```bash
docker service update --image <repo:tag> --detach=false <service>
```

Avec `GHCR_TOKEN` configuré, `--with-registry-auth` est ajouté automatiquement.

### Exemple labels Swarm au niveau service (`deploy.labels`)

```yaml
services:
  app:
    image: example/app:latest
    deploy:
      labels:
        - "autoupdate=true"
        - "autoupdate.webhook=https://..."
```

### Exemple fallback labels dans `TaskTemplate.ContainerSpec.Labels`

```yaml
services:
  app:
    image: example/app:latest
    labels:
      - "autoupdate=true"
```

## Exécution en conteneur (Compose v2)

```bash
docker compose up -d --build
```

`compose.yaml` monte `/var/run/docker.sock` pour piloter le daemon hôte.

## CI/CD

Workflow: `.github/workflows/ci.yml`

- Shell lint: `shellcheck`, `shfmt`
- Build Docker: `docker/build-push-action`
- Scan sécurité: Trivy (filesystem + image)

## Healthcheck

```bash
./container-updater.sh --healthcheck
```

## Zabbix template

Template fourni: `Zabbix-Template_App-Maj.yml`

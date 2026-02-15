# container-updater

Script Bash pour détecter et appliquer des mises à jour de conteneurs Docker via labels (`monitor`, `docker-compose`, `Portainer`), avec notifications Discord et métriques Zabbix optionnelles.

## Nouveautés (modernisation 2026)

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
- `UPDATE_SYSTEM_PACKAGES`: `true|false` (apt/dnf).
- `BLACKLIST`: liste CSV de paquets.
- `DRY_RUN`: `true|false`.
- `LOG_FORMAT`: `text|json`.

## Labels de conteneur supportés

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

### Mise à jour automatique via webhook Portainer

```yaml
labels:
  - "autoupdate=true"
  - "autoupdate.webhook=https://..."
```

## Changement important (sécurité)

Le mode `autoupdate.docker-run` legacy n'exécute plus de reconstruction dynamique de commande `docker run`.

Raison: ce mécanisme reposait sur des patterns à haut risque (`eval`, template distant) incompatibles avec un niveau de sécurité 2026. La migration recommandée est `autoupdate.docker-compose` ou `autoupdate.webhook`.

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

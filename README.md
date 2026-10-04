# container-updater

Script Bash pour détecter et appliquer des mises à jour de workloads Docker via labels (`monitor`, `docker-compose`, `Portainer`), avec notifications Discord et métriques Zabbix optionnelles.

## Nouveautés

- Swarm 2.2 : services sans label visibles en surveillance, `autoupdate=false` respecté.
- Comparaison des digests de registre multiplateformes, sans téléchargement d'image sur le manager.
- Webhooks contrôlés, dédupliqués par exécution et suivis jusqu'à la convergence Swarm.
- États inconnus, exclus et mises à jour en attente explicitement comptabilisés.
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
- `timeout` (GNU coreutils ou BusyBox)
- Docker Buildx (`docker-buildx-plugin` avec les paquets Docker officiels), pour les contrôles Swarm
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

Compose charge `.env` via `env_file`. Le script Bash ne source pas ce fichier :
pour une exécution directe, exporter les variables dans l'environnement du processus
ou utiliser le gestionnaire de secrets du système. Ne pas passer de secret en argument.

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
- `DOCKER_TIMEOUT`: durée maximale d'une requête Docker/registre/webhook, en secondes (15).
- `SWARM_UNLABELED_POLICY`: `monitor` (défaut) ou `ignore`, également réglable par `--unlabeled-policy`.
- `UPDATE_TIMEOUT`: fenêtre d'attente de convergence Swarm, en secondes (180).
- `UPDATE_POLL_INTERVAL`: intervalle de relecture Swarm en secondes (3).

Les durées doivent être des entiers strictement positifs. Une relecture déjà en cours
peut dépasser la fenêtre de convergence de quelques délais `DOCKER_TIMEOUT`.

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

| Label effectif | Comportement Swarm |
| --- | --- |
| `autoupdate=true` | Contrôle et mise à jour automatique du tag configuré |
| `autoupdate=monitor` | Contrôle et notification seulement |
| `autoupdate=false` | Exclusion explicite, sans requête au registre |
| Absent | Surveillance seulement, sauf `--unlabeled-policy ignore` |
| Autre valeur | Erreur de configuration signalée, aucune mise à jour |

Un label de service `false` prime sur un label de conteneur `true`.
Le défaut en standalone reste d'ignorer les conteneurs sans label.

### Pourquoi Portainer affiche encore des images à mettre à jour

La version 2.1.3 ignorait silencieusement les services sans label. Par exemple,
`discovered=26 managed=6` signifie que seuls six services étaient contrôlés.
Depuis 2.2, les autres services sont contrôlés en **surveillance uniquement**.
Pour autoriser leur mise à jour, ajouter `autoupdate=true` dans `deploy.labels`
des services concernés, puis redéployer leur configuration.

Le script recherche une nouvelle image **sous le même tag**. Il ne choisit pas une
nouvelle version applicative : `app:1.2.3` ne devient pas `app:1.3.0` ni `latest`.
Une référence `repo@sha256:...` sans tag est signalée sans être réinterprétée en
`latest`. Une référence `repo:tag@sha256:...` est comparée à `repo:tag` ;
`autoupdate=true` autorise alors le renouvellement de son digest.

Les index multiplateformes et leurs manifests de plateforme sont comparés
à partir du digest de registre fourni par [Docker Buildx](https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/).
Le cache local du manager ne prouve pas la version des tâches sur
les autres nœuds. Lorsque ni le service ni ses tâches actives ne donnent de digest,
le résultat est `RUNNING_IMAGE_DIGEST_UNKNOWN`, jamais « à jour » par défaut.

Les services à zéro réplique et les modes Swarm Job sont signalés sans être relancés.
La convergence vérifiée couvre l'image, les répliques et les tâches en état `running` ;
elle ne remplace pas un test fonctionnel de l'application et de son point d'accès.

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

Le webhook doit retourner un statut HTTP 2xx. Une réponse HTTP 2xx signifie
« demande acceptée » ; `applied` n'augmente qu'après vérification du digest attendu
et des tâches Swarm. Un webhook qui conserve une image épinglée dans le Compose,
une convergence trop lente ou des tâches restées sur l'ancienne image donnent
`pending`, pas un faux succès. Un rollback ou une mise en pause donne `failed`.
Un POST en erreur ou avec un résultat incertain n'est pas réessayé dans la même
exécution. Relire Portainer avant de relancer le script dans ce cas.

Un webhook de stack peut redéployer toute la stack, y compris ses autres services :
ne le configurer que si cette portée est souhaitée. Il n'est appelé qu'une fois
par URL et par exécution. Les URL de webhook ne sont pas écrites dans les logs.

### Méthode par défaut en Swarm (sans webhook)

Si `autoupdate=true` et qu'aucun webhook n'est défini, le script applique:

```bash
docker service update --image <repo:tag@digest-vérifié> --detach=true <service-id>
```

Le script relit l'identifiant et la version du service avant l'envoi, puis attend
sa convergence dans la limite configurée. Avec `GHCR_TOKEN` ou `DOCKERHUB_TOKEN`
configuré, `--with-registry-auth` est ajouté. Une modification concurrente entraîne
un abandon de cette cible jusqu'à une prochaine exécution.

Cette mise à jour directe ne réécrit pas le Compose conservé par Portainer/Git.
Si ce Compose contient un ancien digest, un prochain redéploiement peut le rétablir :
mettre aussi à jour la source de déploiement dans votre procédure de changement.

### Contrôle avant mise à jour

```bash
docker buildx version
./container-updater.sh --no-system-update --dry-run
```

En Swarm, ce contrôle lit les registres sans `docker pull`, login, suppression
d'image, webhook ni mise à jour de service. Discord et Zabbix ne sont pas contactés
en `--dry-run`. Les images privées nécessitent des identifiants Docker déjà disponibles.

Le récapitulatif distingue `unlabeled`, `disabled`, `up_to_date`, `updates_available`,
`monitor_only`, `applied`, `simulated`, `pending`, `failed` et `checks_skipped`.
Les compteurs `unlabeled` et `monitor_only` sont des sous-ensembles, pas des catégories
à additionner. Le code de sortie vaut 1 en cas d'échec, de vérification indéterminée
ou de convergence non vérifiée ; 2 pour une option invalide ; 0 sinon.
Une mise à jour disponible en surveillance seule n'est pas une erreur.

En Swarm, aucun nettoyage automatique des images n'est effectué : les images
locales du manager ne représentent pas le cluster et peuvent servir au retour arrière.

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

Tests de comportement isolés (aucun accès Docker réel ni notification) :

```bash
bash tests/test-swarm-behavior.sh
```

## Healthcheck

```bash
./container-updater.sh --healthcheck
```

## Zabbix template

Template fourni: `Zabbix-Template_App-Maj.yml`

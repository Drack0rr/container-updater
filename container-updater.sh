#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"

# -----------------------------
# Defaults (can be overridden by env or CLI)
# -----------------------------
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
BLACKLIST_RAW="${BLACKLIST:-}"
GHCR_TOKEN="${GHCR_TOKEN:-${AUTH_GITHUB:-}}"
GHCR_USERNAME="${GHCR_USERNAME:-${GITHUB_USERNAME:-oauth2}}"
ZABBIX_SRV="${ZABBIX_SRV:-${ZABBIX_SERVER:-}}"
ZABBIX_HOST="${ZABBIX_HOST:-${HOSTNAME:-unknown-host}}"
UPDATE_SYSTEM_PACKAGES="${UPDATE_SYSTEM_PACKAGES:-true}"
ALLOW_LEGACY_DOCKER_RUN="${ALLOW_LEGACY_DOCKER_RUN:-false}"
DRY_RUN="${DRY_RUN:-false}"
LOG_FORMAT="${LOG_FORMAT:-text}" # text|json
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-15}"

PAQUET_UPDATE=""
PAQUET_NB=0
UPDATED=""
UPDATE=""
ERROR_C=""
ERROR_M=""
CONTAINERS=""
CONTAINERS_Z=""
UPDATED_Z=""
CONTAINERS_NB=0
CONTAINERS_NB_U=0

# shellcheck disable=SC2034
LEGACY_DOCKER_RUN_DISABLED_REASON="autoupdate.docker-run is disabled by default for security hardening"

trap 'on_error $LINENO' ERR

on_error() {
  local line="$1"
  log error "unexpected failure" "line=${line}"
  exit 1
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  local level="$1"
  local message="$2"
  local extra="${3:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ "$LOG_FORMAT" == "json" ]]; then
    jq -cn --arg ts "$ts" --arg level "$level" --arg msg "$message" --arg extra "$extra" \
      '{timestamp:$ts, level:$level, message:$msg, extra:$extra}'
  else
    if [[ -n "$extra" ]]; then
      printf '%s [%s] %s (%s)\n' "$ts" "${level^^}" "$message" "$extra"
    else
      printf '%s [%s] %s\n' "$ts" "${level^^}" "$message"
    fi
  fi
}

usage() {
  cat <<'USAGE'
Container Updater v2

Usage:
  ./container-updater.sh [options]

Options:
  -d <discord_webhook>       Discord webhook URL
  -b <pkg1,pkg2>             Package blacklist (exact package names)
  -g <ghcr_token>            GHCR token (deprecated: prefer GHCR_TOKEN env)
  -u <ghcr_username>         GHCR username (default: oauth2)
  -z <zabbix_server>         Zabbix server
  -n <host_name>             Zabbix host name override
  --dry-run                  Do not perform mutating actions
  --no-system-update         Disable apt/dnf package update step
  --healthcheck              Validate runtime dependencies and exit
  -h, --help                 Show help

Environment variables:
  DISCORD_WEBHOOK, BLACKLIST, GHCR_TOKEN, GHCR_USERNAME,
  ZABBIX_SERVER, ZABBIX_HOST, UPDATE_SYSTEM_PACKAGES,
  ALLOW_LEGACY_DOCKER_RUN, DRY_RUN, LOG_FORMAT, DOCKER_TIMEOUT
USAGE
}

healthcheck() {
  local missing=0
  for bin in bash docker jq curl; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      log error "missing binary" "binary=$bin"
      missing=1
    fi
  done

  if [[ -n "$ZABBIX_SRV" ]] && ! command -v zabbix_sender >/dev/null 2>&1; then
    log error "zabbix_sender required when ZABBIX_SERVER is configured"
    missing=1
  fi

  if [[ "$missing" -eq 0 ]]; then
    log info "healthcheck ok"
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      DISCORD_WEBHOOK="${2:-}"
      shift 2
      ;;
    -b)
      BLACKLIST_RAW="${2:-}"
      shift 2
      ;;
    -g)
      GHCR_TOKEN="${2:-}"
      log warn "-g is deprecated; prefer GHCR_TOKEN env to avoid shell history leaks"
      shift 2
      ;;
    -u)
      GHCR_USERNAME="${2:-}"
      shift 2
      ;;
    -z)
      ZABBIX_SRV="${2:-}"
      shift 2
      ;;
    -n)
      ZABBIX_HOST="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --no-system-update)
      UPDATE_SYSTEM_PACKAGES="false"
      shift
      ;;
    --healthcheck)
      if healthcheck; then
        exit 0
      fi
      exit 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log error "unknown option" "$1"
      usage
      exit 2
      ;;
  esac
done

if ! healthcheck; then
  exit 1
fi

if [[ -n "$GHCR_TOKEN" ]]; then
  if is_true "$DRY_RUN"; then
    log info "dry-run: skip ghcr login"
  else
    printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null 2>&1 || {
      log warn "ghcr login failed" "username=$GHCR_USERNAME"
    }
  fi
fi

IFS=',' read -r -a BLACKLIST <<< "$BLACKLIST_RAW"
is_blacklisted() {
  local pkg="$1"
  local item
  for item in "${BLACKLIST[@]}"; do
    [[ "$pkg" == "$item" ]] && return 0
  done
  return 1
}

send_zabbix_data() {
  local key="$1"
  local value="$2"

  if [[ -z "$ZABBIX_SRV" ]]; then
    return 0
  fi

  if ! command -v zabbix_sender >/dev/null 2>&1; then
    log warn "zabbix_sender not installed; skip metric" "key=$key"
    return 0
  fi

  if zabbix_sender -z "$ZABBIX_SRV" -s "$ZABBIX_HOST" -k "$key" -o "$value" >/dev/null 2>&1; then
    log info "zabbix metric sent" "key=$key"
  else
    log warn "zabbix metric send failed" "key=$key"
  fi
}

maybe_run() {
  if is_true "$DRY_RUN"; then
    log info "dry-run" "$*"
    return 0
  fi
  "$@"
}

update_system_packages() {
  if ! is_true "$UPDATE_SYSTEM_PACKAGES"; then
    log info "system package update disabled"
    return 0
  fi

  if [[ "$EUID" -ne 0 ]]; then
    log warn "system package update skipped: requires root"
    return 0
  fi

  local package
  local candidates=()

  if command -v dnf >/dev/null 2>&1; then
    mapfile -t candidates < <(dnf -q check-update 2>/dev/null | awk 'NR>2 {print $1}' | sed '/^$/d')
    for package in "${candidates[@]}"; do
      if is_blacklisted "$package"; then
        PAQUET_UPDATE+="${package}"$'\n'
        ((PAQUET_NB+=1))
        continue
      fi

      if maybe_run dnf -y upgrade "$package" >/dev/null 2>&1; then
        UPDATED+="📦${package}"$'\n'
      else
        PAQUET_UPDATE+="${package}"$'\n'
      fi
    done
  elif command -v apt-get >/dev/null 2>&1; then
    maybe_run apt-get update -y >/dev/null 2>&1 || true
    mapfile -t candidates < <(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1)
    for package in "${candidates[@]}"; do
      [[ -z "$package" ]] && continue
      if is_blacklisted "$package"; then
        PAQUET_UPDATE+="${package}"$'\n'
        ((PAQUET_NB+=1))
        continue
      fi

      if maybe_run apt-get --only-upgrade install -y "$package" >/dev/null 2>&1; then
        UPDATED+="📦${package}"$'\n'
      else
        PAQUET_UPDATE+="${package}"$'\n'
      fi
    done
  else
    log warn "no supported package manager found (dnf/apt-get)"
  fi

  send_zabbix_data "update.paquets" "$PAQUET_NB"
}

container_update_method() {
  local container="$1"
  local image="$2"

  local docker_compose_file
  docker_compose_file="$(docker container inspect "$container" | jq -r '.[0].Config.Labels["autoupdate.docker-compose"] // empty')"
  if [[ -n "$docker_compose_file" ]]; then
    if maybe_run docker pull "$image" >/dev/null 2>&1; then
      if docker compose version >/dev/null 2>&1; then
        if maybe_run docker compose -f "$docker_compose_file" up -d --force-recreate; then
          return 0
        fi
        log error "compose update failed" "container=$container compose_file=$docker_compose_file"
        return 1
      elif command -v docker-compose >/dev/null 2>&1; then
        if maybe_run docker-compose -f "$docker_compose_file" up -d --force-recreate; then
          return 0
        fi
        log error "docker-compose update failed" "container=$container compose_file=$docker_compose_file"
        return 1
      else
        log error "no compose binary found" "container=$container"
        return 1
      fi
    fi
    return 1
  fi

  local portainer_webhook
  portainer_webhook="$(docker container inspect "$container" | jq -r '.[0].Config.Labels["autoupdate.webhook"] // empty')"
  if [[ -n "$portainer_webhook" ]]; then
    if is_true "$DRY_RUN"; then
      log info "dry-run: skip portainer webhook" "container=$container"
    else
      curl -sS -m "$DOCKER_TIMEOUT" -X POST "$portainer_webhook" >/dev/null
    fi
    return 0
  fi

  local docker_run
  docker_run="$(docker container inspect "$container" | jq -r '.[0].Config.Labels["autoupdate.docker-run"] // empty')"
  if [[ -n "$docker_run" ]]; then
    if is_true "$ALLOW_LEGACY_DOCKER_RUN"; then
      log warn "legacy docker-run mode requested but intentionally unsupported in v2 for security"
    else
      log warn "legacy docker-run mode skipped" "container=$container"
    fi
    return 1
  fi

  log warn "no update method label found" "container=$container"
  return 1
}

check_containers() {
  if ! docker info >/dev/null 2>&1; then
    log warn "docker daemon not reachable; skip container checks"
    return 0
  fi

  local container
  local autoupdate
  local image
  local before_id
  local after_id

  mapfile -t containers < <(docker ps --format '{{.Names}}')

  for container in "${containers[@]}"; do
    autoupdate="$(docker container inspect "$container" | jq -r '.[0].Config.Labels["autoupdate"] // empty')"
    [[ -z "$autoupdate" ]] && continue

    image="$(docker container inspect "$container" | jq -r '.[0].Config.Image')"
    before_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    if [[ -z "$before_id" ]]; then
      ERROR_C+="${image}"$'\n'
      ERROR_M+="LOCAL_IMAGE_NOT_FOUND"$'\n'
      continue
    fi

    if ! maybe_run docker pull "$image" >/dev/null 2>&1; then
      ERROR_C+="${image}"$'\n'
      ERROR_M+="PULL_FAILED"$'\n'
      continue
    fi

    after_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    if [[ "$before_id" == "$after_id" ]]; then
      log info "container image up-to-date" "container=$container image=$image"
      continue
    fi

    UPDATE+="${image}"$'\n'
    CONTAINERS+="${container}"$'\n'
    CONTAINERS_Z+="${container} "
    ((CONTAINERS_NB+=1))

    if [[ "$autoupdate" == "monitor" ]]; then
      log info "update available (monitor only)" "container=$container image=$image"
      continue
    fi

    if [[ "$autoupdate" == "true" ]]; then
      if container_update_method "$container" "$image"; then
        UPDATED+="🐳${container}"$'\n'
        UPDATED_Z+="${container} "
        ((CONTAINERS_NB_U+=1))
      else
        ERROR_C+="${image}"$'\n'
        ERROR_M+="UPDATE_METHOD_FAILED"$'\n'
      fi
    fi
  done

  maybe_run docker image prune -f >/dev/null 2>&1 || true
}

send_discord() {
  if [[ -z "$DISCORD_WEBHOOK" ]]; then
    return 0
  fi

  local title="✅ Tout est à jour"
  local color=5832543

  if [[ -n "$ERROR_C" ]]; then
    title="❌ Erreurs pendant la vérification"
    color=16734296
  elif [[ -n "$UPDATE" || -n "$PAQUET_UPDATE" ]]; then
    title="🚸 Mises à jour disponibles"
    color=16759896
  elif [[ -n "$UPDATED" ]]; then
    title="🚀 Mises à jour appliquées"
    color=5832543
  fi

  local payload
  payload="$(jq -cn \
    --arg username "[$ZABBIX_HOST]" \
    --arg title "$title" \
    --argjson color "$color" \
    --arg host "$ZABBIX_HOST" \
    --arg packages "$PAQUET_UPDATE" \
    --arg containers "$CONTAINERS" \
    --arg images "$UPDATE" \
    --arg updated "$UPDATED" \
    --arg errors_img "$ERROR_C" \
    --arg errors_msg "$ERROR_M" \
    '{
      username:$username,
      content:null,
      embeds:[
        {
          title:$title,
          color:$color,
          author:{name:$host},
          fields:(
            [
              (if $packages != "" then {name:"Packages", value:$packages, inline:true} else empty end),
              (if $containers != "" then {name:"Containers", value:$containers, inline:true} else empty end),
              (if $images != "" then {name:"Images", value:$images, inline:true} else empty end),
              (if $updated != "" then {name:"Updated", value:$updated, inline:false} else empty end),
              (if $errors_img != "" then {name:"Images en erreur", value:$errors_img, inline:true} else empty end),
              (if $errors_msg != "" then {name:"Erreurs", value:$errors_msg, inline:true} else empty end)
            ]
          )
        }
      ]
    }')"

  if is_true "$DRY_RUN"; then
    log info "dry-run: discord payload generated"
    return 0
  fi

  curl -sS -m "$DOCKER_TIMEOUT" -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK" >/dev/null
}

main() {
  log info "container-updater start" "version=$SCRIPT_VERSION"
  update_system_packages
  check_containers

  send_zabbix_data "update.container_to_update_nb" "$CONTAINERS_NB"
  send_zabbix_data "update.container_to_update_names" "$CONTAINERS_Z"
  send_zabbix_data "update.container_updated_nb" "$CONTAINERS_NB_U"
  send_zabbix_data "update.container_updated_names" "$UPDATED_Z"

  send_discord
  log info "container-updater end" "containers_to_update=$CONTAINERS_NB containers_updated=$CONTAINERS_NB_U"
}

main "$@"

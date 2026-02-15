#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.1.3"

# -----------------------------
# Defaults (can be overridden by env or CLI)
# -----------------------------
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
BLACKLIST_RAW="${BLACKLIST:-}"
GHCR_TOKEN="${GHCR_TOKEN:-${AUTH_GITHUB:-}}"
GHCR_USERNAME="${GHCR_USERNAME:-${GITHUB_USERNAME:-oauth2}}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
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
WORKLOAD_DISCOVERED_NB=0
WORKLOAD_MANAGED_NB=0
WORKLOAD_UP_TO_DATE_NB=0
WORKLOAD_MONITOR_ONLY_NB=0
WORKLOAD_UPDATED_APPLIED_NB=0
WORKLOAD_UPDATED_SIMULATED_NB=0
WORKLOAD_UPDATE_FAILED_NB=0
WORKLOAD_CHECK_SKIPPED_NB=0
LAST_UPDATE_METHOD="unknown"
REMOTE_DIGEST_LAST_ERROR=""
PULL_LAST_ERROR=""

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
    1 | true | yes | on) return 0 ;;
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
  DOCKERHUB_USERNAME, DOCKERHUB_TOKEN,
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
    -h | --help)
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

if [[ -n "$DOCKERHUB_USERNAME" && -n "$DOCKERHUB_TOKEN" ]]; then
  if is_true "$DRY_RUN"; then
    log info "dry-run: skip docker hub login"
  else
    printf '%s' "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin >/dev/null 2>&1 || {
      log warn "docker hub login failed" "username=$DOCKERHUB_USERNAME"
    }
  fi
fi

IFS=',' read -r -a BLACKLIST <<<"$BLACKLIST_RAW"
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

record_update_success() {
  local workload="$1"
  local image="$2"
  local method="$3"

  if is_true "$DRY_RUN"; then
    ((WORKLOAD_UPDATED_SIMULATED_NB += 1))
    log info "update simulated" "workload=$workload image=$image method=$method"
  else
    ((WORKLOAD_UPDATED_APPLIED_NB += 1))
    log info "update applied" "workload=$workload image=$image method=$method"
  fi
}

record_update_failure() {
  local workload="$1"
  local image="$2"
  local reason="$3"

  ((WORKLOAD_UPDATE_FAILED_NB += 1))
  log error "update failed" "workload=$workload image=$image reason=$reason"
}

is_rate_limited_error() {
  local message="${1,,}"
  [[ "$message" == *"toomanyrequests"* || "$message" == *"rate limit"* ]]
}

compact_error_message() {
  local message="$1"
  printf '%s' "$message" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //; s/ $//'
}

log_run_summary() {
  local mode="$1"
  local execution_result

  if is_true "$DRY_RUN"; then
    execution_result="dry-run"
  else
    execution_result="live"
  fi

  log info "run summary" \
    "mode=$mode run=$execution_result discovered=$WORKLOAD_DISCOVERED_NB managed=$WORKLOAD_MANAGED_NB up_to_date=$WORKLOAD_UP_TO_DATE_NB updates_available=$CONTAINERS_NB monitor_only=$WORKLOAD_MONITOR_ONLY_NB applied=$WORKLOAD_UPDATED_APPLIED_NB simulated=$WORKLOAD_UPDATED_SIMULATED_NB failed=$WORKLOAD_UPDATE_FAILED_NB checks_skipped=$WORKLOAD_CHECK_SKIPPED_NB"
}

detect_execution_mode() {
  local swarm_state
  local control_available

  if ! docker info >/dev/null 2>&1; then
    echo "docker-unavailable"
    return 0
  fi

  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
  control_available="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "false")"

  if [[ "$swarm_state" != "active" ]]; then
    echo "standalone"
    return 0
  fi

  if [[ "$control_available" == "true" ]]; then
    echo "swarm-manager"
  else
    echo "swarm-worker"
  fi
}

image_repo_from_ref() {
  local image_ref="$1"
  local image_no_digest
  local image_last_segment
  local image_base
  local image_name

  image_no_digest="${image_ref%@*}"
  image_last_segment="${image_no_digest##*/}"

  if [[ "$image_last_segment" == *:* ]]; then
    image_base="${image_no_digest%/*}"
    image_name="${image_last_segment%%:*}"
    if [[ "$image_base" == "$image_no_digest" ]]; then
      printf '%s\n' "$image_name"
    else
      printf '%s/%s\n' "$image_base" "$image_name"
    fi
    return 0
  fi

  printf '%s\n' "$image_no_digest"
}

get_local_digest_for_image() {
  local image_ref="$1"
  local image_repo
  local image_digest

  image_repo="$(image_repo_from_ref "$image_ref")"
  image_digest="$(
    docker image inspect "$image_ref" 2>/dev/null |
      jq -r --arg repo "$image_repo" '.[0].RepoDigests[]? | select(startswith($repo + "@")) | split("@")[1]' |
      head -n 1 || true
  )"
  printf '%s\n' "$image_digest"
}

normalize_architecture() {
  case "${1,,}" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    *) echo "${1,,}" ;;
  esac
}

get_remote_digest_for_image() {
  local image_ref="$1"
  local node_arch
  local manifest_payload
  local manifest_error
  local manifest_error_file
  local remote_digest

  REMOTE_DIGEST_LAST_ERROR=""
  node_arch="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
  node_arch="$(normalize_architecture "${node_arch:-amd64}")"

  manifest_error_file="$(mktemp)"
  manifest_payload="$(docker manifest inspect "$image_ref" 2>"$manifest_error_file" || true)"
  manifest_error="$(cat "$manifest_error_file" 2>/dev/null || true)"
  rm -f "$manifest_error_file"

  if [[ -z "$manifest_payload" ]]; then
    REMOTE_DIGEST_LAST_ERROR="$(compact_error_message "$manifest_error")"
    printf '\n'
    return 0
  fi

  remote_digest="$(
    jq -r --arg arch "$node_arch" '
      (
        [ .manifests[]? | select((.platform.os // "linux") == "linux" and .platform.architecture == $arch) | .digest ] | .[0]
      ) // .digest // empty
    ' <<<"$manifest_payload" | head -n 1 || true
  )"
  if [[ -z "$remote_digest" ]]; then
    REMOTE_DIGEST_LAST_ERROR="remote digest not found for architecture=$node_arch"
  fi
  printf '%s\n' "$remote_digest"
}

pull_image_with_status() {
  local image_ref="$1"
  local pull_error_file

  PULL_LAST_ERROR=""

  if is_true "$DRY_RUN"; then
    maybe_run docker pull "$image_ref" >/dev/null 2>&1
    return 0
  fi

  pull_error_file="$(mktemp)"
  if docker pull "$image_ref" >/dev/null 2>"$pull_error_file"; then
    rm -f "$pull_error_file"
    return 0
  fi

  PULL_LAST_ERROR="$(compact_error_message "$(cat "$pull_error_file" 2>/dev/null || true)")"
  rm -f "$pull_error_file"
  return 1
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
        ((PAQUET_NB += 1))
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
        ((PAQUET_NB += 1))
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

  LAST_UPDATE_METHOD="unknown"

  local docker_compose_file
  docker_compose_file="$(docker container inspect "$container" | jq -r '.[0].Config.Labels["autoupdate.docker-compose"] // empty')"
  if [[ -n "$docker_compose_file" ]]; then
    if maybe_run docker pull "$image" >/dev/null 2>&1; then
      if docker compose version >/dev/null 2>&1; then
        if maybe_run docker compose -f "$docker_compose_file" up -d --force-recreate; then
          LAST_UPDATE_METHOD="docker-compose-v2"
          return 0
        fi
        log error "compose update failed" "container=$container compose_file=$docker_compose_file"
        return 1
      elif command -v docker-compose >/dev/null 2>&1; then
        if maybe_run docker-compose -f "$docker_compose_file" up -d --force-recreate; then
          LAST_UPDATE_METHOD="docker-compose-v1"
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
    LAST_UPDATE_METHOD="portainer-webhook"
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

swarm_update_method() {
  local service="$1"
  local image="$2"
  local docker_compose_file="$3"
  local portainer_webhook="$4"
  local cmd

  LAST_UPDATE_METHOD="unknown"

  if [[ -n "$docker_compose_file" ]]; then
    log warn "autoupdate.docker-compose ignored in swarm mode" "service=$service compose_file=$docker_compose_file"
  fi

  if [[ -n "$portainer_webhook" ]]; then
    LAST_UPDATE_METHOD="portainer-webhook"
    if is_true "$DRY_RUN"; then
      log info "dry-run: skip portainer webhook" "service=$service"
      return 0
    fi

    if curl -sS -m "$DOCKER_TIMEOUT" -X POST "$portainer_webhook" >/dev/null; then
      return 0
    fi
    log error "portainer webhook failed" "service=$service"
    return 1
  fi

  cmd=(docker service update --image "$image" --detach=false)
  if [[ -n "$GHCR_TOKEN" ]]; then
    cmd+=(--with-registry-auth)
  fi
  cmd+=("$service")
  LAST_UPDATE_METHOD="swarm-service-update"

  if maybe_run "${cmd[@]}" >/dev/null 2>&1; then
    return 0
  fi
  log error "swarm service update failed" "service=$service image=$image"
  return 1
}

check_swarm_services() {
  local service
  local inspect_data
  local autoupdate_label_service
  local autoupdate_label_task
  local autoupdate
  local compose_label_service
  local compose_label_task
  local compose_label
  local webhook_label_service
  local webhook_label_task
  local webhook_label
  local service_image
  local service_image_no_digest
  local service_digest
  local remote_digest
  local local_digest
  local before_id
  local after_id
  local update_available
  local -a services

  mapfile -t services < <(docker service ls --format '{{.Name}}')
  log info "swarm scan started" "services=${#services[@]}"

  for service in "${services[@]}"; do
    [[ -z "$service" ]] && continue
    ((WORKLOAD_DISCOVERED_NB += 1))

    inspect_data="$(docker service inspect "$service" 2>/dev/null || true)"
    if [[ -z "$inspect_data" ]]; then
      ERROR_C+="${service}"$'\n'
      ERROR_M+="SERVICE_INSPECT_FAILED"$'\n'
      record_update_failure "$service" "unknown" "SERVICE_INSPECT_FAILED"
      continue
    fi

    autoupdate_label_service="$(jq -r '.[0].Spec.Labels["autoupdate"] // empty' <<<"$inspect_data")"
    autoupdate_label_task="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Labels["autoupdate"] // empty' <<<"$inspect_data")"
    if [[ -n "$autoupdate_label_service" ]]; then
      autoupdate="$autoupdate_label_service"
    else
      autoupdate="$autoupdate_label_task"
      if [[ -n "$autoupdate" ]]; then
        log info "swarm label fallback applied" "service=$service label=autoupdate source=task-template"
      fi
    fi
    [[ -z "$autoupdate" ]] && continue
    ((WORKLOAD_MANAGED_NB += 1))

    compose_label_service="$(jq -r '.[0].Spec.Labels["autoupdate.docker-compose"] // empty' <<<"$inspect_data")"
    compose_label_task="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Labels["autoupdate.docker-compose"] // empty' <<<"$inspect_data")"
    if [[ -n "$compose_label_service" ]]; then
      compose_label="$compose_label_service"
    else
      compose_label="$compose_label_task"
      if [[ -n "$compose_label" ]]; then
        log info "swarm label fallback applied" "service=$service label=autoupdate.docker-compose source=task-template"
      fi
    fi

    webhook_label_service="$(jq -r '.[0].Spec.Labels["autoupdate.webhook"] // empty' <<<"$inspect_data")"
    webhook_label_task="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Labels["autoupdate.webhook"] // empty' <<<"$inspect_data")"
    if [[ -n "$webhook_label_service" ]]; then
      webhook_label="$webhook_label_service"
    else
      webhook_label="$webhook_label_task"
      if [[ -n "$webhook_label" ]]; then
        log info "swarm label fallback applied" "service=$service label=autoupdate.webhook source=task-template"
      fi
    fi

    service_image="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Image // empty' <<<"$inspect_data")"
    if [[ -z "$service_image" ]]; then
      ERROR_C+="${service}"$'\n'
      ERROR_M+="SERVICE_IMAGE_NOT_FOUND"$'\n'
      record_update_failure "$service" "unknown" "SERVICE_IMAGE_NOT_FOUND"
      continue
    fi

    service_image_no_digest="${service_image%@*}"
    service_digest=""
    if [[ "$service_image" == *@* ]]; then
      service_digest="${service_image##*@}"
    fi

    update_available="false"
    remote_digest="$(get_remote_digest_for_image "$service_image_no_digest")"

    if [[ -n "$service_digest" && -n "$remote_digest" ]]; then
      if [[ "$service_digest" != "$remote_digest" ]]; then
        update_available="true"
      fi
    else
      if [[ -n "$REMOTE_DIGEST_LAST_ERROR" ]]; then
        if is_rate_limited_error "$REMOTE_DIGEST_LAST_ERROR"; then
          ((WORKLOAD_CHECK_SKIPPED_NB += 1))
          log warn "registry check skipped (rate limit)" "service=$service image=$service_image_no_digest details=$REMOTE_DIGEST_LAST_ERROR"
          continue
        fi
        log warn "remote digest unavailable; fallback to local pull check" "service=$service image=$service_image_no_digest details=$REMOTE_DIGEST_LAST_ERROR"
      fi

      before_id="$(docker image inspect -f '{{.Id}}' "$service_image_no_digest" 2>/dev/null || true)"
      if ! pull_image_with_status "$service_image_no_digest"; then
        if is_true "$DRY_RUN"; then
          log warn "dry-run: unable to verify remote digest and pull is disabled" "service=$service image=$service_image_no_digest"
        elif is_rate_limited_error "$PULL_LAST_ERROR"; then
          ((WORKLOAD_CHECK_SKIPPED_NB += 1))
          log warn "registry check skipped (rate limit)" "service=$service image=$service_image_no_digest details=$PULL_LAST_ERROR"
        else
          ERROR_C+="${service_image_no_digest}"$'\n'
          ERROR_M+="PULL_FAILED"$'\n'
          record_update_failure "$service" "$service_image_no_digest" "PULL_FAILED"
        fi
        continue
      fi

      after_id="$(docker image inspect -f '{{.Id}}' "$service_image_no_digest" 2>/dev/null || true)"
      local_digest="$(get_local_digest_for_image "$service_image_no_digest")"

      if [[ -n "$service_digest" && -n "$local_digest" ]]; then
        if [[ "$service_digest" != "$local_digest" ]]; then
          update_available="true"
        fi
      else
        if [[ "$before_id" != "$after_id" ]]; then
          update_available="true"
        fi
      fi
    fi

    if [[ "$update_available" == "false" ]]; then
      ((WORKLOAD_UP_TO_DATE_NB += 1))
      log info "service image up-to-date" "service=$service image=$service_image_no_digest"
      continue
    fi

    UPDATE+="${service_image_no_digest}"$'\n'
    CONTAINERS+="${service}"$'\n'
    CONTAINERS_Z+="${service} "
    ((CONTAINERS_NB += 1))
    log info "update available" "service=$service image=$service_image_no_digest autoupdate=$autoupdate"

    if [[ "$autoupdate" == "monitor" ]]; then
      ((WORKLOAD_MONITOR_ONLY_NB += 1))
      log info "update available (monitor only)" "service=$service image=$service_image_no_digest"
      continue
    fi

    if [[ "$autoupdate" == "true" ]]; then
      if swarm_update_method "$service" "$service_image_no_digest" "$compose_label" "$webhook_label"; then
        UPDATED+="🐳${service}"$'\n'
        UPDATED_Z+="${service} "
        ((CONTAINERS_NB_U += 1))
        record_update_success "$service" "$service_image_no_digest" "$LAST_UPDATE_METHOD"
      else
        ERROR_C+="${service_image_no_digest}"$'\n'
        ERROR_M+="SERVICE_UPDATE_FAILED"$'\n'
        record_update_failure "$service" "$service_image_no_digest" "SERVICE_UPDATE_FAILED"
      fi
      continue
    fi

    log warn "unsupported autoupdate label value" "service=$service autoupdate=$autoupdate"
  done

  maybe_run docker image prune -f >/dev/null 2>&1 || true
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
  log info "standalone scan started" "containers=${#containers[@]}"

  for container in "${containers[@]}"; do
    ((WORKLOAD_DISCOVERED_NB += 1))

    autoupdate="$(docker container inspect "$container" | jq -r '.[0].Config.Labels["autoupdate"] // empty')"
    [[ -z "$autoupdate" ]] && continue
    ((WORKLOAD_MANAGED_NB += 1))

    image="$(docker container inspect "$container" | jq -r '.[0].Config.Image')"
    before_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    if [[ -z "$before_id" ]]; then
      ERROR_C+="${image}"$'\n'
      ERROR_M+="LOCAL_IMAGE_NOT_FOUND"$'\n'
      record_update_failure "$container" "$image" "LOCAL_IMAGE_NOT_FOUND"
      continue
    fi

    if ! maybe_run docker pull "$image" >/dev/null 2>&1; then
      ERROR_C+="${image}"$'\n'
      ERROR_M+="PULL_FAILED"$'\n'
      record_update_failure "$container" "$image" "PULL_FAILED"
      continue
    fi

    after_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    if [[ "$before_id" == "$after_id" ]]; then
      ((WORKLOAD_UP_TO_DATE_NB += 1))
      log info "container image up-to-date" "container=$container image=$image"
      continue
    fi

    UPDATE+="${image}"$'\n'
    CONTAINERS+="${container}"$'\n'
    CONTAINERS_Z+="${container} "
    ((CONTAINERS_NB += 1))
    log info "update available" "container=$container image=$image autoupdate=$autoupdate"

    if [[ "$autoupdate" == "monitor" ]]; then
      ((WORKLOAD_MONITOR_ONLY_NB += 1))
      log info "update available (monitor only)" "container=$container image=$image"
      continue
    fi

    if [[ "$autoupdate" == "true" ]]; then
      if container_update_method "$container" "$image"; then
        UPDATED+="🐳${container}"$'\n'
        UPDATED_Z+="${container} "
        ((CONTAINERS_NB_U += 1))
        record_update_success "$container" "$image" "$LAST_UPDATE_METHOD"
      else
        ERROR_C+="${image}"$'\n'
        ERROR_M+="UPDATE_METHOD_FAILED"$'\n'
        record_update_failure "$container" "$image" "UPDATE_METHOD_FAILED"
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
              (if $containers != "" then {name:"Workloads", value:$containers, inline:true} else empty end),
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
  local execution_mode
  local zabbix_updated_nb
  local zabbix_updated_names
  local run_mode

  log info "container-updater start" "version=$SCRIPT_VERSION"
  update_system_packages
  execution_mode="$(detect_execution_mode)"
  log info "execution mode detected" "mode=$execution_mode"
  if is_true "$DRY_RUN"; then
    log info "run mode" "dry-run enabled: no mutating actions will be executed"
  fi

  case "$execution_mode" in
    standalone)
      check_containers
      ;;
    swarm-manager)
      check_swarm_services
      ;;
    swarm-worker)
      log warn "swarm worker node: updates skipped (manager required)"
      ;;
    docker-unavailable)
      log warn "docker daemon not reachable; skip container checks"
      ;;
    *)
      log warn "unknown execution mode; skip container checks" "mode=$execution_mode"
      ;;
  esac

  zabbix_updated_nb="$CONTAINERS_NB_U"
  zabbix_updated_names="$UPDATED_Z"
  run_mode="live"
  if is_true "$DRY_RUN"; then
    zabbix_updated_nb="0"
    zabbix_updated_names=""
    run_mode="dry-run"
  fi

  send_zabbix_data "update.container_to_update_nb" "$CONTAINERS_NB"
  send_zabbix_data "update.container_to_update_names" "$CONTAINERS_Z"
  send_zabbix_data "update.container_updated_nb" "$zabbix_updated_nb"
  send_zabbix_data "update.container_updated_names" "$zabbix_updated_names"

  send_discord
  log_run_summary "$execution_mode"
  log info "container-updater end" "updates_available=$CONTAINERS_NB updates_applied=$WORKLOAD_UPDATED_APPLIED_NB updates_simulated=$WORKLOAD_UPDATED_SIMULATED_NB run_mode=$run_mode"
}

main "$@"

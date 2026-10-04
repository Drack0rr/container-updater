#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.2.0"

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
SWARM_UNLABELED_POLICY="${SWARM_UNLABELED_POLICY:-monitor}" # monitor|ignore
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-180}"
UPDATE_POLL_INTERVAL="${UPDATE_POLL_INTERVAL:-3}"

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
WORKLOAD_UNLABELED_NB=0
WORKLOAD_DISABLED_NB=0
WORKLOAD_PENDING_NB=0
LAST_UPDATE_METHOD="unknown"
REMOTE_DIGEST_LAST_ERROR=""
REMOTE_DIGEST=""
REMOTE_DIGESTS="[]"
declare -A MANIFEST_CACHE=()
declare -A MANIFEST_ERRORS=()
declare -A WEBHOOK_RESULTS=()

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
  --unlabeled-policy <mode>   Swarm services without labels: monitor (default)|ignore
  --healthcheck              Validate runtime dependencies and exit
  -h, --help                 Show help

Environment variables:
  DISCORD_WEBHOOK, BLACKLIST, GHCR_TOKEN, GHCR_USERNAME,
  DOCKERHUB_USERNAME, DOCKERHUB_TOKEN,
  ZABBIX_SERVER, ZABBIX_HOST, UPDATE_SYSTEM_PACKAGES,
  ALLOW_LEGACY_DOCKER_RUN, DRY_RUN, LOG_FORMAT, DOCKER_TIMEOUT,
  SWARM_UNLABELED_POLICY, UPDATE_TIMEOUT, UPDATE_POLL_INTERVAL
USAGE
}

healthcheck() {
  local missing=0
  for bin in bash docker jq curl timeout; do
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
    --unlabeled-policy)
      SWARM_UNLABELED_POLICY="${2:-}"
      if [[ $# -lt 2 ]]; then
        log error "--unlabeled-policy requires monitor or ignore"
        exit 2
      fi
      shift 2
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

if [[ "$SWARM_UNLABELED_POLICY" != "monitor" && "$SWARM_UNLABELED_POLICY" != "ignore" ]]; then
  log error "invalid unlabeled policy; expected monitor or ignore"
  exit 2
fi
for duration in "$DOCKER_TIMEOUT" "$UPDATE_TIMEOUT" "$UPDATE_POLL_INTERVAL"; do
  if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
    log error "timeouts and polling interval must be positive integer seconds"
    exit 2
  fi
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
  if is_true "$DRY_RUN"; then
    log info "dry-run: skip zabbix metric" "key=$key"
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
  [[ "$message" == *"toomanyrequests"* || "$message" == *"too many requests"* || "$message" == *"rate limit"* || "$message" == *"429"* ]]
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
    "mode=$mode run=$execution_result discovered=$WORKLOAD_DISCOVERED_NB managed=$WORKLOAD_MANAGED_NB unlabeled=$WORKLOAD_UNLABELED_NB disabled=$WORKLOAD_DISABLED_NB up_to_date=$WORKLOAD_UP_TO_DATE_NB updates_available=$CONTAINERS_NB monitor_only=$WORKLOAD_MONITOR_ONLY_NB applied=$WORKLOAD_UPDATED_APPLIED_NB simulated=$WORKLOAD_UPDATED_SIMULATED_NB pending=$WORKLOAD_PENDING_NB failed=$WORKLOAD_UPDATE_FAILED_NB checks_skipped=$WORKLOAD_CHECK_SKIPPED_NB"
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

# Buildx exposes the registry's top-level digest for both indexes and single
# manifests. Never compare an index digest with just the manager's architecture.
# Results use globals: command substitution would lose the error and cache state.
get_remote_digest_for_image() {
  local image_ref="$1"
  local payload error_file error_text
  REMOTE_DIGEST=""
  REMOTE_DIGESTS='[]'
  REMOTE_DIGEST_LAST_ERROR=""

  if [[ -n "${MANIFEST_ERRORS[$image_ref]:-}" ]]; then
    REMOTE_DIGEST_LAST_ERROR="${MANIFEST_ERRORS[$image_ref]}"
    return 1
  fi
  payload="${MANIFEST_CACHE[$image_ref]:-}"
  if [[ -z "$payload" ]]; then
    error_file="$(mktemp)"
    if ! payload="$(timeout "$DOCKER_TIMEOUT" docker buildx imagetools inspect "$image_ref" --format '{{json .Manifest}}' 2>"$error_file")"; then
      error_text="$(cat "$error_file")"
      rm -f "$error_file"
      REMOTE_DIGEST_LAST_ERROR="REGISTRY_UNAVAILABLE"
      if is_rate_limited_error "$error_text"; then
        REMOTE_DIGEST_LAST_ERROR="REGISTRY_RATE_LIMIT"
      elif [[ "${error_text,,}" == *unauthorized* || "${error_text,,}" == *denied* || "$error_text" == *401* || "$error_text" == *403* ]]; then
        REMOTE_DIGEST_LAST_ERROR="REGISTRY_AUTH_REQUIRED"
      fi
      # Registry errors may contain credentials/URLs: retain only a reason code.
      MANIFEST_ERRORS[$image_ref]="$REMOTE_DIGEST_LAST_ERROR"
      return 1
    fi
    rm -f "$error_file"
    if ! jq -e '.digest | strings | test("^sha256:[a-f0-9]{64}$")' <<<"$payload" >/dev/null 2>&1; then
      REMOTE_DIGEST_LAST_ERROR="INVALID_REGISTRY_MANIFEST"
      MANIFEST_ERRORS[$image_ref]="$REMOTE_DIGEST_LAST_ERROR"
      return 1
    fi
    MANIFEST_CACHE[$image_ref]="$payload"
  fi
  REMOTE_DIGEST="$(jq -r '.digest' <<<"$payload")"
  REMOTE_DIGESTS="$(jq -c '[.digest, (.manifests[]? | select(.platform.os != "unknown") | .digest)] | unique' <<<"$payload")"
}

digest_is_current() {
  local digest="$1"
  jq -e --arg digest "$digest" 'index($digest) != null' <<<"$REMOTE_DIGESTS" >/dev/null
}

record_check_skipped() {
  ((WORKLOAD_CHECK_SKIPPED_NB += 1))
  log warn "service image status unknown" "service=$1 reason=$2"
}

# A mutable tag in the service spec is not proof of what is running. Inspect
# current tasks across the cluster, never the manager's unrelated image cache.
get_running_task_digests() {
  local service="$1"
  local task_ids tasks
  TASK_DIGESTS='[]'
  if ! task_ids="$(timeout "$DOCKER_TIMEOUT" docker service ps --no-trunc --filter desired-state=running --format '{{.ID}}' "$service" 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$task_ids" ]] || return 1
  local -a ids
  mapfile -t ids <<<"$task_ids"
  if ! tasks="$(timeout "$DOCKER_TIMEOUT" docker inspect --type task "${ids[@]}" 2>/dev/null)"; then
    return 1
  fi
  if ! jq -e 'length > 0 and all(.[]; .Status.State == "running" and
      (.Spec.ContainerSpec.Image | test("@sha256:[a-f0-9]{64}$")))' <<<"$tasks" >/dev/null 2>&1; then
    return 1
  fi
  TASK_DIGESTS="$(jq -c '[.[].Spec.ContainerSpec.Image | split("@")[1]]' <<<"$tasks")"
}

wait_for_swarm_update() {
  local service="$1"
  local deadline=$((SECONDS + UPDATE_TIMEOUT))
  local data image state replicas desired running
  while ((SECONDS < deadline)); do
    data="$(timeout "$DOCKER_TIMEOUT" docker service inspect "$service" 2>/dev/null || true)"
    if ! jq -e 'length == 1 and .[0].Spec.TaskTemplate.ContainerSpec.Image != null' <<<"$data" >/dev/null 2>&1; then
      log warn "unable to verify submitted update" "service=$service"
      return 2
    fi
    state="$(jq -r '.[0].UpdateStatus.State // empty' <<<"$data")"
    case "$state" in
      paused | rollback_*)
        log error "swarm rollout did not complete" "service=$service state=$state"
        return 1
        ;;
    esac
    image="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Image' <<<"$data")"
    if [[ "$image" == *@* ]] && digest_is_current "${image##*@}" && [[ "$state" != "updating" ]]; then
      replicas="$(timeout "$DOCKER_TIMEOUT" docker service ls --filter "id=$service" --format '{{.Replicas}}' 2>/dev/null || true)"
      if [[ "$replicas" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        running="${BASH_REMATCH[1]}"
        desired="${BASH_REMATCH[2]}"
        if [[ "$running" -eq "$desired" && "$desired" -gt 0 ]] && get_running_task_digests "$service"; then
          if jq -e --argjson expected "$REMOTE_DIGESTS" --argjson desired "$desired" \
            'length == $desired and all(.[]; . as $d | $expected | index($d) != null)' <<<"$TASK_DIGESTS" >/dev/null; then
            return 0
          fi
        fi
      fi
    fi
    sleep "$UPDATE_POLL_INTERVAL"
  done
  log warn "update submitted but convergence not verified before timeout" "service=$service timeout=$UPDATE_TIMEOUT"
  return 2
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
      invoke_portainer_webhook "$portainer_webhook" || return 1
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

invoke_portainer_webhook() {
  local code
  # Do not follow redirects, retry a POST, or print the capability URL.
  if ! code="$(curl -fsS -m "$DOCKER_TIMEOUT" -o /dev/null -w '%{http_code}' -X POST "$1" 2>/dev/null)"; then
    return 1
  fi
  [[ "$code" == 2[0-9][0-9] ]]
}

swarm_update_method() {
  local service="$1"
  local image="$2"
  local docker_compose_file="$3"
  local portainer_webhook="$4"
  local -a cmd
  LAST_UPDATE_METHOD="unknown"

  if [[ -n "$docker_compose_file" ]]; then
    log warn "autoupdate.docker-compose ignored in swarm mode" "service=$service"
  fi

  if [[ -n "$portainer_webhook" ]]; then
    LAST_UPDATE_METHOD="portainer-webhook"
    if is_true "$DRY_RUN"; then
      log info "dry-run: skip portainer webhook" "service=$service"
      return 0
    fi
    if [[ -n "${WEBHOOK_RESULTS[$portainer_webhook]:-}" ]]; then
      log info "shared stack webhook already submitted; verify service only" "service=$service"
      [[ "${WEBHOOK_RESULTS[$portainer_webhook]}" == "accepted" ]]
      return
    fi
    WEBHOOK_RESULTS[$portainer_webhook]="uncertain"
    if invoke_portainer_webhook "$portainer_webhook"; then
      WEBHOOK_RESULTS[$portainer_webhook]="accepted"
      return 0
    fi
    log error "portainer webhook not accepted; no retry" "service=$service"
    return 1
  fi

  # Pin exactly the registry result we checked, then verify the asynchronous
  # rollout ourselves with a bounded wait (including paused/rolled back states).
  cmd=(timeout "$DOCKER_TIMEOUT" docker service update --image "$image" --detach=true)
  if [[ -n "$GHCR_TOKEN" || -n "$DOCKERHUB_TOKEN" ]]; then
    cmd+=(--with-registry-auth)
  fi
  cmd+=("$service")
  LAST_UPDATE_METHOD="swarm-service-update"
  if maybe_run "${cmd[@]}" >/dev/null 2>&1; then
    return 0
  fi
  log error "swarm service update command failed; no retry" "service=$service"
  return 1
}

check_swarm_services() {
  local service service_id inspect_data listing current_data version
  local service_policy task_policy autoupdate compose_label webhook_label
  local service_image image_tag service_digest check_status verify_status
  local buildx_available=true
  local -a services

  if ! listing="$(timeout "$DOCKER_TIMEOUT" docker service ls --format '{{.Name}}' 2>/dev/null)"; then
    record_update_failure "swarm" "unknown" "SERVICE_LIST_FAILED"
    return 0
  fi
  services=()
  if [[ -n "$listing" ]]; then
    mapfile -t services <<<"$listing"
  fi
  if ! docker buildx version >/dev/null 2>&1; then
    buildx_available=false
    log warn "Docker Buildx is required for registry checks; install docker-buildx-plugin"
  fi
  log info "swarm scan started" "services=${#services[@]} unlabeled_policy=$SWARM_UNLABELED_POLICY"

  for service in "${services[@]}"; do
    ((WORKLOAD_DISCOVERED_NB += 1))
    inspect_data="$(timeout "$DOCKER_TIMEOUT" docker service inspect "$service" 2>/dev/null || true)"
    if ! jq -e 'length == 1 and .[0].ID != null and .[0].Version.Index != null' <<<"$inspect_data" >/dev/null 2>&1; then
      record_update_failure "$service" "unknown" "SERVICE_INSPECT_FAILED"
      continue
    fi
    service_id="$(jq -r '.[0].ID' <<<"$inspect_data")"
    version="$(jq -r '.[0].Version.Index' <<<"$inspect_data")"
    service_policy="$(jq -r '.[0].Spec.Labels["autoupdate"] // empty' <<<"$inspect_data")"
    task_policy="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Labels["autoupdate"] // empty' <<<"$inspect_data")"
    autoupdate="$service_policy"
    if [[ -z "$autoupdate" ]]; then
      autoupdate="$task_policy"
      if [[ -n "$autoupdate" ]]; then
        log info "swarm label fallback applied" "service=$service label=autoupdate source=task-template"
      else
        ((WORKLOAD_UNLABELED_NB += 1))
        autoupdate="$SWARM_UNLABELED_POLICY"
        log info "service has no autoupdate label" "service=$service policy=$autoupdate"
      fi
    fi
    case "$autoupdate" in
      false | ignore)
        ((WORKLOAD_DISABLED_NB += 1))
        log info "service excluded by update policy" "service=$service policy=$autoupdate"
        continue
        ;;
      true | monitor) ((WORKLOAD_MANAGED_NB += 1)) ;;
      *)
        record_check_skipped "$service" "INVALID_AUTOUPDATE_POLICY"
        continue
        ;;
    esac

    if jq -e '.[0].Spec.Mode | has("ReplicatedJob") or has("GlobalJob") or (.Replicated.Replicas == 0)' <<<"$inspect_data" >/dev/null; then
      record_check_skipped "$service" "STOPPED_OR_JOB_SERVICE"
      continue
    fi
    service_image="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Image // empty' <<<"$inspect_data")"
    if [[ -z "$service_image" ]]; then
      record_check_skipped "$service" "SERVICE_IMAGE_NOT_FOUND"
      continue
    fi
    image_tag="${service_image%@*}"
    service_digest=""
    if [[ "$service_image" == *@* ]]; then
      service_digest="${service_image##*@}"
      if [[ "${image_tag##*/}" != *:* ]]; then
        record_check_skipped "$service" "DIGEST_ONLY_REFERENCE_NO_TAG"
        continue
      fi
    elif [[ "${image_tag##*/}" != *:* ]]; then
      # Preserve Docker's implicit latest tag when pinning the update digest.
      image_tag+=":latest"
    fi
    if [[ "$buildx_available" == false ]]; then
      record_check_skipped "$service" "BUILDX_UNAVAILABLE"
      continue
    fi
    if ! get_remote_digest_for_image "$image_tag"; then
      record_check_skipped "$service" "$REMOTE_DIGEST_LAST_ERROR"
      continue
    fi
    check_status="outdated"
    if [[ -n "$service_digest" ]]; then
      if digest_is_current "$service_digest"; then
        check_status="current"
      fi
    elif get_running_task_digests "$service_id"; then
      if jq -e --argjson expected "$REMOTE_DIGESTS" 'all(.[]; . as $d | $expected | index($d) != null)' <<<"$TASK_DIGESTS" >/dev/null; then
        check_status="current"
      fi
    else
      record_check_skipped "$service" "RUNNING_IMAGE_DIGEST_UNKNOWN"
      continue
    fi
    if [[ "$check_status" == current ]]; then
      ((WORKLOAD_UP_TO_DATE_NB += 1))
      log info "service image up-to-date" "service=$service image=$image_tag"
      continue
    fi

    UPDATE+="${image_tag}"$'\n'
    CONTAINERS+="${service}"$'\n'
    CONTAINERS_Z+="${service} "
    ((CONTAINERS_NB += 1))
    log info "update available" "service=$service image=$image_tag autoupdate=$autoupdate"
    if [[ "$autoupdate" == monitor ]]; then
      ((WORKLOAD_MONITOR_ONLY_NB += 1))
      log info "update available (monitor only)" "service=$service image=$image_tag"
      continue
    fi

    # Re-read the stable ID and version immediately before any mutation. A
    # concurrent redeploy requires a new scan, not overwriting somebody's work.
    current_data="$(timeout "$DOCKER_TIMEOUT" docker service inspect "$service_id" 2>/dev/null || true)"
    if ! jq -e --arg id "$service_id" --arg version "$version" \
      '.[0].ID == $id and (.[0].Version.Index | tostring) == $version' <<<"$current_data" >/dev/null 2>&1; then
      record_check_skipped "$service" "SERVICE_CHANGED_DURING_SCAN"
      continue
    fi
    compose_label="$(jq -r '.[0] | .Spec.Labels["autoupdate.docker-compose"] // .Spec.TaskTemplate.ContainerSpec.Labels["autoupdate.docker-compose"] // empty' <<<"$inspect_data")"
    webhook_label="$(jq -r '.[0] | .Spec.Labels["autoupdate.webhook"] // .Spec.TaskTemplate.ContainerSpec.Labels["autoupdate.webhook"] // empty' <<<"$inspect_data")"
    if ! swarm_update_method "$service_id" "$image_tag@$REMOTE_DIGEST" "$compose_label" "$webhook_label"; then
      record_update_failure "$service" "$image_tag" "UPDATE_SUBMISSION_FAILED_OR_UNCERTAIN"
      continue
    fi
    if is_true "$DRY_RUN"; then
      record_update_success "$service" "$image_tag" "$LAST_UPDATE_METHOD"
      continue
    fi
    log info "update submitted; verifying swarm convergence" "service=$service method=$LAST_UPDATE_METHOD"
    verify_status=0
    wait_for_swarm_update "$service_id" || verify_status=$?
    case "$verify_status" in
      0)
        UPDATED+="🐳${service}"$'\n'
        UPDATED_Z+="${service} "
        ((CONTAINERS_NB_U += 1))
        record_update_success "$service" "$image_tag" "$LAST_UPDATE_METHOD"
        ;;
      2)
        ((WORKLOAD_PENDING_NB += 1))
        log warn "update pending verification" "service=$service image=$image_tag"
        ;;
      *) record_update_failure "$service" "$image_tag" "ROLLOUT_FAILED" ;;
    esac
  done
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
    if [[ -z "$autoupdate" || "$autoupdate" == false ]]; then
      ((WORKLOAD_DISABLED_NB += 1))
      log info "container excluded by update policy" "container=$container"
      continue
    fi
    if [[ "$autoupdate" != true && "$autoupdate" != monitor ]]; then
      ((WORKLOAD_CHECK_SKIPPED_NB += 1))
      log warn "invalid autoupdate policy" "container=$container"
      continue
    fi
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

  local title="✅ Images vérifiées à jour (périmètre configuré)"
  local color=5832543

  if [[ -n "$ERROR_C" || "$WORKLOAD_UPDATE_FAILED_NB" -gt 0 ]]; then
    title="❌ Erreurs pendant la vérification"
    color=16734296
  elif [[ "$WORKLOAD_CHECK_SKIPPED_NB" -gt 0 || "$WORKLOAD_PENDING_NB" -gt 0 ]]; then
    title="⚠️ Vérification incomplète"
    color=16759896
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
    --arg coverage "Vérifications indéterminées: $WORKLOAD_CHECK_SKIPPED_NB ; mises à jour non vérifiées: $WORKLOAD_PENDING_NB ; échecs: $WORKLOAD_UPDATE_FAILED_NB ; exclus: $WORKLOAD_DISABLED_NB" \
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
              {name:"Couverture", value:$coverage, inline:false},
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
  if [[ "$WORKLOAD_UPDATE_FAILED_NB" -gt 0 || "$WORKLOAD_CHECK_SKIPPED_NB" -gt 0 || "$WORKLOAD_PENDING_NB" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"

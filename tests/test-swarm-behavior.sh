#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/container-updater.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CURRENT_LOG_FILE=""
CURRENT_OUTPUT_FILE=""

fail() {
  local message="$1"
  echo "FAIL: $message" >&2
  echo "--- script output ---" >&2
  cat "$CURRENT_OUTPUT_FILE" >&2
  echo "--- mock log ---" >&2
  cat "$CURRENT_LOG_FILE" >&2
  exit 1
}

assert_output_contains() {
  local pattern="$1"
  grep -Fq "$pattern" "$CURRENT_OUTPUT_FILE" || fail "output missing: $pattern"
}

assert_log_contains() {
  local pattern="$1"
  grep -Fq "$pattern" "$CURRENT_LOG_FILE" || fail "log missing: $pattern"
}

assert_log_not_contains() {
  local pattern="$1"
  if grep -Fq "$pattern" "$CURRENT_LOG_FILE"; then
    fail "unexpected log pattern: $pattern"
  fi
}

create_mock_bin() {
  local mock_bin="$1"

  mkdir -p "$mock_bin"

  cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="${MOCK_LOG_FILE:?}"
STATE_FILE="${MOCK_STATE_FILE:?}"
SCENARIO="${MOCK_SCENARIO:?}"

echo "docker $*" >>"$LOG_FILE"

is_pulled() {
  local image="$1"
  [[ -f "$STATE_FILE" ]] && grep -Fxq "$image" "$STATE_FILE"
}

mark_pulled() {
  local image="$1"
  if ! is_pulled "$image"; then
    echo "$image" >>"$STATE_FILE"
  fi
}

image_repo() {
  local image="$1"
  local image_no_digest
  local image_last_segment
  local image_base
  local image_name

  image_no_digest="${image%@*}"
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

image_old_id() {
  local image="$1"
  case "$image" in
    example/standalone:latest) echo "sha256:standalone-old-id" ;;
    *) echo "sha256:svc-old-id" ;;
  esac
}

image_new_id() {
  local image="$1"
  case "$image" in
    example/standalone:latest) echo "sha256:standalone-new-id" ;;
    *) echo "sha256:svc-new-id" ;;
  esac
}

image_old_digest() {
  local image="$1"
  case "$image" in
    example/standalone:latest) echo "sha256:standalone-old-digest" ;;
    *) echo "sha256:old-svc" ;;
  esac
}

image_new_digest() {
  local image="$1"
  case "$image" in
    example/standalone:latest) echo "sha256:standalone-new-digest" ;;
    *) echo "sha256:new-svc" ;;
  esac
}

docker_info_state() {
  case "$SCENARIO" in
    standalone) echo "inactive" ;;
    swarm_worker) echo "active" ;;
    *) echo "active" ;;
  esac
}

docker_info_control() {
  case "$SCENARIO" in
    standalone) echo "false" ;;
    swarm_worker) echo "false" ;;
    *) echo "true" ;;
  esac
}

if [[ "${1:-}" == "info" ]]; then
  if [[ "${2:-}" == "--format" ]]; then
    case "${3:-}" in
      *Swarm.LocalNodeState*) docker_info_state ;;
      *Swarm.ControlAvailable*) docker_info_control ;;
      *Architecture*) echo "amd64" ;;
      *) echo "" ;;
    esac
  fi
  exit 0
fi

if [[ "${1:-}" == "ps" ]]; then
  if [[ "$SCENARIO" == "standalone" ]]; then
    echo "standalone-app"
  fi
  exit 0
fi

if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
  cat <<JSON
[{"Config":{"Labels":{"autoupdate":"true","autoupdate.webhook":"https://example/standalone-webhook"},"Image":"example/standalone:latest"}}]
JSON
  exit 0
fi

if [[ "${1:-}" == "pull" ]]; then
  mark_pulled "${2:-}"
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  if [[ "${3:-}" == "-f" ]]; then
    image_ref="${5:-}"
    if [[ "$SCENARIO" == "swarm_dry_run" && "$image_ref" == "example/svc:latest" ]]; then
      image_new_id "$image_ref"
      exit 0
    fi
    if is_pulled "$image_ref"; then
      image_new_id "$image_ref"
    else
      image_old_id "$image_ref"
    fi
    exit 0
  fi

  image_ref="${3:-}"
  image_repo_name="$(image_repo "$image_ref")"
  if [[ "$SCENARIO" == "swarm_dry_run" && "$image_ref" == "example/svc:latest" ]]; then
    image_digest="$(image_new_digest "$image_ref")"
    image_id="$(image_new_id "$image_ref")"
    cat <<JSON
[{"RepoDigests":["${image_repo_name}@${image_digest}"],"Id":"${image_id}"}]
JSON
    exit 0
  fi

  if is_pulled "$image_ref"; then
    image_digest="$(image_new_digest "$image_ref")"
    image_id="$(image_new_id "$image_ref")"
  else
    image_digest="$(image_old_digest "$image_ref")"
    image_id="$(image_old_id "$image_ref")"
  fi

  cat <<JSON
[{"RepoDigests":["${image_repo_name}@${image_digest}"],"Id":"${image_id}"}]
JSON
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "prune" ]]; then
  exit 0
fi

if [[ "${1:-}" == "service" && "${2:-}" == "ls" ]]; then
  if [[ "${SCENARIO}" != "standalone" && "${SCENARIO}" != "swarm_worker" ]]; then
    echo "svc1"
  fi
  exit 0
fi

if [[ "${1:-}" == "service" && "${2:-}" == "inspect" ]]; then
  case "$SCENARIO" in
    swarm_service_label|swarm_dry_run)
      cat <<JSON
[{"Spec":{"Name":"svc1","Labels":{"autoupdate":"true"},"TaskTemplate":{"ContainerSpec":{"Image":"example/svc:latest@sha256:old-svc","Labels":{}}}}}]
JSON
      ;;
    swarm_task_fallback)
      cat <<JSON
[{"Spec":{"Name":"svc1","Labels":{},"TaskTemplate":{"ContainerSpec":{"Image":"example/svc:latest@sha256:old-svc","Labels":{"autoupdate":"true"}}}}}]
JSON
      ;;
    swarm_monitor)
      cat <<JSON
[{"Spec":{"Name":"svc1","Labels":{"autoupdate":"monitor"},"TaskTemplate":{"ContainerSpec":{"Image":"example/svc:latest@sha256:old-svc","Labels":{}}}}}]
JSON
      ;;
    swarm_webhook_compose)
      cat <<JSON
[{"Spec":{"Name":"svc1","Labels":{"autoupdate":"true","autoupdate.webhook":"https://example/swarm-webhook","autoupdate.docker-compose":"/stack/compose.yml"},"TaskTemplate":{"ContainerSpec":{"Image":"example/svc:latest@sha256:old-svc","Labels":{}}}}}]
JSON
      ;;
    *)
      echo "[]"
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "service" && "${2:-}" == "update" ]]; then
  exit 0
fi

if [[ "${1:-}" == "manifest" && "${2:-}" == "inspect" ]]; then
  image_ref="${3:-}"
  if [[ "$SCENARIO" == "standalone" && "$image_ref" == "example/standalone:latest" ]]; then
    digest="sha256:standalone-new-digest"
  elif [[ "$SCENARIO" == "swarm_service_label" || "$SCENARIO" == "swarm_task_fallback" || "$SCENARIO" == "swarm_monitor" || "$SCENARIO" == "swarm_webhook_compose" || "$SCENARIO" == "swarm_dry_run" ]]; then
    digest="sha256:new-svc"
  else
    digest="sha256:old-svc"
  fi

  cat <<JSON
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"$digest","platform":{"architecture":"amd64","os":"linux"}}]}
JSON
  exit 0
fi

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi

echo "unsupported docker invocation: $*" >&2
exit 1
EOF

  cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "curl $*" >>"${MOCK_LOG_FILE:?}"
exit 0
EOF

  chmod +x "$mock_bin/docker" "$mock_bin/curl"
}

run_case() {
  local case_name="$1"
  local scenario="$2"
  shift 2

  local case_dir="$TMP_DIR/$case_name"
  local mock_bin="$case_dir/bin"
  local log_file="$case_dir/mock.log"
  local state_file="$case_dir/pull-state.log"
  local output_file="$case_dir/output.log"

  mkdir -p "$case_dir"
  : >"$log_file"
  : >"$state_file"

  create_mock_bin "$mock_bin"

  CURRENT_LOG_FILE="$log_file"
  CURRENT_OUTPUT_FILE="$output_file"

  if ! (
    cd "$ROOT_DIR"
    PATH="$mock_bin:$PATH" \
      MOCK_LOG_FILE="$log_file" \
      MOCK_STATE_FILE="$state_file" \
      MOCK_SCENARIO="$scenario" \
      "$SCRIPT_PATH" --no-system-update "$@" >"$output_file" 2>&1
  ); then
    fail "script failed for case=$case_name scenario=$scenario"
  fi
}

run_case "standalone" "standalone"
assert_output_contains "mode=standalone"
assert_log_contains "docker ps --format {{.Names}}"
assert_log_contains "curl -sS -m 15 -X POST https://example/standalone-webhook"
assert_log_not_contains "docker service ls"

run_case "swarm-service-label" "swarm_service_label"
assert_output_contains "mode=swarm-manager"
assert_log_contains "docker service ls --format {{.Name}}"
assert_log_contains "docker service update --image example/svc:latest --detach=false svc1"
assert_log_not_contains "docker ps --format {{.Names}}"

run_case "swarm-task-fallback" "swarm_task_fallback"
assert_output_contains "mode=swarm-manager"
assert_output_contains "label=autoupdate source=task-template"
assert_log_contains "docker service update --image example/svc:latest --detach=false svc1"

run_case "swarm-monitor" "swarm_monitor"
assert_output_contains "mode=swarm-manager"
assert_output_contains "update available (monitor only)"
assert_log_not_contains "docker service update --image"

run_case "swarm-webhook-compose" "swarm_webhook_compose"
assert_output_contains "mode=swarm-manager"
assert_output_contains "autoupdate.docker-compose ignored in swarm mode"
assert_log_contains "curl -sS -m 15 -X POST https://example/swarm-webhook"
assert_log_not_contains "docker service update --image"
assert_log_not_contains "docker compose -f"

run_case "swarm-worker" "swarm_worker"
assert_output_contains "mode=swarm-worker"
assert_output_contains "updates skipped (manager required)"
assert_log_not_contains "docker service ls --format {{.Name}}"
assert_log_not_contains "docker ps --format {{.Names}}"

run_case "swarm-dry-run" "swarm_dry_run" --dry-run
assert_output_contains "mode=swarm-manager"
assert_log_not_contains "docker service update --image"
assert_log_not_contains "curl -sS -m 15 -X POST"

echo "All swarm behavior tests passed."

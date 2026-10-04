#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CASE_DIR=""
CASE_COUNT=0
NEW_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
fail() {
  echo "FAIL: $*" >&2
  cat "$CASE_DIR/output" "$CASE_DIR/calls" >&2
  exit 1
}
output_has() { grep -Fq -- "$1" "$CASE_DIR/output" || fail "output missing: $1"; }
output_lacks() { if grep -Fq -- "$1" "$CASE_DIR/output"; then fail "unexpected output: $1"; fi; }
calls_have() { grep -Fq -- "$1" "$CASE_DIR/calls" || fail "call missing: $1"; }
calls_lack() { if grep -Fq -- "$1" "$CASE_DIR/calls"; then fail "unexpected call: $1"; fi; }
no_mutations() {
  calls_lack 'service update'
  calls_lack 'docker pull'
  calls_lack 'image prune'
  calls_lack 'curl '
  calls_lack 'docker login'
  calls_lack 'zabbix_sender'
}
run_case() {
  local scenario="$1" expected="$2" status=0
  shift 2
  ((CASE_COUNT += 1))
  CASE_DIR="$TMP_DIR/$CASE_COUNT-$scenario"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/home"
  cp "$ROOT_DIR"/tests/mocks/* "$CASE_DIR/bin/"
  chmod +x "$CASE_DIR"/bin/*
  : >"$CASE_DIR/calls"
  # Isolate integrations and Docker credentials from the developer's shell.
  env -i PATH="$CASE_DIR/bin:$PATH" HOME="$CASE_DIR/home" \
    DOCKER_CONFIG="$CASE_DIR/home" MOCK_SCENARIO="$scenario" MOCK_DIR="$CASE_DIR" \
    UPDATE_TIMEOUT=1 UPDATE_POLL_INTERVAL=1 DOCKER_TIMEOUT=2 \
    bash "$ROOT_DIR/container-updater.sh" --no-system-update "$@" >"$CASE_DIR/output" 2>&1 || status=$?
  [[ "$status" -eq "$expected" ]] || fail "$scenario exited $status, expected $expected"
}
run_case standalone 0
output_has 'mode=standalone'
calls_have 'POST https://example.invalid/webhook'
calls_lack 'service ls'
run_case standalone_false 0
output_has 'disabled=1'
# Standalone retains its historical prune, but must not pull/update disabled apps.
calls_lack 'docker pull'
calls_lack 'curl '
run_case service_label 0
calls_have "service update --image example/svc:latest@$NEW_DIGEST --detach=true service-id-1"
output_has 'applied=1'
calls_have 'inspect --type task task-id-1'
calls_lack 'docker ps'
calls_lack 'docker pull'
calls_lack 'image prune'
run_case task_label 0
output_has 'label=autoupdate source=task-template'
output_has 'applied=1'
run_case unlabeled 0
output_has 'service has no autoupdate label'
output_has 'unlabeled=1'
output_has 'monitor_only=1'
no_mutations
run_case unlabeled 0 --unlabeled-policy ignore
output_has 'disabled=1'
calls_lack 'imagetools inspect'
no_mutations
run_case disabled 0
output_has 'disabled=1'
output_lacks 'unsupported'
calls_lack 'imagetools inspect'
no_mutations
run_case invalid_policy 1
output_has 'INVALID_AUTOUPDATE_POLICY'
no_mutations
run_case service_label 2 --unlabeled-policy true
output_has 'invalid unlabeled policy'
no_mutations
run_case service_label 2 --unlabeled-policy
output_has 'requires monitor or ignore'
no_mutations
run_case monitor 0
output_has 'update available (monitor only)'
no_mutations
for scenario in current_index current_child single_manifest; do
  run_case "$scenario" 0
  output_has 'up_to_date=1'
  output_has 'updates_available=0'
  no_mutations
done
run_case rate_limit 1 --dry-run
output_has 'REGISTRY_RATE_LIMIT'
output_has 'up_to_date=0'
output_has 'checks_skipped=1'
output_lacks 'sensitive-placeholder'
no_mutations
run_case registry_error 1
output_has 'REGISTRY_UNAVAILABLE'
output_lacks 'sensitive-placeholder'
no_mutations
run_case registry_auth 1
output_has 'REGISTRY_AUTH_REQUIRED'
output_lacks 'sensitive-placeholder'
no_mutations
run_case http_rate_limit 1
output_has 'REGISTRY_RATE_LIMIT'
output_lacks 'sensitive-placeholder'
no_mutations
run_case malformed_manifest 1 --dry-run
output_has 'INVALID_REGISTRY_MANIFEST'
no_mutations
run_case no_buildx 1
output_has 'BUILDX_UNAVAILABLE'
no_mutations
run_case digest_only 1
output_has 'DIGEST_ONLY_REFERENCE_NO_TAG'
calls_lack 'imagetools inspect'
no_mutations
run_case unpinned_unknown 1 --dry-run
output_has 'RUNNING_IMAGE_DIGEST_UNKNOWN'
output_has 'up_to_date=0'
calls_lack 'image inspect'
no_mutations
run_case unpinned_current 0
output_has 'up_to_date=1'
no_mutations
run_case unpinned_outdated 0
output_has 'applied=1'
run_case untagged_outdated 0
calls_have "service update --image example/svc:latest@$NEW_DIGEST --detach=true service-id-1"
output_has 'applied=1'
run_case webhook 0
output_has 'autoupdate.docker-compose ignored in swarm mode'
output_has 'applied=1'
calls_have 'POST https://example.invalid/webhook'
calls_lack 'service update'
calls_lack 'docker compose'
output_lacks 'https://example.invalid/webhook'
for scenario in webhook_http_error webhook_redirect webhook_timeout; do
  run_case "$scenario" 1
  output_has 'UPDATE_SUBMISSION_FAILED_OR_UNCERTAIN'
  output_has 'applied=0'
  [[ "$(grep -c '^curl ' "$CASE_DIR/calls")" == 1 ]] || fail 'webhook retried'
done
run_case webhook_unchanged 1
output_has 'pending=1'
output_has 'applied=0'
for scenario in rollout_paused rollout_rollback; do
  run_case "$scenario" 1
  output_has 'ROLLOUT_FAILED'
  output_has 'applied=0'
done
for scenario in tasks_old tasks_unhealthy incomplete_replicas; do
  run_case "$scenario" 1
  output_has 'pending=1'
  output_has 'applied=0'
done
run_case concurrent_change 1
output_has 'SERVICE_CHANGED_DURING_SCAN'
no_mutations
for scenario in stopped job; do
  run_case "$scenario" 1
  output_has 'STOPPED_OR_JOB_SERVICE'
  no_mutations
done
run_case list_error 1
output_has 'SERVICE_LIST_FAILED'
no_mutations
run_case inspect_error 1
output_has 'SERVICE_INSPECT_FAILED'
no_mutations
run_case shared_webhook 0
output_has 'applied=2'
[[ "$(grep -c '^curl ' "$CASE_DIR/calls")" == 1 ]] || fail 'shared webhook submitted twice'
[[ "$(grep -c 'imagetools inspect' "$CASE_DIR/calls")" == 1 ]] || fail 'manifest not cached'
run_case worker 0
output_has 'updates skipped (manager required)'
calls_lack 'service ls'
no_mutations
run_case service_label 0 --dry-run -z example.invalid -d https://example.invalid/discord
output_has 'simulated=1'
output_has 'applied=0'
output_has 'dry-run: skip zabbix metric'
no_mutations
run_case webhook 0 --dry-run
output_has 'simulated=1'
no_mutations
echo "All $CASE_COUNT behavior tests passed."

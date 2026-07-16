#!/bin/sh
set -eu

PULL_POLL_ATTEMPTS=${DOCKHAND_PULL_POLL_ATTEMPTS:-150}
PULL_POLL_INTERVAL=${DOCKHAND_PULL_POLL_INTERVAL:-2}
VERIFY_ATTEMPTS=${DEPLOY_VERIFY_ATTEMPTS:-12}
VERIFY_INTERVAL=${DEPLOY_VERIFY_INTERVAL:-2}
ROLLBACK_FILE=
REPLACEMENT_STARTED=false

fail() { echo "deploy: $*" >&2; exit 1; }

: "${IMAGE_REF:?IMAGE_REF is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${APP_URL:?APP_URL is required}"
: "${DOCKHAND_URL:?DOCKHAND_URL is required}"
: "${DOCKHAND_TOKEN:?DOCKHAND_TOKEN is required}"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

DOCKHAND_URL=${DOCKHAND_URL%/}
HEALTH_PATH=${HEALTH_PATH:-/}
case $HEALTH_PATH in /*) ;; *) HEALTH_PATH=/$HEALTH_PATH ;; esac
HEALTH_URL=${APP_URL%/}$HEALTH_PATH
AUTH_HEADER="Authorization: Bearer $DOCKHAND_TOKEN"

api() {
    method=$1 path=$2 data=${3-}
    if [ -n "$data" ]; then
        curl --fail --silent --show-error -X "$method" -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" --data "$data" "$DOCKHAND_URL$path"
    else
        curl --fail --silent --show-error -X "$method" -H "$AUTH_HEADER" \
            "$DOCKHAND_URL$path"
    fi
}

body_reports_success() {
    printf '%s' "$1" | jq -e '.success == true' >/dev/null 2>&1
}

create_payload_from_inspect() {
    jq -c --arg name "$CONTAINER_NAME" --arg image "$1" '{
        name: $name, image: $image,
        cmd: .Config.Cmd, entrypoint: .Config.Entrypoint,
        workingDir: .Config.WorkingDir, user: .Config.User,
        env: (.Config.Env // []),
        # OCI image annotations belong to the selected image. Copying them from
        # the old container overrides the new image metadata at container create.
        labels: ((.Config.Labels // {}) | with_entries(
            select(.key | startswith("org.opencontainers.image.") | not)
        )),
        volumeBinds: (.HostConfig.Binds // []),
        ports: ((.HostConfig.PortBindings // {}) | with_entries(.value = .value[0])),
        restartPolicy: (.HostConfig.RestartPolicy.Name // "no"),
        restartMaxRetries: (.HostConfig.RestartPolicy.MaximumRetryCount // 0),
        networkMode: (.HostConfig.NetworkMode // "default"),
        privileged: (.HostConfig.Privileged // false),
        readonlyRootfs: (.HostConfig.ReadonlyRootfs // false)
    }'
}

rollback() {
    status=$?
    trap - EXIT INT TERM
    if [ "$REPLACEMENT_STARTED" = true ] && [ -s "${ROLLBACK_FILE:-/nonexistent}" ]; then
        echo "deploy: deployment failed; restoring snapshot" >&2
        set +e
        api POST "/api/containers/$CONTAINER_NAME/stop?env=1" >/dev/null 2>&1
        api DELETE "/api/containers/$CONTAINER_NAME?env=1&force=true" >/dev/null 2>&1
        old_image=$(jq -r '.Config.Image' "$ROLLBACK_FILE")
        payload=$(create_payload_from_inspect "$old_image" < "$ROLLBACK_FILE")
        result=$(api POST "/api/containers?env=1" "$payload" 2>&1)
        if body_reports_success "$result"; then
            result=$(api POST "/api/containers/$CONTAINER_NAME/start?env=1" 2>&1)
        fi
        if body_reports_success "$result"; then
            echo "deploy: rollback restored the previous container" >&2
        else
            echo "ALERT: deploy rollback failed; $CONTAINER_NAME requires manual recovery" >&2
        fi
        set -e
    fi
    [ -z "$ROLLBACK_FILE" ] || rm -f "$ROLLBACK_FILE"
    exit "$status"
}
trap rollback EXIT INT TERM

echo "deploy: pulling $IMAGE_REF"
pull_result=$(api POST "/api/images/pull?env=1" \
    "$(jq -cn --arg image "$IMAGE_REF" '{image: $image, scanAfterPull: false}')")
job_id=$(printf '%s' "$pull_result" | jq -er '.jobId') || fail "image pull returned no job ID"
attempt=1
while [ "$attempt" -le "$PULL_POLL_ATTEMPTS" ]; do
    job=$(api GET "/api/jobs/$job_id?env=1")
    status=$(printf '%s' "$job" | jq -er '.status') || fail "image pull job has no status"
    if [ "$status" = "done" ]; then
        printf '%s' "$job" | jq -e '.result.status == "complete"' >/dev/null || fail "image pull failed"
        break
    fi
    case $status in pending|running) ;; *) fail "unexpected image pull status: $status" ;; esac
    [ "$attempt" -lt "$PULL_POLL_ATTEMPTS" ] || fail "timed out waiting for image pull"
    sleep "$PULL_POLL_INTERVAL"
    attempt=$((attempt + 1))
done

ROLLBACK_FILE=$(mktemp)
api GET "/api/containers/$CONTAINER_NAME?env=1" > "$ROLLBACK_FILE" || fail "could not inspect existing container"
jq -e '.Config.Image and .State' "$ROLLBACK_FILE" >/dev/null || fail "container snapshot is incomplete"
create_payload=$(create_payload_from_inspect "$IMAGE_REF" < "$ROLLBACK_FILE")

echo "deploy: replacing $CONTAINER_NAME using its inspected configuration"
api POST "/api/containers/$CONTAINER_NAME/stop?env=1" >/dev/null
api DELETE "/api/containers/$CONTAINER_NAME?env=1" >/dev/null
REPLACEMENT_STARTED=true
create_result=$(api POST "/api/containers?env=1" "$create_payload")
body_reports_success "$create_result" || fail "replacement create did not report success"
start_result=$(api POST "/api/containers/$CONTAINER_NAME/start?env=1")
body_reports_success "$start_result" || fail "replacement start did not report success"

[ "${DEPLOY_SIMULATE_FAILURE:-false}" != true ] || fail "simulated post-start failure"

details=$(api GET "/api/containers/$CONTAINER_NAME?env=1")
printf '%s' "$details" | jq -e '.State.Running == true' >/dev/null || fail "container is not running"
actual_image=$(printf '%s' "$details" | jq -er '.Config.Image') || fail "container has no image"
[ "$actual_image" = "$IMAGE_REF" ] || fail "expected $IMAGE_REF, found $actual_image"
if [ -n "${EXPECTED_IMAGE_REVISION:-}" ]; then
    actual_revision=$(printf '%s' "$details" | jq -er \
        '.Config.Labels["org.opencontainers.image.revision"]') || \
        fail "container has no org.opencontainers.image.revision label"
    [ "$actual_revision" = "$EXPECTED_IMAGE_REVISION" ] || \
        fail "expected image revision $EXPECTED_IMAGE_REVISION, found $actual_revision"
fi

attempt=1
while ! curl --fail --silent --show-error --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; do
    [ "$attempt" -lt "$VERIFY_ATTEMPTS" ] || fail "$HEALTH_URL did not return HTTP success"
    sleep "$VERIFY_INTERVAL"
    attempt=$((attempt + 1))
done

if [ -n "${STRONG_VERIFY_COMMAND:-}" ]; then
    export APP_URL HEALTH_URL EXPECTED_IMAGE="$IMAGE_REF" CONTAINER_NAME
    sh -eu -c "$STRONG_VERIFY_COMMAND" || fail "application-specific verification failed"
fi

REPLACEMENT_STARTED=false
rm -f "$ROLLBACK_FILE"
ROLLBACK_FILE=
trap - EXIT INT TERM
echo "deploy: verified $CONTAINER_NAME on $IMAGE_REF"

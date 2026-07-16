#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/curl" <<'EOF'
#!/bin/sh
set -eu
method=GET data= url=
while [ "$#" -gt 0 ]; do
    case $1 in
        -X) method=$2; shift 2 ;;
        --data) data=$2; shift 2 ;;
        -H|--max-time) shift 2 ;;
        --fail|--silent|--show-error) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >> "$MOCK_LOG"
case $url in
    http://dockhand/api/images/pull*) printf '%s' '{"jobId":"pull-1"}' ;;
    http://dockhand/api/jobs/*) printf '%s' '{"status":"done","result":{"status":"complete"}}' ;;
    http://dockhand/api/containers/demo\?env=1)
        if [ "$(cat "$MOCK_IMAGE")" = old ]; then image=registry/demo:old revision=old-sha; else image=registry/demo:new revision=$MOCK_NEW_REVISION; fi
        jq -cn --arg image "$image" --arg revision "$revision" '{Config:{Image:$image,Cmd:["serve"],Entrypoint:null,WorkingDir:"/app",User:"1000",Env:["KEEP=yes"],Labels:{owner:"test","org.opencontainers.image.title":"demo","org.opencontainers.image.vendor":"Pacific Shift Labs","org.opencontainers.image.source":"https://github.com/example/demo","org.opencontainers.image.revision":$revision}},HostConfig:{Binds:["demo-data:/data:rw"],PortBindings:{"8000/tcp":[{HostPort:"18000"}]},RestartPolicy:{Name:"unless-stopped",MaximumRetryCount:0},NetworkMode:"bridge",Privileged:false,ReadonlyRootfs:false},State:{Running:true}}'
        ;;
    http://dockhand/api/containers\?env=1)
        image=$(printf '%s' "$data" | jq -r '.image')
        case $image in registry/demo:new) printf new > "$MOCK_IMAGE" ;; registry/demo:old) printf old > "$MOCK_IMAGE" ;; esac
        printf '%s' '{"success":true}'
        ;;
    http://dockhand/api/containers/*) printf '%s' '{"success":true}' ;;
    http://app/health) exit 0 ;;
    *) echo "unexpected URL: $url" >&2; exit 2 ;;
esac
EOF
cat > "$TMP/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/curl" "$TMP/sleep"

run_deploy() {
    printf old > "$TMP/image"
    : > "$TMP/log"
    PATH="$TMP:$PATH" MOCK_IMAGE="$TMP/image" MOCK_LOG="$TMP/log" \
      MOCK_NEW_REVISION="${2:-new-sha}" \
      IMAGE_REF=registry/demo:new CONTAINER_NAME=demo APP_URL=http://app \
      EXPECTED_IMAGE_REVISION=new-sha \
      HEALTH_PATH=/health DOCKHAND_URL=http://dockhand DOCKHAND_TOKEN=test-token \
      DEPLOY_SIMULATE_FAILURE="$1" "$ROOT/.github/actions/deploy/deploy.sh"
}

run_deploy false
[ "$(cat "$TMP/image")" = new ]
jq -e '.image == "registry/demo:new" and .env == ["KEEP=yes"] and
  .labels == {owner:"test"} and
  .volumeBinds == ["demo-data:/data:rw"] and .ports["8000/tcp"].HostPort == "18000"' \
  <<EOF >/dev/null
$(awk -F '\t' '$2 == "http://dockhand/api/containers?env=1" {print $3; exit}' "$TMP/log")
EOF

if run_deploy true; then
    echo "simulated deployment unexpectedly succeeded" >&2
    exit 1
fi
[ "$(cat "$TMP/image")" = old ]
awk -F '\t' '$2 == "http://dockhand/api/containers?env=1" {print $3}' "$TMP/log" | tail -n 1 | \
  jq -e '.image == "registry/demo:old" and .env == ["KEEP=yes"] and
    .labels == {owner:"test"}' >/dev/null

if run_deploy false stale-sha; then
    echo "deployment with a stale revision unexpectedly succeeded" >&2
    exit 1
fi
[ "$(cat "$TMP/image")" = old ]

echo "deploy tests passed"

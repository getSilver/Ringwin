#!/bin/sh
set -eu

base=/opt/ringwin-qualification/20260921
env_file=/root/.ringwin/env.local
value() {
    sed -n "s/^$1=//p" "$env_file" | sed -n '1p'
}

export RINGWIN_OKX_KEY="$(value OKX_DEMO_API_KEY)"
export RINGWIN_OKX_SECRET="$(value OKX_DEMO_SECRET_KEY)"
export RINGWIN_OKX_PASSPHRASE="$(value OKX_DEMO_PASSPHRASE)"
export RINGWIN_OKX_REST_BASE_URL="$(value OKX_DEMO_REST_BASE_URL)"
export RINGWIN_OKX_ENTITY="$(value OKX_ENTITY)"
export RINGWIN_OKX_PRIVATE_WS_URL="wss://wspap.okx.com/ws/v5/private"
export RINGWIN_DEMO_POLICY_PATH="$base/okx-demo-policy.json"
export RINGWIN_DEMO_STATE_DIR="$base/okx-state"
mode="${1:---demo-live}"
case "$mode" in
    --demo-live|--prepare-only|--cleanup-only) ;;
    *) exit 64 ;;
esac

if [ "$mode" != "--cleanup-only" ] && [ -d "$RINGWIN_DEMO_STATE_DIR" ]; then
    mv "$RINGWIN_DEMO_STATE_DIR" "$base/evidence/pre-v40-state-$(date +%Y%m%d%H%M%S)"
fi
install -d -m 700 "$RINGWIN_DEMO_STATE_DIR"
output="$base/evidence/okx-v40-${mode#--}.txt"
stdout="$output.stdout"
stderr="$output.stderr"
set +e
"$base/bin/okx-demo-internal-v40" "$mode" >"$stdout" 2>"$stderr"
status=$?
set -e
cat "$stdout" "$stderr" >"$output"
chmod 600 "$output"
exit "$status"

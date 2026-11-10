#!/bin/sh
# Tunnel create: existing remote name must be reported, and force delete must
# allow recreation.

set -e

ROOT="${ROOT:?}"
TESTDIR="${TESTDIR:?}"
TMP="${TMP:?}"

MOCK="$TESTDIR/mock"
export MOCK_DB="$TMP/db"
export MOCK_TYPE="$TMP/type"
export MOCK_CF_DELETED="$TMP/cf-deleted"
export MOCK_CF_CREDS="$TMP/cf-new.json"
export CF_STATE_DIR="$TMP/state"
export PATH="$MOCK:$PATH"
export CLOUDFLARED_COMMON="$ROOT/root/usr/lib/cloudflared/common.sh"

BASE="$TMP/collision-base"
mkdir -p "$BASE" "$CF_STATE_DIR"
printf 'BEGIN CERTIFICATE\nx\n' > "$BASE/cert.pem"

cat > "$MOCK_TYPE" <<'EOF'
cloudflared.main=main
cloudflared.t1=tunnel
EOF

cat > "$MOCK_DB" <<EOF
cloudflared.main.cloudflared_path=$TESTDIR/mock/cloudflared
cloudflared.main.data_path=$TMP/collision-data
cloudflared.main.base_path=
cloudflared.main.cert_path=$BASE/cert.pem
cloudflared.t1.name=chdao
cloudflared.t1.enabled=1
cloudflared.t1.data_dir=$TMP/collision-data/tunnels/t1
EOF

CTL="$ROOT/root/usr/bin/cloudflared-ctl"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	printf '%s' "$1" | grep -q "$2" || fail "expected '$2' in output: $1"
}

rm -f "$MOCK_CF_DELETED" "$MOCK_CF_CREDS"

set +e
out="$("$CTL" tunnel-create t1 chdao 2>&1)"
rc=$?
set -e

[ "$rc" -ne 0 ] || fail "first create should fail when the name exists"
assert_contains "$out" 'exists=1'
assert_contains "$out" 'tunnel_id=tid-existing'
[ ! -f "$MOCK_CF_DELETED" ] || fail "must not delete without force"

set +e
out2="$("$CTL" tunnel-create t1 chdao --force-delete 2>&1)"
rc2=$?
set -e

[ "$rc2" -eq 0 ] || fail "force delete + create should succeed: $out2"
assert_contains "$out2" 'ok=1'
assert_contains "$out2" 'tunnel_id=11111111-2222-3333-4444-555555555555'
[ -f "$MOCK_CF_DELETED" ] || fail "force delete was not executed"

printf 'shell tunnel create collision test passed\n'

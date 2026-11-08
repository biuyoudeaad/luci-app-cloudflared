#!/bin/sh
# Multi-tunnel / same-zone isolation test.

set -e

ROOT="${ROOT:?}"
TESTDIR="${TESTDIR:?}"
TMP="${TMP:?}"

MOCK="$TESTDIR/mock"
export MOCK_DB="$TMP/db"
export MOCK_TYPE="$TMP/type"
export PATH="$MOCK:$PATH"
export CF_STATE_DIR="$TMP/state"

BASE="$TMP/base"
mkdir -p "$BASE/t1" "$BASE/t2" "$CF_STATE_DIR"

printf '{"TunnelID":"tid1","TunnelSecret":"s1","AccountTag":"a"}\n' > "$BASE/t1/tid1.json"
printf '{"TunnelID":"tid2","TunnelSecret":"s2","AccountTag":"a"}\n' > "$BASE/t2/tid2.json"
printf 'BEGIN CERTIFICATE\nx\n' > "$BASE/cert.pem"

cat > "$MOCK_TYPE" <<'EOF'
cloudflared.main=main
cloudflared.t1=tunnel
cloudflared.t2=tunnel
cloudflared.r1=ingress
cloudflared.r2=ingress
EOF

cat > "$MOCK_DB" <<EOF
cloudflared.main.base_path=$BASE
cloudflared.main.cert_path=$BASE/cert.pem
cloudflared.t1.name=t1
cloudflared.t1.enabled=1
cloudflared.t1.domain=example.com
cloudflared.t1.applied_domain=example.com
cloudflared.t1.tunnel_id=tid1
cloudflared.t1.data_dir=$BASE/t1
cloudflared.t1.credentials_file=$BASE/t1/tid1.json
cloudflared.t2.name=t2
cloudflared.t2.enabled=1
cloudflared.t2.domain=example.com
cloudflared.t2.applied_domain=example.com
cloudflared.t2.tunnel_id=tid2
cloudflared.t2.data_dir=$BASE/t2
cloudflared.t2.credentials_file=$BASE/t2/tid2.json
cloudflared.r1.tunnel=t1
cloudflared.r1.hostname=a.example.com
cloudflared.r1.service=http://10.0.0.1:80
cloudflared.r2.tunnel=t2
cloudflared.r2.hostname=b.example.com
cloudflared.r2.service=http://10.0.0.2:80
EOF

. "$ROOT/root/usr/lib/cloudflared/common.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

assert_contains() {
	grep -q "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
	if grep -q "$2" "$1"; then
		fail "did not expect '$2' in $1"
	fi
}

assert_eq "$(cf_tunnel_sections | tr '\n' ' ')" "t1 t2 "
assert_eq "$(cf_ingress_sections t1)" "r1"
assert_eq "$(cf_ingress_sections t2)" "r2"

cfg1="$(cf_gen_config t1)"
cfg2="$(cf_gen_config t2)"

assert_contains "$cfg1" "hostname: a.example.com"
assert_not_contains "$cfg1" "b.example.com"
assert_contains "$cfg2" "hostname: b.example.com"
assert_not_contains "$cfg2" "a.example.com"

assert_eq "$(cf_domain_rewrite t1 example.com new.com)" "1"
assert_eq "$(uci -q get cloudflared.r1.hostname)" "a.new.com"
assert_eq "$(uci -q get cloudflared.r2.hostname)" "b.example.com"

# Legacy anonymous-section data directory discovery
mkdir -p "$BASE/tunnels/@tunnel[0]"
printf 'tunnel: tid1\n' > "$BASE/tunnels/@tunnel[0]/config.yml"
printf '{"TunnelID":"tid1","TunnelSecret":"s1","AccountTag":"a"}\n' > "$BASE/tunnels/@tunnel[0]/tid1.json"
uci -q set cloudflared.t1.data_dir=
uci -q set cloudflared.t1.credentials_file=
assert_eq "$(cf_tunnel_dir t1)" "$BASE/tunnels/@tunnel[0]"
assert_eq "$(cf_credentials t1)" "$BASE/tunnels/@tunnel[0]/tid1.json"
legacy_cfg="$(cf_gen_config t1)"
assert_contains "$legacy_cfg" "hostname: a.new.com"

# When both the canonical and legacy directories exist, fall back to the
# legacy directory for credentials if the canonical one has none.
mkdir -p "$BASE/tunnels/t1"
printf 'tunnel: tid1\n' > "$BASE/tunnels/t1/config.yml"
assert_eq "$(cf_credentials t1)" "$BASE/tunnels/@tunnel[0]/tid1.json"

# Disabled ingress rows are not written to config.yml
uci -q set cloudflared.r1.enabled=0
cfg_off="$(cf_gen_config t1)"
assert_not_contains "$cfg_off" "hostname: a.new.com"
uci -q set cloudflared.r1.enabled=1
cfg_on="$(cf_gen_config t1)"
assert_contains "$cfg_on" "hostname: a.new.com"

# Log size limit parsing
uci -q set cloudflared.log.log_max_size=2
uci -q set cloudflared.log.log_max_unit=KB
assert_eq "$(cf_log_limit_bytes)" "2048"
uci -q set cloudflared.log.log_max_size=0
assert_eq "$(cf_log_limit_bytes)" "0"
uci -q set cloudflared.log.log_max_size=1
uci -q set cloudflared.log.log_max_unit=GB
assert_eq "$(cf_log_limit_bytes)" "1073741824"

printf 'shell multi-tunnel same-zone test passed\n'

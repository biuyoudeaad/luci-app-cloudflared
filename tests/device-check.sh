#!/bin/sh
# Device-side validation helper for luci-app-cloudflared.
# Run on the router as root after installing the package.

set -u

FAIL=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '[WARN] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || {
	echo "Please run as root"
	exit 1
}

DATA="$(uci -q get cloudflared.main.data_path 2>/dev/null)"
[ -n "$DATA" ] || DATA="$(uci -q get cloudflared.main.base_path 2>/dev/null)"
[ -n "$DATA" ] || DATA="/etc/cloudflared"
LEGACY_BASE="$(uci -q get cloudflared.main.base_path 2>/dev/null)"
[ -n "$LEGACY_BASE" ] || LEGACY_BASE="/opt/cloudflare"
CORE_DIR="/opt/cloudflared/bin"

BIN="$(uci -q get cloudflared.main.cloudflared_path 2>/dev/null)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
	if [ -x "$CORE_DIR/cloudflared" ]; then
		BIN="$CORE_DIR/cloudflared"
	elif [ -x "$LEGACY_BASE/cloudflared" ]; then
		BIN="$LEGACY_BASE/cloudflared"
	elif [ -x "/usr/bin/cloudflared" ]; then
		BIN="/usr/bin/cloudflared"
	else
		BIN=""
	fi
fi

if [ -n "$BIN" ] && [ -x "$BIN" ]; then
	pass "binary: $BIN ($("$BIN" --version 2>&1 | head -n 1))"
else
	fail "cloudflared binary not found or not executable"
fi

AVAIL_DIR="$CORE_DIR"
[ -n "$BIN" ] && AVAIL_DIR="$(dirname "$BIN")"
AVAIL="$(df -k "$AVAIL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt 102400 ]; then
	warn "low free space: ${AVAIL}KB at $AVAIL_DIR"
else
	pass "free space: ${AVAIL:-unknown}KB at $AVAIL_DIR"
fi

TUNNELS="$(uci -q -X show cloudflared 2>/dev/null | sed -n 's/^cloudflared\.\([^.=]*\)=tunnel$/\1/p')"
if [ -z "$TUNNELS" ]; then
	fail "no tunnel sections found"
fi

for section in $TUNNELS; do
	enabled="$(uci -q get "cloudflared.$section.enabled" 2>/dev/null)"
	[ -n "$enabled" ] || enabled=1

	dir="$(uci -q get "cloudflared.$section.data_dir" 2>/dev/null)"
	if [ -z "$dir" ]; then
		config="$(/usr/bin/cloudflared-ctl get-config-path "$section" 2>/dev/null)"
		[ -n "$config" ] || config="$DATA/tunnels/$section/config.yml"
		dir="${config%/config.yml}"
	else
		config="$dir/config.yml"
	fi

	tunnel_id="$(uci -q get "cloudflared.$section.tunnel_id" 2>/dev/null)"

	printf -- '--- tunnel: %s (enabled=%s) ---\n' "$section" "$enabled"

	if [ -f "$config" ]; then
		pass "config: $config"
	else
		fail "config missing: $config"
	fi

	if [ -n "$tunnel_id" ]; then
		pass "tunnel id: $tunnel_id"
	else
		fail "tunnel id missing"
	fi

	credentials="$(uci -q get "cloudflared.$section.credentials_file" 2>/dev/null)"
	[ -n "$credentials" ] || credentials="$dir/$tunnel_id.json"
	if [ -n "$tunnel_id" ] && [ -f "$credentials" ]; then
		pass "credentials: $credentials"
	else
		fail "credentials missing: $credentials"
	fi

	cert="$(uci -q get "cloudflared.$section.cert_path" 2>/dev/null)"
	[ -n "$cert" ] || cert="$(uci -q get cloudflared.main.cert_path 2>/dev/null)"
	[ -n "$cert" ] || cert="$DATA/cert.pem"
	if [ -f "$cert" ]; then
		pass "cert: $cert"
	else
		fail "cert missing: $cert"
	fi

	if [ "$enabled" = "1" ] && [ -f "$config" ]; then
		if ps w 2>/dev/null | grep -F -- "--config $config tunnel run" | grep -v grep >/dev/null 2>&1; then
			pass "process running"
		else
			fail "process not running"
		fi
	fi
done

echo "=============================="
if [ "$FAIL" -eq 0 ]; then
	echo "ALL DEVICE CHECKS PASSED"
	exit 0
fi

echo "$FAIL DEVICE CHECK(S) FAILED"
exit "$FAIL"

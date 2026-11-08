#!/bin/sh
# Run the local test suite.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d /tmp/cf-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

export ROOT TESTDIR TMP
export MOCK_DB="$TMP/db"
export MOCK_TYPE="$TMP/type"
export CF_STATE_DIR="$TMP/state"
export CLOUDFLARED_COMMON="$ROOT/root/usr/lib/cloudflared/common.sh"
export PATH="$TESTDIR/mock:$PATH"

chmod +x "$TESTDIR/mock/uci"

echo "== shell: multi-tunnel same-zone =="
sh "$TESTDIR/shell/multitunnel.sh"

LUA_BIN="${LUA_BIN:-}"
if [ -z "$LUA_BIN" ]; then
	for candidate in lua lua5.1 luajit; do
		if command -v "$candidate" >/dev/null 2>&1; then
			LUA_BIN="$candidate"
			break
		fi
	done
fi

if [ -n "$LUA_BIN" ]; then
	echo "== lua: orphan dns and change detection =="
	"$LUA_BIN" "$TESTDIR/lua/test_orphan_dns.lua"
	"$LUA_BIN" "$TESTDIR/lua/test_snapshot.lua"
else
	echo "lua not found, skipping Lua tests"
fi

echo "ALL TESTS PASSED"

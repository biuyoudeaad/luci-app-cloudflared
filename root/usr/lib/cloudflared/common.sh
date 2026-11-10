#!/bin/sh
# Shared helpers for luci-app-cloudflared.
# Sourced by /etc/init.d/cloudflared and /usr/bin/cloudflared-ctl.

[ -n "${CF_COMMON_SH_LOADED:-}" ] && return 0
CF_COMMON_SH_LOADED=1

CF_STATE_DIR="${CF_STATE_DIR:-/tmp/cloudflared}"
CF_LOG_DIR="/var/log/cloudflared"
CF_RUN_USER="${CF_RUN_USER:-cloudflared}"
CF_APP_LOG="$CF_LOG_DIR/app.log"
CF_CORE_LOG="$CF_LOG_DIR/core.log"
CF_DEFAULT_BASE="${CF_DEFAULT_BASE:-/opt/cloudflare}"
CF_DEFAULT_DATA_PATH="${CF_DEFAULT_DATA_PATH:-/etc/cloudflared}"
CF_DEFAULT_CORE_DIR="${CF_DEFAULT_CORE_DIR:-/opt/cloudflared/bin}"
CF_DEFAULT_CORE="$CF_DEFAULT_CORE_DIR/cloudflared"
CF_BACKUP_DIR="${CF_BACKUP_DIR:-/opt/cloudflared/backups}"
CF_DEFAULT_DOWNLOAD="https://github.com/cloudflare/cloudflared/releases/latest/download"

cf_log() {
	mkdir -p "$CF_LOG_DIR" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" 2>/dev/null >> "$CF_APP_LOG"
	logger -t cloudflared "$*" 2>/dev/null || true
}

cf_log_limit_bytes() {
	local size unit mul

	if [ -n "${CF_LOG_LIMIT_CACHE:-}" ]; then
		printf '%s' "$CF_LOG_LIMIT_CACHE"
		return 0
	fi

	size="$(cf_get log log_max_size 1)"
	case "$size" in
		''|*[!0-9]*) size=1 ;;
	esac

	unit="$(cf_get log log_max_unit MB)"
	case "$unit" in
		KB) mul=1024 ;;
		GB) mul=1073741824 ;;
		*)  mul=1048576 ;;
	esac

	if [ "$size" -gt 0 ]; then
		CF_LOG_LIMIT_CACHE=$((size * mul))
	else
		CF_LOG_LIMIT_CACHE=0
	fi

	printf '%s' "$CF_LOG_LIMIT_CACHE"
}

cf_run_user_exists() {
	id -u "$CF_RUN_USER" >/dev/null 2>&1
}

cf_fix_dir_perms() {
	local d="$1"
	[ "$(id -u)" = "0" ] || return 0
	cf_run_user_exists || return 0
	[ -d "$d" ] || return 0
	chgrp "$CF_RUN_USER" "$d" 2>/dev/null || true
	chmod 750 "$d" 2>/dev/null || true
}

cf_fix_file_perms() {
	local f="$1"
	[ "$(id -u)" = "0" ] || return 0
	cf_run_user_exists || return 0
	[ -f "$f" ] || return 0
	chgrp "$CF_RUN_USER" "$f" 2>/dev/null || true
	chmod 640 "$f" 2>/dev/null || true
}

cf_fix_permissions() {
	local data section dir cfg cert creds f

	[ "$(id -u)" = "0" ] || return 0
	cf_run_user_exists || return 0

	data="$(cf_data_path)"
	for dir in "$data" "$data/tunnels"; do
		[ -d "$dir" ] || continue
		chgrp "$CF_RUN_USER" "$dir" 2>/dev/null || true
		chmod 750 "$dir" 2>/dev/null || true
	done

	for section in $(cf_tunnel_sections); do
		dir="$(cf_tunnel_dir "$section")"
		if [ -d "$dir" ]; then
			chgrp "$CF_RUN_USER" "$dir" 2>/dev/null || true
			chmod 750 "$dir" 2>/dev/null || true
		fi

		cfg="$(cf_config_path "$section")"
		for f in "$cfg" "$cfg.bak1" "$cfg.bak2" "$dir/cert.pem" "$dir"/*.json; do
			[ -f "$f" ] || continue
			chgrp "$CF_RUN_USER" "$f" 2>/dev/null || true
			chmod 640 "$f" 2>/dev/null || true
		done

		cert="$(cf_cert_path "$section" 2>/dev/null)" || cert=""
		if [ -n "$cert" ] && [ -f "$cert" ]; then
			chgrp "$CF_RUN_USER" "$cert" 2>/dev/null || true
			chmod 640 "$cert" 2>/dev/null || true
		fi

		creds="$(cf_credentials "$section" 2>/dev/null)" || creds=""
		if [ -n "$creds" ] && [ -f "$creds" ]; then
			chgrp "$CF_RUN_USER" "$creds" 2>/dev/null || true
			chmod 640 "$creds" 2>/dev/null || true
		fi
	done

	cert="$(cf_get main cert_path)"
	if [ -n "$cert" ] && [ -f "$cert" ]; then
		chgrp "$CF_RUN_USER" "$cert" 2>/dev/null || true
		chmod 640 "$cert" 2>/dev/null || true
	fi

	mkdir -p "$CF_LOG_DIR" "$CF_STATE_DIR" 2>/dev/null
	chgrp "$CF_RUN_USER" "$CF_LOG_DIR" "$CF_STATE_DIR" 2>/dev/null || true
	chmod 775 "$CF_LOG_DIR" "$CF_STATE_DIR" 2>/dev/null || true
	touch "$CF_APP_LOG" "$CF_CORE_LOG" 2>/dev/null
	chgrp "$CF_RUN_USER" "$CF_APP_LOG" "$CF_CORE_LOG" 2>/dev/null || true
	chmod 664 "$CF_APP_LOG" "$CF_CORE_LOG" 2>/dev/null || true
}

cf_info() {
	printf '%s\n' "$*"
}

cf_warn() {
	printf '%s\n' "$*" >&2
	cf_log "WARN: $*"
}

cf_err() {
	printf '%s\n' "$*" >&2
	cf_log "ERROR: $*"
}

cf_require_root() {
	[ "$(id -u)" -eq 0 ] || {
		cf_err "Please run as root"
		exit 1
	}
}

cf_get() {
	local section="$1"
	local option="$2"
	local default="${3:-}"
	local value

	value="$(uci -q get "cloudflared.$section.$option" 2>/dev/null)"
	if [ -z "$value" ]; then
		printf '%s' "$default"
	else
		printf '%s' "$value"
	fi
}

cf_set() {
	local section="$1"
	local option="$2"
	local value="$3"

	uci set "cloudflared.$section.$option=$value"
}

cf_commit() {
	uci commit cloudflared 2>/dev/null || true
}

# Legacy installs shared one base directory for binary and data. New installs
# keep the binary under /opt/cloudflared and all persistent data under /etc.
cf_legacy_base_path() {
	uci -q get cloudflared.main.base_path 2>/dev/null
}

cf_data_path() {
	local path legacy

	path="$(uci -q get cloudflared.main.data_path 2>/dev/null)"
	[ -n "$path" ] || path="$(cf_legacy_base_path)"
	[ -n "$path" ] || path="$CF_DEFAULT_DATA_PATH"
	printf '%s' "$path"
}

cf_core_dir() {
	printf '%s' "$CF_DEFAULT_CORE_DIR"
}

cf_backup_dir() {
	local section="$1"
	printf '%s/%s' "$CF_BACKUP_DIR" "$section"
}

# Kept as a compatibility alias for call sites that still refer to the old
# combined base directory.
cf_base_path() {
	local data legacy
	data="$(uci -q get cloudflared.main.data_path 2>/dev/null)"
	if [ -n "$data" ]; then
		printf '%s' "$data"
		return 0
	fi
	legacy="$(cf_legacy_base_path)"
	[ -n "$legacy" ] && { printf '%s' "$legacy"; return 0; }
	printf '%s' "$CF_DEFAULT_BASE"
}

cf_download_url() {
	cf_get main download_url "$CF_DEFAULT_DOWNLOAD"
}

cf_find_binary() {
	local custom core legacy f

	custom="$(cf_get main cloudflared_path)"
	if [ -n "$custom" ] && [ -x "$custom" ]; then
		printf '%s' "$custom"
		return 0
	fi

	core="$(cf_core_dir)"
	for f in "$core/cloudflared" "$core"/cloudflared-linux-*; do
		if [ -x "$f" ]; then
			printf '%s' "$f"
			return 0
		fi
	done

	legacy="$(cf_legacy_base_path)"
	if [ -n "$legacy" ]; then
		for f in "$legacy/cloudflared" "$legacy"/cloudflared-linux-*; do
			if [ -x "$f" ]; then
				printf '%s' "$f"
				return 0
			fi
		done
	fi

	if [ -x "/usr/bin/cloudflared" ]; then
		printf '%s' "/usr/bin/cloudflared"
		return 0
	fi

	return 1
}

cf_version() {
	local bin="$1"

	[ -n "$bin" ] || bin="$(cf_find_binary)" || return 1
	[ -x "$bin" ] || return 1

	"$bin" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

cf_legacy_tunnel_dir() {
	local section="$1"
	local data legacy tid dir

	data="$(cf_data_path)"
	legacy="$(cf_legacy_base_path)"
	tid="$(cf_get "$section" tunnel_id)"
	[ -n "$tid" ] || return 1

	# Older releases addressed anonymous sections as @tunnel[N] and stored
	# their data under the old base directory. Reuse that directory when it
	# still belongs to this tunnel so upgrades do not lose credentials.
	for dir in "$data"/tunnels/@* ${legacy:+"$legacy"/tunnels/@*}; do
		[ -d "$dir" ] || continue
		if [ -f "$dir/$tid.json" ]; then
			printf '%s' "$dir"
			return 0
		fi
		if [ -f "$dir/config.yml" ] && grep -qx "tunnel: $tid" "$dir/config.yml" 2>/dev/null; then
			printf '%s' "$dir"
			return 0
		fi
	done

	return 1
}

cf_tunnel_dir() {
	local section="$1"
	local data legacy dir

	data="$(cf_data_path)"
	dir="$(cf_get "$section" data_dir)"

	if [ -z "$dir" ]; then
		if [ "$section" = "default" ] && [ -f "$data/config.yml" ]; then
			dir="$data"
		else
			dir="$data/tunnels/$section"
			if [ ! -d "$dir" ]; then
				legacy="$(cf_legacy_tunnel_dir "$section" 2>/dev/null)" || legacy=""
				[ -n "$legacy" ] && dir="$legacy"
			fi
		fi
	fi

	printf '%s' "$dir"
}

cf_cert_path() {
	local section="$1"
	local path dir legacy imported use_global global

	imported="$(cf_get "$section" imported 0)"
	use_global="$(cf_get "$section" use_global_cert 0)"
	if [ "$use_global" = "1" ] && [ "$imported" != "1" ]; then
		global="$(cf_get main cert_path)"
		[ -n "$global" ] || global="$(cf_data_path)/cert.pem"
		[ -f "$global" ] && printf '%s' "$global" && return 0
	fi

	path="$(cf_get "$section" cert_path)"
	# An explicitly configured but missing cert must not hide a valid
	# per-tunnel or global certificate.
	[ -n "$path" ] && [ ! -f "$path" ] && path=""
	if [ -z "$path" ]; then
		dir="$(cf_tunnel_dir "$section")"
		[ -f "$dir/cert.pem" ] && path="$dir/cert.pem"
		if [ -z "$path" ]; then
			legacy="$(cf_legacy_tunnel_dir "$section" 2>/dev/null)" || legacy=""
			[ -n "$legacy" ] && [ -f "$legacy/cert.pem" ] && path="$legacy/cert.pem"
		fi
	fi
	if [ -z "$path" ] && [ "$imported" != "1" ]; then
		path="$(cf_get main cert_path)"
	fi
	if [ -z "$path" ] && [ "$imported" != "1" ]; then
		path="$(cf_data_path)/cert.pem"
	fi

	printf '%s' "$path"
}

# Target path used when writing a newly authorized certificate. Always keep
# it inside the tunnel directory unless the user explicitly configured one,
# so authorizing another Cloudflare account cannot overwrite a shared cert.
cf_tunnel_cert_target() {
	local section="$1"
	local path dir use_global global

	use_global="$(cf_get "$section" use_global_cert 0)"
	if [ "$use_global" = "1" ]; then
		global="$(cf_get main cert_path)"
		[ -n "$global" ] || global="$(cf_data_path)/cert.pem"
		printf '%s' "$global"
		return 0
	fi

	path="$(cf_get "$section" cert_path)"
	if [ -n "$path" ]; then
		printf '%s' "$path"
		return 0
	fi

	dir="$(cf_tunnel_dir "$section")"
	printf '%s/cert.pem' "$dir"
}

cf_config_path() {
	local section="$1"
	local path

	path="$(cf_get "$section" config_path)"
	[ -n "$path" ] || path="$(cf_tunnel_dir "$section")/config.yml"

	printf '%s' "$path"
}

cf_find_credentials_by_id() {
	local uuid="$1"
	local data legacy f

	[ -n "$uuid" ] || return 1
	data="$(cf_data_path)"
	legacy="$(cf_legacy_base_path)"

	for f in "$data/tunnels"/*/"$uuid.json" "$data/$uuid.json"; do
		[ -f "$f" ] || continue
		printf '%s' "$f"
		return 0
	done

	if [ -n "$legacy" ] && [ "$legacy" != "$data" ]; then
		for f in "$legacy/tunnels"/*/"$uuid.json" "$legacy/$uuid.json"; do
			[ -f "$f" ] || continue
			printf '%s' "$f"
			return 0
		done
	fi

	# Pre-migration installs may still hold credentials here even when the
	# current config no longer has a legacy base_path.
	if [ "$data" != "$CF_DEFAULT_BASE" ]; then
		for f in "$CF_DEFAULT_BASE/tunnels"/*/"$uuid.json" "$CF_DEFAULT_BASE/$uuid.json"; do
			[ -f "$f" ] || continue
			printf '%s' "$f"
			return 0
		done
	fi

	for f in "/root/.cloudflared/$uuid.json"; do
		[ -f "$f" ] || continue
		printf '%s' "$f"
		return 0
	done

	return 1
}

cf_credentials() {
	local section="$1"
	local file dir tid data legacy_base legacy

	file="$(cf_get "$section" credentials_file)"
	if [ -n "$file" ] && [ -f "$file" ]; then
		printf '%s' "$file"
		return 0
	fi

	dir="$(cf_tunnel_dir "$section")"
	tid="$(cf_get "$section" tunnel_id)"
	data="$(cf_data_path)"
	legacy_base="$(cf_legacy_base_path)"
	legacy="$(cf_legacy_tunnel_dir "$section" 2>/dev/null)" || legacy=""

	for file in "$dir/$tid.json" "$dir"/*.json \
	            "$data/$tid.json" "$data"/*.json \
	            "/root/.cloudflared/$tid.json" "/root/.cloudflared"/*.json; do
		[ -f "$file" ] || continue
		printf '%s' "$file"
		return 0
	done

	# Old installs kept credentials directly in the legacy base directory.
	if [ -n "$legacy_base" ] && [ "$legacy_base" != "$data" ]; then
		for file in "$legacy_base/$tid.json" "$legacy_base"/*.json; do
			[ -f "$file" ] || continue
			printf '%s' "$file"
			return 0
		done
	fi

	if [ -n "$legacy" ] && [ "$legacy" != "$dir" ]; then
		for file in "$legacy/$tid.json" "$legacy"/*.json; do
			[ -f "$file" ] || continue
			printf '%s' "$file"
			return 0
		done
	fi

	return 1
}

# Format anonymous sections as their internal cfXXXX names. This matches the
# section names exposed to LuCI and the values stored in the "tunnel" option;
# plain "uci show" would use @type[index] aliases instead and they differ.
cf_show() {
	uci -q -X show cloudflared 2>/dev/null
}

cf_ingress_sections() {
	local target="$1"
	local section tunnel count

	count="$(cf_tunnel_sections | wc -l | tr -d ' ')"

	cf_show | sed -n "s/^cloudflared\.\([^.=]*\)=ingress$/\1/p" | \
		while read -r section; do
			[ -n "$section" ] || continue
			tunnel="$(uci -q get "cloudflared.$section.tunnel" 2>/dev/null)"
			if [ "$tunnel" = "$target" ]; then
				printf '%s\n' "$section"
			elif [ "${count:-0}" -le 1 ]; then
				# Legacy orphan: older UI versions could save an empty or
				# stale tunnel reference. With a single tunnel it is
				# unambiguous.
				printf '%s\n' "$section"
			fi
		done
}

cf_tunnel_sections() {
	cf_show | sed -n "s/^cloudflared\.\([^.=]*\)=tunnel$/\1/p"
}

cf_gen_config() {
	local section="$1"
	local dir cfg tunnel_id creds cert tmp bakdir ingress host service name
	local host_header no_tls origin_name ipath
	local connect_timeout tls_timeout tcp_keepalive no_happy
	local proxy_addr proxy_port proxy_type
	local http2 disable_chunked keepalive_conns keepalive_timeout ca_pool bastion
	local scheme is_http is_tls is_tcp req

	dir="$(cf_tunnel_dir "$section")"
	cfg="$(cf_config_path "$section")"
	tunnel_id="$(cf_get "$section" tunnel_id)"
	creds="$(cf_credentials "$section")"
	cert="$(cf_cert_path "$section")"
	name="$(cf_get "$section" name)"

	[ -n "$tunnel_id" ] || {
		cf_err "tunnel_id missing for tunnel '${name:-$section}' (section $section)"
		return 1
	}
	[ -n "$creds" ] || {
		cf_err "credentials file missing for tunnel '${name:-$section}' (section $section); upload the <tunnel_id>.json file in Certificate & Credentials"
		return 1
	}

	mkdir -p "$dir" || return 1
	cf_fix_dir_perms "$dir"
	tmp="$(mktemp "$dir/.config.XXXXXX" 2>/dev/null)" || tmp="$dir/.config.$$"

	{
		printf 'tunnel: %s\n' "$tunnel_id"
		printf 'credentials-file: %s\n' "$creds"
		if [ -f "$cert" ]; then
			printf 'origincert: %s\n' "$cert"
		fi
		printf '\n'
		printf 'ingress:\n'

		for ingress in $(cf_ingress_sections "$section"); do
			[ "$(cf_get "$ingress" enabled 1)" = "1" ] || continue
			host="$(cf_get "$ingress" hostname)"
			service="$(cf_get "$ingress" service)"
			[ -n "$host" ] || continue
			[ -n "$service" ] || continue

			host_header="$(cf_get "$ingress" origin_host_header)"
			no_tls="$(cf_get "$ingress" no_tls_verify 0)"
			origin_name="$(cf_get "$ingress" origin_server_name)"
			ipath="$(cf_get "$ingress" ingress_path)"
			connect_timeout="$(cf_get "$ingress" origin_connect_timeout)"
			tls_timeout="$(cf_get "$ingress" origin_tls_timeout)"
			tcp_keepalive="$(cf_get "$ingress" origin_tcp_keepalive)"
			no_happy="$(cf_get "$ingress" origin_no_happy_eyeballs 0)"
			proxy_addr="$(cf_get "$ingress" origin_proxy_address)"
			proxy_port="$(cf_get "$ingress" origin_proxy_port)"
			proxy_type="$(cf_get "$ingress" origin_proxy_type)"
			http2="$(cf_get "$ingress" origin_http2 0)"
			disable_chunked="$(cf_get "$ingress" origin_disable_chunked 0)"
			keepalive_conns="$(cf_get "$ingress" origin_keepalive_connections)"
			keepalive_timeout="$(cf_get "$ingress" origin_keepalive_timeout)"
			ca_pool="$(cf_get "$ingress" origin_ca_pool)"
			bastion="$(cf_get "$ingress" origin_bastion_mode 0)"

			scheme="${service%%:*}"
			is_http=0
			is_tls=0
			is_tcp=0
			case "$scheme" in
				http)  is_http=1; is_tcp=1 ;;
				https) is_http=1; is_tls=1; is_tcp=1 ;;
				unix)  is_http=1 ;;
				tcp|ssh|rdp|smb) is_tcp=1 ;;
			esac

			printf '  - hostname: %s\n' "$host"
			[ "$is_http" = "1" ] && [ -n "$ipath" ] && printf '    path: %s\n' "$ipath"
			printf '    service: %s\n' "$service"
			req=0
			[ "$scheme" != "http_status" ] && [ -n "$connect_timeout" ] && req=1
			[ "$is_tls" = "1" ] && [ -n "$tls_timeout" ] && req=1
			[ "$is_tcp" = "1" ] && [ -n "$tcp_keepalive" ] && req=1
			[ "$is_tcp" = "1" ] && [ "$no_happy" = "1" ] && req=1
			[ "$is_tcp" = "1" ] && [ -n "$proxy_addr" ] && req=1
			[ "$is_tcp" = "1" ] && [ -n "$proxy_port" ] && req=1
			[ "$is_tcp" = "1" ] && [ -n "$proxy_type" ] && req=1
			[ "$is_http" = "1" ] && [ -n "$host_header" ] && req=1
			[ "$is_http" = "1" ] && [ "$http2" = "1" ] && req=1
			[ "$is_http" = "1" ] && [ "$disable_chunked" = "1" ] && req=1
			[ "$is_http" = "1" ] && [ -n "$keepalive_conns" ] && req=1
			[ "$is_http" = "1" ] && [ -n "$keepalive_timeout" ] && req=1
			[ "$is_tls" = "1" ] && [ -n "$origin_name" ] && req=1
			[ "$is_tls" = "1" ] && [ -n "$ca_pool" ] && req=1
			[ "$is_tls" = "1" ] && [ "$no_tls" = "1" ] && req=1
			[ "$scheme" = "ssh" ] && [ "$bastion" = "1" ] && req=1

			if [ "$req" = "1" ]; then
				printf '    originRequest:\n'
				[ -n "$connect_timeout" ] && printf '      connectTimeout: %s\n' "$connect_timeout"
				[ "$is_tls" = "1" ] && [ -n "$tls_timeout" ] && printf '      tlsTimeout: %s\n' "$tls_timeout"
				[ "$is_tcp" = "1" ] && [ -n "$tcp_keepalive" ] && printf '      tcpKeepAlive: %s\n' "$tcp_keepalive"
				[ "$is_tcp" = "1" ] && [ "$no_happy" = "1" ] && printf '      noHappyEyeballs: true\n'
				[ "$is_tcp" = "1" ] && [ -n "$proxy_addr" ] && printf '      proxyAddress: %s\n' "$proxy_addr"
				[ "$is_tcp" = "1" ] && [ -n "$proxy_port" ] && printf '      proxyPort: %s\n' "$proxy_port"
				[ "$is_tcp" = "1" ] && [ -n "$proxy_type" ] && printf '      proxyType: %s\n' "$proxy_type"
				[ "$is_http" = "1" ] && [ -n "$host_header" ] && printf '      httpHostHeader: %s\n' "$host_header"
				[ "$is_http" = "1" ] && [ "$http2" = "1" ] && printf '      http2Origin: true\n'
				[ "$is_http" = "1" ] && [ "$disable_chunked" = "1" ] && printf '      disableChunkedEncoding: true\n'
				[ "$is_http" = "1" ] && [ -n "$keepalive_conns" ] && printf '      keepAliveConnections: %s\n' "$keepalive_conns"
				[ "$is_http" = "1" ] && [ -n "$keepalive_timeout" ] && printf '      keepAliveTimeout: %s\n' "$keepalive_timeout"
				[ "$is_tls" = "1" ] && [ -n "$origin_name" ] && printf '      originServerName: %s\n' "$origin_name"
				[ "$is_tls" = "1" ] && [ -n "$ca_pool" ] && printf '      caPool: %s\n' "$ca_pool"
				[ "$is_tls" = "1" ] && [ "$no_tls" = "1" ] && printf '      noTLSVerify: true\n'
				[ "$scheme" = "ssh" ] && [ "$bastion" = "1" ] && printf '      bastionMode: true\n'
			fi
			printf '\n'
		done

		printf '  - service: http_status:404\n'
	} > "$tmp" || {
		rm -f "$tmp"
		return 1
	}

	# Keep rotating config backups outside /etc so sysupgrade does not carry
	# them. Fall back next to the config only when the backup dir is unusable.
	bakdir="$(cf_backup_dir "$section")"
	if ! mkdir -p "$bakdir" 2>/dev/null; then
		bakdir="$dir"
	fi
	if [ -f "$bakdir/config.yml.bak1" ]; then
		mv -f "$bakdir/config.yml.bak1" "$bakdir/config.yml.bak2" 2>/dev/null || true
	fi
	if [ -f "$cfg" ]; then
		mv -f "$cfg" "$bakdir/config.yml.bak1" 2>/dev/null || true
	fi

	mv -f "$tmp" "$cfg" || return 1
	chmod 600 "$cfg" 2>/dev/null || true
	cf_fix_file_perms "$cfg"

	printf '%s' "$cfg"
}

cf_domain_rewrite() {
	local section="$1"
	local old="$2"
	local new="$3"
	local changed=0 ingress host prefix

	[ -n "$old" ] || {
		printf '0'
		return 0
	}

	for ingress in $(cf_ingress_sections "$section"); do
		[ "$(cf_get "$ingress" enabled 1)" = "1" ] || continue
		host="$(cf_get "$ingress" hostname)"
		[ -n "$host" ] || continue

		if [ "$host" = "$old" ]; then
			cf_set "$ingress" hostname "$new"
			changed=$((changed + 1))
		elif [ "${host%.$old}" != "$host" ]; then
			prefix="${host%.$old}"
			cf_set "$ingress" hostname "$prefix.$new"
			changed=$((changed + 1))
		fi
	done

	[ "$changed" -gt 0 ] && cf_commit
	printf '%s' "$changed"
}

cf_dns_sync() {
	local section="$1"
	local bin cert tunnel_id ingress host created=0

	bin="$(cf_find_binary)" || {
		cf_err "cloudflared binary not found"
		return 1
	}
	cert="$(cf_cert_path "$section")"
	tunnel_id="$(cf_get "$section" tunnel_id)"

	[ -n "$tunnel_id" ] || {
		cf_err "tunnel_id missing for section '$section'"
		return 1
	}
	[ -f "$cert" ] || {
		cf_err "cert.pem missing: $cert"
		return 1
	}

	for ingress in $(cf_ingress_sections "$section"); do
		[ "$(cf_get "$ingress" enabled 1)" = "1" ] || continue
		host="$(cf_get "$ingress" hostname)"
		[ -n "$host" ] || continue

		if "$bin" tunnel --origincert "$cert" route dns "$tunnel_id" "$host" >/dev/null 2>&1; then
			created=$((created + 1))
			cf_warn "DNS synced: $host"
		else
			cf_warn "DNS record exists or sync failed: $host"
		fi
	done

	printf '%s' "$created"
}

cf_restart() {
	if [ -x /etc/init.d/cloudflared ]; then
		/etc/init.d/cloudflared restart >/dev/null 2>&1
	fi
}

cf_valid_domain() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

cf_arch_asset() {
	local arch

	arch="$(uname -m)"
	case "$arch" in
		aarch64|arm64) printf 'cloudflared-linux-arm64' ;;
		x86_64|amd64)  printf 'cloudflared-linux-amd64' ;;
		armv7l|armhf)  printf 'cloudflared-linux-arm' ;;
		armv6l)        printf 'cloudflared-linux-arm' ;;
		i386|i686)     printf 'cloudflared-linux-386' ;;
		mips)          printf 'cloudflared-linux-mips' ;;
		mipsel)        printf 'cloudflared-linux-mipsle' ;;
		*)             return 1 ;;
	esac
}

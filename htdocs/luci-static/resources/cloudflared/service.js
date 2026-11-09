'use strict';
'require baseclass';

function parseService(service) {
	const out = { protocol: 'http', host: '', port: null, extra: '', valid: false };
	if (!service)
		return out;

	const match = String(service).match(/^([A-Za-z0-9_]+):(.+)$/);
	if (!match)
		return out;

	const scheme = match[1].toLowerCase();
	const rest = match[2];

	if (scheme === 'unix' || scheme === 'http_status') {
		return { protocol: scheme, host: '', port: null, extra: rest, valid: true };
	}

	let host = '';
	let port = null;

	let m = rest.match(/^\/\/\[([^\]]+)\]:(\d+)/);
	if (m) {
		host = m[1];
		port = parseInt(m[2], 10);
	}
	else {
		m = rest.match(/^\/\/([^:/]+):(\d+)/);
		if (m) {
			host = m[1];
			port = parseInt(m[2], 10);
		}
		else {
			m = rest.match(/^\/\/([^:/]+)/);
			if (m)
				host = m[1];
		}
	}

	if (!host)
		return out;

	if (!port)
		port = (scheme === 'https') ? 443 : 80;

	return { protocol: scheme, host: host, port: port, extra: rest, valid: true };
}

function composeService(protocol, host, port, extra) {
	const p = String(protocol || 'http').toLowerCase();

	if (p === 'unix' || p === 'http_status')
		return p + ':' + (extra || '');

	let h = String(host || '');
	if (h.indexOf(':') !== -1 && h.charAt(0) !== '[')
		h = '[' + h + ']';

	const q = String(port || '');
	return p + '://' + h + (q !== '' ? ':' + q : '');
}

return baseclass.extend({
	parseService: parseService,
	composeService: composeService
});

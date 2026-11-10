'use strict';
'require baseclass';

function endpoint() {
	return L.url('admin', 'services', 'cloudflared', 'action');
}

function token() {
	return (L.env && L.env.token) ? L.env.token : '';
}

function decode(text, status) {
	try {
		const data = JSON.parse(text);
		if (data && typeof(data) == 'object')
			return data;
	}
	catch (e) {}

	return { ok: false, message: 'HTTP ' + status + ' (invalid response)' };
}

function action(name, params) {
	const body = new URLSearchParams();
	body.append('action', name);
	body.append('token', token());

	for (const key in (params || {})) {
		const val = params[key];
		if (val !== undefined && val !== null)
			body.append(key, val);
	}

	return fetch(endpoint(), {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: body.toString(),
		credentials: 'same-origin'
	}).then(function(res) {
		return res.text().then(function(text) {
			return decode(text, res.status);
		});
	}).catch(function(err) {
		return { ok: false, message: String(err) };
	});
}

function upload(name, section, file) {
	const form = new FormData();
	form.append('file', file);

	const url = L.url('admin', 'services', 'cloudflared', 'upload') +
		'?action=' + encodeURIComponent(name) +
		'&section=' + encodeURIComponent(section || '') +
		'&token=' + encodeURIComponent(token());

	return fetch(url, {
		method: 'POST',
		body: form,
		credentials: 'same-origin'
	}).then(function(res) {
		return res.text().then(function(text) {
			return decode(text, res.status);
		});
	}).catch(function(err) {
		return { ok: false, message: String(err) };
	});
}

function message(result) {
	const msg = (result && result.message) ? result.message : _('Request failed');

	if (/unknown section/i.test(msg))
		return _('This tunnel is not saved yet. Click the page-level Save or Save & Apply button below the tunnel table first, then try again.');

	return msg;
}

return baseclass.extend({
	action: action,
	upload: upload,
	message: message
});

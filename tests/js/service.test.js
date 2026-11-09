'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
	path.join(__dirname, '..', '..', 'htdocs', 'luci-static', 'resources', 'cloudflared', 'service.js'),
	'utf8');

const service = new Function('baseclass', source)({ extend: function(obj) { return obj; } });

assert.deepEqual(service.parseService('http://192.168.1.5:9000'),
	{ protocol: 'http', host: '192.168.1.5', port: 9000, extra: '//192.168.1.5:9000', valid: true });

assert.deepEqual(service.parseService('https://origin.example.com'),
	{ protocol: 'https', host: 'origin.example.com', port: 443, extra: '//origin.example.com', valid: true });

assert.deepEqual(service.parseService('unix:/run/app.sock'),
	{ protocol: 'unix', host: '', port: null, extra: '/run/app.sock', valid: true });

assert.deepEqual(service.parseService('http_status:404'),
	{ protocol: 'http_status', host: '', port: null, extra: '404', valid: true });

assert.equal(service.parseService('garbage').valid, false);
assert.equal(service.parseService('').valid, false);

assert.equal(service.composeService('http', '192.168.1.5', '9000', ''), 'http://192.168.1.5:9000');
assert.equal(service.composeService('https', 'origin.example.com', '443', ''), 'https://origin.example.com:443');
assert.equal(service.composeService('unix', '', '', '/run/app.sock'), 'unix:/run/app.sock');
assert.equal(service.composeService('http_status', '', '', '404'), 'http_status:404');
assert.equal(service.composeService('tcp', '2001:db8::1', '22', ''), 'tcp://[2001:db8::1]:22');

for (const value of [
	'http://192.168.1.5:9000',
	'https://origin.example.com:8443',
	'unix:/run/app.sock',
	'http_status:404',
	'tcp://[2001:db8::1]:22'
]) {
	const parts = service.parseService(value);
	assert.equal(service.composeService(parts.protocol, parts.host, parts.port, parts.extra), value,
		'round trip failed for ' + value);
}

console.log('js service parser test passed');

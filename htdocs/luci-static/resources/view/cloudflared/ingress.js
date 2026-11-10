'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require poll';
'require cloudflared.api as cfApi';
'require cloudflared.result as cfResult';
'require cloudflared.service as cfService';

const TCP_RE = /^(http|https|tcp|ssh|rdp|smb)$/;
const HTTP_RE = /^(http|https|unix)$/;
const CONNECT_RE = /^(http|https|tcp|ssh|rdp|smb|unix)$/;
const TLS_RE = /^https$/;
const PARALLEL_LIMIT = 20;

function savedService(section_id) {
	return uci.get('cloudflared', section_id, 'service') || '';
}

function savedParts(section_id) {
	return cfService.parseService(savedService(section_id));
}

function dnsSkipLabel(code) {
	switch (code) {
	case 'missing_hostname':
		return _('No hostname configured');
	case 'missing':
		return _('Missing API token, tunnel ID or domain');
	case 'query_failed':
		return _('Unable to query DNS records');
	case 'not_found':
		return _('No DNS record points to this tunnel');
	default:
		return code;
	}
}

function openDeleteIngress(section_id) {
	const hostname = uci.get('cloudflared', section_id, 'hostname') || '';
	const dnsBox = E('input', {
		'type': 'checkbox',
		'id': 'cf-ingress-delete-dns',
		'checked': hostname ? '' : null,
		'disabled': hostname ? null : ''
	});

	const deleteBtn = E('button', {
		'class': 'btn cbi-button cbi-button-negative important',
		'click': function(ev) {
			const btn = ev.currentTarget;
			btn.disabled = true;
			btn.classList.add('spinning');

			cfApi.action('ingress_delete', {
				section: section_id,
				delete_dns: dnsBox.checked ? '1' : '0'
			}).then(function(r) {
				btn.disabled = false;
				btn.classList.remove('spinning');

				if (!r || !r.ok) {
					ui.showModal(_('Delete Ingress Rule'), [
						E('p', {}, [ cfApi.message(r) ]),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Dismiss') ])
						])
					]);
					return;
				}

				ui.hideModal();

				const parts = [ _('Ingress rule deleted') ];
				if (r.dns_deleted)
					parts.push(_('DNS record deleted'));
				if (r.dns_failed)
					parts.push(_('DNS record deletion failed'));
				if (r.dns_skipped)
					parts.push(_('DNS record not deleted: %s').format(dnsSkipLabel(r.dns_skipped)));
				if (r.config === false)
					parts.push(_('Config regeneration failed. Check the log.'));
				else if (r.restarted === false)
					parts.push(_('Service restart failed. Check the log.'));

				const warn = r.dns_failed || r.dns_skipped ||
					r.config === false || r.restarted === false;

				if (cfResult.store('cf-ingress-delete-result', parts, warn ? 'warning' : 'info')) {
					location.reload();
				}
				else {
					ui.addNotification(null, E('p', {}, [ parts.join(' · ') ]),
						warn ? 'warning' : 'info');
					setTimeout(function() { location.reload(); }, 10000);
				}
			});
		}
	}, [ _('Delete') ]);

	ui.showModal(_('Delete Ingress Rule'), [
		E('p', {}, [ _('Delete the local ingress rule for "%s"?').format(hostname || section_id) ]),
		E('label', { 'class': 'cf-option-row', 'for': 'cf-ingress-delete-dns' }, [
			dnsBox,
			E('span', {}, [
				E('strong', {}, [ _('Delete the matching remote DNS record') ]),
				E('div', { 'class': 'cf-note' }, [
					_('Removes the Cloudflare DNS record that points this hostname to the tunnel.')
				])
			])
		]),
		E('p', { 'class': 'cf-note' }, [ _('This action takes effect immediately.') ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
			' ',
			deleteBtn
		])
	]);
}

function openDeleteSelectedIngress(section_ids, toolbarButton) {
	const dnsBox = E('input', {
		'type': 'checkbox',
		'id': 'cf-ingress-delete-selected-dns',
		'checked': ''
	});

	ui.showModal(_('Delete Selected Ingress Rules'), [
		E('p', {}, [ _('Delete %s selected ingress rules?').format(section_ids.length) ]),
		E('label', { 'class': 'cf-option-row', 'for': 'cf-ingress-delete-selected-dns' }, [
			dnsBox,
			E('span', {}, [
				E('strong', {}, [ _('Delete matching remote DNS records') ]),
				E('div', { 'class': 'cf-note' }, [
					_('Removes matching Cloudflare DNS records before deleting the local rules.')
				])
			])
		]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-negative important',
				'click': function(ev) {
					const button = ev.currentTarget;
					setBusyButton(button, true);
					setBusyButton(toolbarButton, true);

					section_ids.reduce(function(chain, section) {
						return chain.then(function(results) {
							return cfApi.action('ingress_delete', {
								section: section,
								delete_dns: dnsBox.checked ? '1' : '0'
							}).then(function(r) {
								results.push(r || { ok: false, message: _('Request failed') });
								return results;
							}, function(err) {
								results.push({ ok: false, message: String(err) });
								return results;
							});
						});
					}, Promise.resolve([])).then(function(results) {
						setBusyButton(button, false);
						setBusyButton(toolbarButton, false);
						ui.hideModal();
						const deleted = results.filter(function(r) { return r && r.ok; }).length;
						const failed = results.length - deleted;
						const failedDetails = results.filter(function(r) {
							return !r || !r.ok;
						}).map(function(r, index) {
							const section = section_ids[index] || '';
							const hostname = (r && r.hostname) || section;
							return hostname + ': ' + ((r && r.message) || _('Request failed'));
						});
						const dnsDeleted = results.reduce(function(n, r) { return n + (r && r.dns_deleted || 0); }, 0);
						const dnsFailed = results.reduce(function(n, r) { return n + (r && r.dns_failed || 0); }, 0);
						const parts = [ _('Ingress rules deleted: %s').format(deleted) ];
						if (dnsDeleted)
							parts.push(_('DNS records deleted: %s').format(dnsDeleted));
						if (dnsFailed)
							parts.push(_('DNS record deletion failed: %s').format(dnsFailed));
						if (failed)
							parts.push(_('Ingress rules failed: %s').format(failed));
						failedDetails.forEach(function(detail) { parts.push(detail); });

						if (cfResult.store('cf-ingress-delete-result', parts, failed || dnsFailed ? 'warning' : 'info'))
							location.reload();
						else {
							ui.addNotification(null, E('p', {}, [ parts.join(' · ') ]), failed || dnsFailed ? 'warning' : 'info');
							setTimeout(function() { location.reload(); }, 10000);
						}
					});
				}
			}, [ _('Delete') ])
		])
	]);
}

function widgetValue(sectionObj, section_id, name) {
	for (let i = 0; i < sectionObj.children.length; i++) {
		if (sectionObj.children[i].option === name) {
			const val = sectionObj.children[i].formvalue(section_id);
			return (val != null) ? val : null;
		}
	}
	return null;
}

function composeFrom(sectionObj, section_id, override) {
	const saved = savedParts(section_id);

	function pick(name, fallback) {
		if (override && override.hasOwnProperty(name))
			return override[name];

		const val = widgetValue(sectionObj, section_id, name);
		return (val != null && val !== '') ? val : fallback;
	}

	const protocol = String(pick('_protocol', saved.protocol) || 'http').toLowerCase();
	const host = String(pick('_ip', saved.host) || '');
	const port = String(pick('_port', saved.port || '') || '');
	const extra = (protocol === 'unix')
		? String(pick('_path', (saved.protocol === 'unix') ? saved.extra : '') || '')
		: (protocol === 'http_status')
			? String(pick('_status', (saved.protocol === 'http_status') ? saved.extra : '') || '')
			: '';

	if (protocol === 'unix')
		return extra ? cfService.composeService(protocol, '', '', extra) : '';

	if (protocol === 'http_status')
		return extra ? cfService.composeService(protocol, '', '', extra) : '';

	if (!host || !port)
		return '';

	return cfService.composeService(protocol, host, port, '');
}

function storeService(sectionObj, section_id, override) {
	const svc = composeFrom(sectionObj, section_id, override);

	if (svc)
		uci.set('cloudflared', section_id, 'service', svc);
	else
		uci.remove('cloudflared', section_id, 'service');
}

const ProtocolValue = form.ListValue.extend({
	cfgvalue: function(section_id) {
		const parts = savedParts(section_id);
		return parts.valid ? parts.protocol : 'http';
	},

	write: function(section_id, value) {
		storeService(this.section, section_id, { _protocol: value });
	},

	remove: function() {},

	clearConfirm: function(frame) {
		const box = frame ? frame.querySelector('.cf-protocol-confirm') : null;
		if (box)
			box.remove();
	},

	showConfirm: function(section_id, frame, value, old) {
		let box = frame.querySelector('.cf-protocol-confirm');

		if (!box) {
			box = E('div', { 'class': 'cf-protocol-confirm' });
			frame.appendChild(box);
		}

		const self = this;
		const label = (frame.tagName === 'TD') ? _('Confirm') : _('Confirm Protocol Change');

		dom.content(box, [
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-negative',
				'title': _('Confirm Protocol Change'),
				'click': function() {
					const pending = self._cfPending ? self._cfPending[section_id] : null;
					if (!pending)
						return;

					pending.accepted = true;
					self.clearConfirm(frame);

					try {
						const el = self.getUIElement(section_id);
						if (el && el.setValue)
							el.setValue(value);
					}
					catch (e) {}

					const el = self.getUIElement(section_id);
					const target = (el && el.node) ? el.node : frame.querySelector('.cbi-dropdown, select');

					if (target)
						target.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
				}
			}, [ label ])
		]);
	},

	render: function(option_index, section_id, in_table) {
		const self = this;

		return this.super('render', [ option_index, section_id, in_table ]).then(function(frame) {
			self._cfPending = self._cfPending || {};

			frame.addEventListener('widget-change', function(ev) {
				const pending = self._cfPending[section_id];

				if (pending && pending.accepted) {
					delete self._cfPending[section_id];
					return;
				}

				const old = self.cfgvalue(section_id);
				const value = self.formvalue(section_id);

				if (!old || value === old) {
					self.clearConfirm(frame);
					return;
				}

				ev.stopImmediatePropagation();
				self._cfPending[section_id] = { old: old, value: value };

				try {
					const el = self.getUIElement(section_id);
					if (el && el.setValue)
						el.setValue(old);
				}
				catch (e) {}

				self.showConfirm(section_id, frame, value, old);
			}, true);

			frame.addEventListener('widget-change', function() {
				updateModalFields(frame, self.formvalue(section_id));
			});

			updateModalFields(frame, self.formvalue(section_id));

			return frame;
		});
	}
});

function updateModalFields(frame, protocol) {
	const modal = frame.closest ? frame.closest('.cbi-modal') : null;
	if (!modal)
		return;

	const p = String(protocol || 'http').toLowerCase();
	const isTcp = [ 'http', 'https', 'tcp', 'ssh', 'rdp', 'smb' ].indexOf(p) >= 0;

	[ '_ip', '_port' ].forEach(function(name) {
		const cell = modal.querySelector('[data-name="' + name + '"]');
		if (cell)
			cell.style.display = isTcp ? '' : 'none';
	});
}

const HostValue = form.Value.extend({
	cfgvalue: function(section_id) {
		const parts = savedParts(section_id);
		return parts.valid ? parts.host : '';
	},

	write: function(section_id, value) {
		storeService(this.section, section_id, { _ip: value });
	},

	remove: function(section_id) {
		storeService(this.section, section_id, { _ip: '' });
	}
});

const PortValue = form.Value.extend({
	cfgvalue: function(section_id) {
		const parts = savedParts(section_id);
		return (parts.valid && parts.port) ? String(parts.port) : '';
	},

	write: function(section_id, value) {
		storeService(this.section, section_id, { _port: value });
	},

	remove: function(section_id) {
		storeService(this.section, section_id, { _port: '' });
	}
});

const UnixPathValue = form.Value.extend({
	cfgvalue: function(section_id) {
		const parts = savedParts(section_id);
		return (parts.valid && parts.protocol === 'unix') ? parts.extra : '';
	},

	write: function(section_id, value) {
		storeService(this.section, section_id, { _protocol: 'unix', _path: value });
	},

	remove: function(section_id) {
		storeService(this.section, section_id, { _protocol: 'unix', _path: '' });
	}
});

const StatusCodeValue = form.Value.extend({
	cfgvalue: function(section_id) {
		const parts = savedParts(section_id);
		return (parts.valid && parts.protocol === 'http_status') ? parts.extra : '';
	},

	write: function(section_id, value) {
		storeService(this.section, section_id, { _protocol: 'http_status', _status: value });
	},

	remove: function(section_id) {
		storeService(this.section, section_id, { _protocol: 'http_status', _status: '' });
	}
});

const ServiceSummary = form.DummyValue.extend({
	cfgvalue: function(section_id) {
		return savedService(section_id);
	},

	textvalue: function(section_id) {
		const svc = savedService(section_id);
		return E('code', {}, [ svc || '—' ]);
	}
});

const DnsStatus = form.DummyValue.extend({
	textvalue: function(section_id) {
		return E('span', { 'id': 'cf-dns-' + section_id }, [ _('Checking...') ]);
	}
});

function runIngressTest(section, result) {
	const box = result || document.getElementById('cf-test-' + section);
	if (box) {
		box.className = 'cf-test-result';
		box.textContent = '...';
		box.title = '';
	}

	return cfApi.action('test_ingress', { section: section }).then(function(r) {
		if (!box)
			return r;

		if (!r) {
			box.textContent = '✖ ' + _('Request failed');
			return r;
		}

		if (r.disabled) {
			box.className = 'cf-test-result';
			box.textContent = '— ' + (r.message || _('Disabled'));
			box.title = JSON.stringify(r, null, 2);
			return r;
		}

		const parts = [];
		if (r.backend) parts.push(r.backend);
		if (r.tunnel_running === false) parts.push(_('Tunnel not running'));
		if (r.dns) parts.push('DNS: ' + r.dns);
		if (r.public_status) parts.push(_('Public') + ': ' + r.public_status);

		const level = r.level || (r.ok ? 'ok' : 'error');
		const icon = (level === 'ok') ? '✔' : (level === 'warn' ? '⚠' : '✖');
		box.className = 'cf-test-result cf-test-' + level;
		box.textContent = icon + ' ' + parts.join(' | ');
		box.title = JSON.stringify(r, null, 2);
		return r;
	});
}

function setBusyButton(button, busy) {
	if (!button)
		return;

	if (busy) {
		if (button._cfBusy)
			return;

		button._cfBusy = true;
		button.disabled = true;
		button.classList.add('cf-busy');
		button.insertBefore(E('span', { 'class': 'cf-spinner' }), button.firstChild);
	}
	else {
		button._cfBusy = false;
		button.disabled = false;
		button.classList.remove('cf-busy');

		const spinner = button.querySelector('.cf-spinner');
		if (spinner)
			spinner.remove();
	}
}

const TestValue = form.DummyValue.extend({
	cfgvalue: function() { return null; },
	write: function() {},
	remove: function() {},

	renderWidget: function(section_id) {
		const result = E('span', { 'class': 'cf-test-result', 'id': 'cf-test-' + section_id });

		const btn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cf-test-button',
			'click': function() {
				runIngressTest(section_id, result);
			}
		}, [ _('Test') ]);

		return E('div', { 'class': 'cf-test-cell' }, [ btn, result ]);
	}
});

function dnsText(state) {
	if (state === 'synced')
		return E('span', { 'class': 'cf-site-running' }, [ '● ' + _('Synced') ]);
	if (state === 'pending')
		return E('span', { 'class': 'cf-site-pending' }, [ '● ' + _('Pending') ]);
	if (state === 'disabled')
		return E('span', { 'class': 'cf-site-disabled' }, [ '● ' + _('Inactive') ]);
	if (state === 'unknown')
		return E('span', { 'class': 'cf-site-abnormal' }, [ '● ' + _('Unknown') ]);
	return E('span', {}, [ '—' ]);
}

function dnsFailureMessage(msg) {
	if (!msg)
		return '';

	return msg
		.replace(/API: missing_token/g, 'API: ' + _('API token is not configured'))
		.replace(/API: missing_tunnel_id/g, 'API: ' + _('Tunnel ID is missing'))
		.replace(/API: zone_not_found/g, 'API: ' + _('DNS zone not found'))
		.replace(/API: record_exists:[^ ]*/g, 'API: ' + _('DNS record exists with a different target'))
		.replace(/API: api_failed/g, 'API: ' + _('Cloudflare API request failed'));
}

function showDnsSummary(results, title) {
	results = results || [];

	let created = 0;
	let exists = 0;
	let failed = 0;
	const failures = [];

	results.forEach(function(r) {
		if (!r || !r.ok) {
			if (r && r.disabled)
				return;
			failed++;
			if (r && r.message)
				failures.push(r.message);
			return;
		}

		created += r.created_count || 0;
		exists += r.exists_count || 0;
		failed += r.failed_count || 0;

		if (r.failed_messages) {
			for (const host in r.failed_messages)
				failures.push(host + ' — ' + dnsFailureMessage(r.failed_messages[host]));
		}
	});

	ui.showModal(title || _('DNS sync result'), [
		E('p', {}, [
			_('Created: %s').format(created) + ' · ' +
			_('Existing: %s').format(exists) + ' · ' +
			_('Failed: %s').format(failed)
		]),
		failures.length ? E('ul', {}, failures.map(function(line) {
			return E('li', {}, [ line ]);
		})) : '',
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Dismiss') ])
		])
	]);
}

return view.extend({
	load: function() {
		return uci.load('cloudflared');
	},

	render: function() {
		const view = this;
		const selected = view._ingressSelected || (view._ingressSelected = {});
		let updateSelectAll = function() {};

		function syncDnsIngress(section_id, button) {
			const force = button.getAttribute('data-force-sync') === '1';
			setBusyButton(button, true);

			return cfApi.action('dns_sync', {
				ingress: section_id,
				force_sync: force ? '1' : '0'
			}).then(function(r) {
				setBusyButton(button, false);

				const cell = document.getElementById('cf-dns-' + section_id);
				if (cell) {
					if (r && (r.created_count || r.exists_count))
						dom.content(cell, [ dnsText('synced') ]);
					else if (r && r.disabled)
						dom.content(cell, [ dnsText('disabled') ]);
					else
						dom.content(cell, [ dnsText('pending') ]);
				}

				showDnsSummary([ r ], _('DNS sync result'));
				return r;
			}, function(err) {
				setBusyButton(button, false);
				showDnsSummary([ { ok: false, message: String(err) } ], _('DNS sync result'));
			});
		}

		const map = new form.Map('cloudflared', _('Ingress Rules'), _('Map public hostnames to local services.') + ' ' + _('Save only stores changes; Save & Apply rebuilds config and restarts the service.'));

		const s = map.section(form.GridSection, 'ingress', _('Ingress Rules'));
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;
		s.renderSectionPlaceholder = function() {
			return E('span', { 'aria-hidden': 'true' });
		};

		let o = s.option(form.DummyValue, '_select', '');
		o.modalonly = false;
		const selectAll = E('input', {
			'type': 'checkbox',
			'id': 'cf-select-all-ingress',
			'title': _('Select all'),
			'aria-label': _('Select all')
		});
		o.title = selectAll;
			o.textvalue = function(section_id) {
			const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;
			const selectable = !(creates && creates[section_id]);

			if (selected[section_id] === undefined)
				selected[section_id] = false;
			if (!selectable)
				selected[section_id] = false;

			const cb = E('input', {
				'type': 'checkbox',
				'data-select-section': section_id,
				'checked': selected[section_id] ? '' : null,
				'disabled': selectable ? null : ''
			});
			cb.addEventListener('click', function(ev) { ev.stopPropagation(); });
			cb.addEventListener('change', function(ev) {
				ev.stopPropagation();
				selected[section_id] = cb.checked;
				updateSelectAll();
			});
			return cb;
		};

		o = s.option(form.ListValue, 'tunnel', _('Tunnel'));
		o.editable = true;
		uci.sections('cloudflared', 'tunnel', function(sec) {
			o.value(sec['.name'], sec.name || sec['.name']);
		});
		o.cfgvalue = function(section_id) {
			const current = uci.get('cloudflared', section_id, 'tunnel') || '';
			const tunnels = uci.sections('cloudflared', 'tunnel') || [];
			for (let i = 0; i < tunnels.length; i++)
				if (tunnels[i]['.name'] === current)
					return current;
			return (tunnels.length === 1) ? tunnels[0]['.name'] : current;
		};

		o = s.option(form.Value, 'hostname', _('Hostname'), _('Full hostname, e.g. app.example.com.'));
		o.placeholder = 'app.example.com';
		o.datatype = 'hostname';
		o.editable = true;
		o.write = function(section_id, value) {
			if (value && value.indexOf('.') === -1) {
				const ts = widgetValue(this.section, section_id, 'tunnel') ||
					uci.get('cloudflared', section_id, 'tunnel') || '';
				const domain = ts ? (uci.get('cloudflared', ts, 'domain') || '') : '';
				if (domain)
					value = value + '.' + domain;
			}
			return form.Value.prototype.write.call(this, section_id, value);
		};

		o = s.option(ProtocolValue, '_protocol', _('Protocol'));
		o.value('http', 'HTTP');
		o.value('https', 'HTTPS');
		o.value('tcp', 'TCP');
		o.value('ssh', 'SSH');
		o.value('rdp', 'RDP');
		o.value('smb', 'SMB');
		o.value('unix', _('Unix Socket'));
		o.value('http_status', _('HTTP Status'));
		o.default = 'http';
		o.editable = true;
		o.rmempty = false;

		o = s.option(HostValue, '_ip', _('IP / Host'));
		o.placeholder = '192.168.1.1 or localhost';
		o.datatype = 'host';
		o.editable = true;
		o.rmempty = true;

		o = s.option(PortValue, '_port', _('Port'));
		o.placeholder = '8080';
		o.datatype = 'port';
		o.editable = true;
		o.rmempty = true;

		o = s.option(ServiceSummary, '_service', _('Service'));
		o.modalonly = false;

		o = s.option(DnsStatus, '_dns', _('DNS'));
		o.modalonly = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.DummyValue, '_dns_sync', _('Sync DNS'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;
			const enabled = (uci.get('cloudflared', section_id, 'enabled') || '1') !== '0';
			const hostname = uci.get('cloudflared', section_id, 'hostname') || '';

			const btn = E('button', {
				'type': 'button',
				'class': 'btn cbi-button cf-dns-sync-button',
				'click': function(ev) {
					ev.preventDefault();
					ev.stopPropagation();
					if (!btn.disabled)
						syncDnsIngress(section_id, btn);
				}
			}, [ _('Sync DNS') ]);
			btn.disabled = !enabled || hostname === '' || !!(creates && creates[section_id]);
			return btn;
		};

		o = s.option(form.DummyValue, '_dns_force', '');
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;
			const hostname = uci.get('cloudflared', section_id, 'hostname') || '';
			const btn = E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-negative cf-dns-force-button',
				'data-force-sync': '1',
				'click': function(ev) {
					ev.preventDefault();
					ev.stopPropagation();
					if (!btn.disabled)
						syncDnsIngress(section_id, btn);
				}
			}, [ _('Force Sync') ]);
			btn.disabled = hostname === '' || !!(creates && creates[section_id]);
			return btn;
		};

		o = s.option(TestValue, '_test', _('Check'));
		o.editable = true;
		o.modalonly = false;

		/* ===== Protocol specific parameters (settings modal only) ===== */

		o = s.option(UnixPathValue, '_path', _('Unix Socket Path'));
		o.placeholder = '/var/run/service.sock';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', /^unix$/);

		o = s.option(StatusCodeValue, '_status', _('HTTP Status Code'));
		o.placeholder = '404';
		o.datatype = 'uinteger';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', /^http_status$/);

		o = s.option(form.Value, 'origin_host_header', _('Origin Host Header'),
			_('Optional. Host header sent to the origin.'));
		o.placeholder = '192.168.1.1';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', HTTP_RE);

		o = s.option(form.Flag, 'no_tls_verify', _('Skip Origin TLS Verify'),
			_('Enable for HTTPS origins with self-signed certificates.'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('_protocol', TLS_RE);

		o = s.option(form.Value, 'origin_server_name', _('Origin TLS Server Name'),
			_('Optional. Override the TLS server name used for HTTPS origins.'));
		o.placeholder = 'origin.example.com';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TLS_RE);

		o = s.option(form.Value, 'ingress_path', _('Ingress Path'),
			_('Optional. URL path prefix for HTTP/HTTPS ingress rules.'));
		o.placeholder = '/';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', HTTP_RE);

		o = s.option(form.Value, 'origin_connect_timeout', _('Connect Timeout'),
			_('Origin connection timeout, e.g. 30s.'));
		o.placeholder = '30s';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', CONNECT_RE);

		o = s.option(form.Value, 'origin_tls_timeout', _('TLS Timeout'),
			_('Origin TLS handshake timeout, e.g. 10s.'));
		o.placeholder = '10s';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TLS_RE);

		o = s.option(form.Value, 'origin_tcp_keepalive', _('TCP KeepAlive'),
			_('Origin TCP keepalive interval, e.g. 30s.'));
		o.placeholder = '30s';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TCP_RE);

		o = s.option(form.Flag, 'origin_no_happy_eyeballs', _('Disable Happy Eyeballs'),
			_('Disable parallel IPv4/IPv6 connection attempts.'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('_protocol', TCP_RE);

		o = s.option(form.Value, 'origin_proxy_address', _('Proxy Address'),
			_('Optional SOCKS/HTTP proxy address for the origin connection.'));
		o.placeholder = '127.0.0.1';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TCP_RE);

		o = s.option(form.Value, 'origin_proxy_port', _('Proxy Port'), _('Optional proxy port.'));
		o.placeholder = '1080';
		o.datatype = 'port';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TCP_RE);

		o = s.option(form.ListValue, 'origin_proxy_type', _('Proxy Type'), _('Optional origin proxy protocol.'));
		o.value('socks5', 'SOCKS5');
		o.value('http', 'HTTP');
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TCP_RE);

		o = s.option(form.Flag, 'origin_http2', _('HTTP/2 Origin'),
			_('Use HTTP/2 when connecting to the origin.'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('_protocol', HTTP_RE);

		o = s.option(form.Flag, 'origin_disable_chunked', _('Disable Chunked Encoding'),
			_('Disable chunked transfer encoding for HTTP origins.'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('_protocol', HTTP_RE);

		o = s.option(form.Value, 'origin_keepalive_connections', _('KeepAlive Connections'),
			_('Number of keepalive connections to the origin.'));
		o.placeholder = '100';
		o.datatype = 'uinteger';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', HTTP_RE);

		o = s.option(form.Value, 'origin_keepalive_timeout', _('KeepAlive Timeout'),
			_('Keepalive timeout for HTTP origins, e.g. 90s.'));
		o.placeholder = '90s';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', HTTP_RE);

		o = s.option(form.Value, 'origin_ca_pool', _('CA Pool'),
			_('Optional CA bundle path used to verify HTTPS origins.'));
		o.placeholder = '/etc/ssl/certs/ca-certificates.crt';
		o.modalonly = true;
		o.rmempty = true;
		o.depends('_protocol', TLS_RE);

		o = s.option(form.Flag, 'origin_bastion_mode', _('Bastion Mode'),
			_('Enable bastion mode for SSH origins.'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('_protocol', /^ssh$/);

		/* Column proportions: the tunnel gets room for long names, the IP and
		   port fields stay compact. */
		const widths = {
			tunnel: '16%',
			hostname: '15%',
			_protocol: '130px',
			_ip: '165px',
			_port: '90px',
			_service: '8%',
			_dns: '5%',
			enabled: '3%',
			_test: '10%'
		};
		s.children.forEach(function(opt) {
			if (widths[opt.option])
				opt.width = widths[opt.option];
		});

		/* Keep hidden protocol fields when switching protocols instead of
		   deleting the stored values. */
		s.children.forEach(function(opt) {
			if (opt.deps && opt.deps.length)
				opt.retain = true;
		});

		return map.render().then(function(node) {
			document.head.appendChild(E('link', {
				'rel': 'stylesheet',
				'href': L.resource('view/cloudflared/cloudflared.css')
			}));

			const COLUMNS = [
				[ 'tunnel', _('Tunnel'), true ],
				[ 'hostname', _('Hostname'), true ],
				[ '_protocol', _('Protocol'), true ],
				[ '_ip', _('IP / Host'), true ],
				[ '_port', _('Port'), true ],
				[ '_service', _('Service'), false ],
				[ '_dns', _('DNS'), true ],
				[ 'enabled', _('Enable'), true ],
				[ '_test', _('Check'), true ]
			];
			const COLUMN_KEY = 'cf-ingress-columns-js-v2';

			function savedColumns() {
				try {
					const saved = JSON.parse(localStorage.getItem(COLUMN_KEY));
					return (saved && typeof(saved) === 'object') ? saved : {};
				}
				catch (e) {
					return {};
				}
			}

			function columnDefault(name) {
				for (let i = 0; i < COLUMNS.length; i++)
					if (COLUMNS[i][0] === name)
						return COLUMNS[i][2] !== false;
				return true;
			}

			function isColumnVisible(name) {
				const saved = savedColumns();
				return saved.hasOwnProperty(name) ? !!saved[name] : columnDefault(name);
			}

			function setColumnVisible(name, visible) {
				const saved = savedColumns();
				saved[name] = !!visible;
				try { localStorage.setItem(COLUMN_KEY, JSON.stringify(saved)); } catch (e) {}
				applyColumns();
				setupSelectAll();
			}

			function tableElement() {
				return node.querySelector('.cbi-section-table') ||
					document.querySelector('#cbi-cloudflared-ingress .cbi-section-table');
			}

			function columnIndexes(table) {
				const mapIdx = {};
				const dataRow = table.querySelector('tr.cbi-section-table-row');
				if (!dataRow)
					return mapIdx;

				Array.prototype.forEach.call(dataRow.children, function(cell, idx) {
					const name = cell.getAttribute('data-name');
					if (name)
						mapIdx[name] = idx;
				});

				return mapIdx;
			}

			function applyColumns() {
				const table = tableElement();
				if (!table)
					return;

				const mapIdx = columnIndexes(table);
				const rows = table.querySelectorAll('tr');

				Array.prototype.forEach.call(rows, function(row) {
					const cells = Array.prototype.filter.call(row.children, function(cell) {
						return cell.classList.contains('td') || cell.classList.contains('th');
					});

					COLUMNS.forEach(function(def) {
						const idx = mapIdx[def[0]];
						if (idx == null)
							return;

						const cell = cells[idx];
						if (cell)
							cell.style.display = isColumnVisible(def[0]) ? '' : 'none';
					});
				});
			}

			function selectedIngressSections(requireHostname) {
				const targets = [];

				dataRows().filter(function(row) {
					return row.style.display !== 'none';
				}).forEach(function(row) {
					const sel = row.querySelector('[data-name="_select"] input[type="checkbox"]');
					if (!sel || !sel.checked || sel.disabled)
						return;

					if (requireHostname && !rowHostname(row))
						return;

					const section = row.getAttribute('data-sid') ||
						row.getAttribute('data-section-id') || '';
					if (section)
						targets.push(section);
				});

				return targets;
			}

			function updateDnsCell(section, r) {
				const cell = document.getElementById('cf-dns-' + section);
				if (!cell)
					return;

				if (r && (r.created_count || r.exists_count))
					dom.content(cell, [ dnsText('synced') ]);
				else if (r && r.disabled)
					dom.content(cell, [ dnsText('disabled') ]);
				else
					dom.content(cell, [ dnsText('pending') ]);
			}

			function runLimited(targets, worker, limit) {
				return new Promise(function(resolve) {
					let index = 0;
					let active = 0;

					function startNext() {
						while (active < limit && index < targets.length) {
							const target = targets[index++];
							active++;

							Promise.resolve()
								.then(function() { return worker(target); })
								.then(done, done);
						}

						if (active === 0 && index >= targets.length)
							resolve();
					}

					function done() {
						active--;
						startNext();
					}

					startNext();
				});
			}

			function syncSelectedDns(button) {
				const targets = selectedIngressSections(true);
				if (!targets.length) {
					ui.addNotification(null, E('p', {}, [ _('No selected sites to sync.') ]), 'warning');
					return;
				}

				setBusyButton(button, true);
				const results = [];

				runLimited(targets, function(section) {
					return cfApi.action('dns_sync', { ingress: section }).then(function(r) {
						results.push(r);
						updateDnsCell(section, r);
					}, function(err) {
						results.push({ ok: false, message: String(err) });
					});
				}, PARALLEL_LIMIT).then(function() {
					setBusyButton(button, false);
					showDnsSummary(results, _('DNS sync result'));
				});
			}

			function checkAllIngress(button) {
				const targets = selectedIngressSections(true);

				if (!targets.length) {
					ui.addNotification(null, E('p', {}, [ _('No selected sites to check.') ]), 'warning');
					return;
				}

				setBusyButton(button, true);
				runLimited(targets, function(section) {
					return runIngressTest(section, document.getElementById('cf-test-' + section));
				}, PARALLEL_LIMIT).then(function() {
					setBusyButton(button, false);
				});
			}

			function deleteSelectedIngress(button) {
				const targets = selectedIngressSections(false);
				if (!targets.length) {
					ui.addNotification(null, E('p', {}, [ _('No selected sites to delete.') ]), 'warning');
					return;
				}

				openDeleteSelectedIngress(targets, button);
			}

			updateSelectAll = function() {
				const all = document.getElementById('cf-select-all-ingress');
				if (!all)
					return;

				let total = 0;
				let checked = 0;

				dataRows().filter(function(row) {
					return row.style.display !== 'none';
				}).forEach(function(row) {
					const cb = row.querySelector('[data-name="_select"] input[type="checkbox"]');
					if (!cb || cb.disabled)
						return;
					total++;
					if (cb.checked)
						checked++;
				});

				all.checked = total > 0 && checked === total;
				all.indeterminate = checked > 0 && checked < total;
			};

			function bindSelectAll() {
				const all = document.getElementById('cf-select-all-ingress');
				if (!all || all._cfBound)
					return;

				all._cfBound = true;
				all.addEventListener('click', function(ev) { ev.stopPropagation(); });
				all.addEventListener('change', function(ev) {
					ev.stopPropagation();
					const want = all.checked;

					dataRows().filter(function(row) {
						return row.style.display !== 'none';
					}).forEach(function(row) {
						const rowCb = row.querySelector('[data-name="_select"] input[type="checkbox"]');
						if (!rowCb || rowCb.disabled)
							return;
						rowCb.checked = want;
						selected[row.id.substring('cbi-cloudflared-'.length)] = want;
					});

					updateSelectAll();
				});
			}

			function setupSelectAll() {
				bindSelectAll();
				updateSelectAll();
			}

			function setupColumns() {
				const table = tableElement();
				if (!table)
					return;

				const section = table.closest('.cbi-section') || table.parentNode;
				let bar = section.querySelector('.cf-columns-toolbar');

				if (!bar) {
					const menu = E('div', { 'class': 'cf-columns-menu', 'style': 'display:none' });

					COLUMNS.forEach(function(def) {
						const cb = E('input', {
							'type': 'checkbox',
							'data-column': def[0],
							'checked': isColumnVisible(def[0]) ? '' : null
						});
						cb.addEventListener('change', function() {
							setColumnVisible(def[0], cb.checked);
						});

						menu.appendChild(E('label', { 'class': 'cf-columns-item' }, [ cb, E('span', {}, [ def[1] ]) ]));
					});

					const reset = E('button', {
						'type': 'button',
						'class': 'btn cbi-button cf-columns-reset',
						'click': function(ev) {
							ev.stopPropagation();
							try { localStorage.removeItem(COLUMN_KEY); } catch (e) {}
							menu.querySelectorAll('input[type="checkbox"]').forEach(function(cb) {
								cb.checked = columnDefault(cb.getAttribute('data-column'));
							});
							applyColumns();
						}
					}, [ _('Reset') ]);
					menu.appendChild(reset);

					const dnsAll = E('button', {
						'type': 'button',
						'class': 'btn cbi-button',
						'click': function(ev) {
							ev.stopPropagation();
							syncSelectedDns(ev.currentTarget);
						}
					}, [ _('Sync Selected DNS') ]);

				const checkAll = E('button', {
						'type': 'button',
						'class': 'btn cbi-button',
						'click': function(ev) {
							ev.stopPropagation();
							checkAllIngress(ev.currentTarget);
						}
				}, [ _('Check All') ]);

				const deleteAll = E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-negative',
					'click': function(ev) {
						ev.stopPropagation();
						deleteSelectedIngress(ev.currentTarget);
					}
				}, [ _('Delete Selected') ]);

					const btn = E('button', { 'type': 'button', 'class': 'btn cbi-button', 'click': function(ev) {
						ev.stopPropagation();
						menu.style.display = (menu.style.display === 'none' || menu.style.display === '') ? 'block' : 'none';
					} }, [ _('Columns') ]);

				bar = E('div', { 'class': 'cf-columns-toolbar' }, [ dnsAll, checkAll, deleteAll, btn, menu ]);
					menu.addEventListener('click', function(ev) { ev.stopPropagation(); });
					document.addEventListener('click', function() { menu.style.display = 'none'; });

					if (table.parentNode)
						table.parentNode.insertBefore(bar, table);
				}

				applyColumns();
				setupSelectAll();
			}

			const tableState = view._ingressTableState ||
				(view._ingressTableState = { page: 1, size: 20, tunnel: '', hostname: '' });

			function tunnelLabels() {
				const labels = {};
				(uci.sections('cloudflared', 'tunnel') || []).forEach(function(sec) {
					labels[sec['.name']] = sec.name || sec['.name'];
				});
				return labels;
			}

			function dataRows() {
				return Array.prototype.slice.call(
					node.querySelectorAll('tr.cbi-section-table-row')).filter(function(row) {
						return !row.classList.contains('placeholder');
					});
			}

			function rowTunnel(row) {
				const cell = row.querySelector('[data-name="tunnel"]');
				if (!cell)
					return '';

				const hidden = cell.querySelector('.cbi-dropdown input[type="hidden"]');
				if (hidden)
					return hidden.value || '';

				const select = cell.querySelector('select');
				if (select)
					return select.value || '';

				const selected = cell.querySelector('.cbi-dropdown li[selected]');
				if (selected)
					return selected.getAttribute('data-value') || '';

				const input = cell.querySelector('input');
				return input ? (input.value || '') : '';
			}

			function rowHostname(row) {
				const input = row.querySelector('[data-name="hostname"] input');
				return input ? (input.value || '') : '';
			}

			function rowMatches(row, labels) {
				const tunnel = rowTunnel(row);
				const hostname = rowHostname(row);
				const label = labels[tunnel] || tunnel;

				if (tableState.tunnel && tunnel !== tableState.tunnel)
					return false;

				if (tableState.hostname) {
					const needle = tableState.hostname.toLowerCase();
					if (hostname.toLowerCase().indexOf(needle) === -1)
						return false;
				}

				return true;
			}

			function applyTablePage(tools) {
				const rows = dataRows();
				const labels = tunnelLabels();
				const matched = rows.filter(function(row) { return rowMatches(row, labels); });
				const pages = Math.max(1, Math.ceil(matched.length / tableState.size));

				if (tableState.page > pages)
					tableState.page = pages;
				if (tableState.page < 1)
					tableState.page = 1;

				const start = (tableState.page - 1) * tableState.size;

				rows.forEach(function(row) { row.style.display = 'none'; });
				matched.forEach(function(row, idx) {
					row.style.display = (idx >= start && idx < start + tableState.size) ? '' : 'none';
				});

				const info = tools.querySelector('.cf-page-info');
				if (info)
					info.textContent = _('Page %s / %s').format(tableState.page, pages) +
						' · ' + _('%s rows').format(matched.length);

				tools.querySelectorAll('[data-page-action]').forEach(function(btn) {
					const action = btn.getAttribute('data-page-action');
					btn.disabled = ((action === 'first' || action === 'prev') && tableState.page <= 1) ||
						((action === 'last' || action === 'next') && tableState.page >= pages);
				});

				tools._cfPages = pages;
			}

			function setupIngressTools() {
				const table = tableElement();
				if (!table)
					return;

				const section = table.closest('.cbi-section') || table.parentNode;
				const labels = tunnelLabels();

				if (tableState.tunnel && !labels.hasOwnProperty(tableState.tunnel)) {
					for (const key in labels) {
						if (labels[key] === tableState.tunnel) {
							tableState.tunnel = key;
							break;
						}
					}
				}

				let bar = section.querySelector('.cf-table-filters-row');
				let tunnelSel, hostInput;

				if (!bar) {
					tunnelSel = E('select', { 'class': 'cbi-input-select cf-filter-tunnel' });
					hostInput = E('input', {
						'type': 'text',
						'class': 'cbi-input-text cf-filter-hostname',
						'placeholder': _('Filter by hostname')
					});

					const right = E('div', { 'class': 'cf-table-filters-right' });
					bar = E('div', { 'class': 'cf-table-filters-row' }, [
						E('div', { 'class': 'cf-table-filters' }, [ tunnelSel, hostInput ]),
						right
					]);

					let filterTimer = null;
					function scheduleFilter() {
						if (filterTimer)
							clearTimeout(filterTimer);
						filterTimer = setTimeout(function() {
							tableState.tunnel = tunnelSel.value;
							tableState.hostname = hostInput.value.replace(/^\s+|\s+$/g, '');
							tableState.page = 1;
							applyTablePage(section.querySelector('.cf-table-pager-bar'));
						}, 120);
					}

					tunnelSel.addEventListener('change', scheduleFilter);
					hostInput.addEventListener('input', scheduleFilter);

					if (table.parentNode)
						table.parentNode.insertBefore(bar, table);
				}
				else {
					tunnelSel = bar.querySelector('.cf-filter-tunnel');
					hostInput = bar.querySelector('.cf-filter-hostname');
				}

				/* Rebuild the tunnel dictionary only when it actually changed,
				   otherwise the mutation observer would rebuild it forever. */
				const sig = Object.keys(labels).map(function(key) {
					return key + ':' + labels[key];
				}).join('|');

				if (tunnelSel._cfSig !== sig) {
					tunnelSel._cfSig = sig;

					while (tunnelSel.firstChild)
						tunnelSel.removeChild(tunnelSel.firstChild);

					tunnelSel.appendChild(E('option', { 'value': '' }, [ _('All') ]));
					for (const key in labels)
						tunnelSel.appendChild(E('option', { 'value': key }, [ labels[key] ]));
				}

				tunnelSel.value = tableState.tunnel || '';

				if (hostInput !== document.activeElement)
					hostInput.value = tableState.hostname || '';

				/* Keep the column chooser on the right side of the filter row. */
				if (!tunnelSel._cfBound) {
					tunnelSel._cfBound = true;
				}

				const columnsBar = section.querySelector('.cf-columns-toolbar');
				const right = bar.querySelector('.cf-table-filters-right');
				if (columnsBar && right && columnsBar.parentNode !== right)
					right.appendChild(columnsBar);

				let pagerBar = section.querySelector('.cf-table-pager-bar');

				if (!pagerBar) {
					pagerBar = E('div', { 'class': 'cf-table-pager-bar' });

					const sizeSel = E('select', { 'class': 'cbi-input-select' }, [
						[ 10, '10' ], [ 20, '20' ], [ 30, '30' ], [ 50, '50' ], [ 100, '100' ]
					].map(function(item) {
						return E('option', {
							'value': String(item[0]),
							'selected': item[0] === tableState.size ? '' : null
						}, [ item[1] ]);
					}));

					sizeSel.value = String(tableState.size);

					const info = E('span', { 'class': 'cf-page-info' });
					const pager = E('div', { 'class': 'cf-table-pager' }, [
						E('label', { 'class': 'cf-page-size' }, [ _('Rows per page'), ' ', sizeSel ]),
						E('button', { 'type': 'button', 'class': 'btn cbi-button cf-pager-btn', 'data-page-action': 'first', 'title': _('First page') }, [ '«' ]),
						E('button', { 'type': 'button', 'class': 'btn cbi-button cf-pager-btn', 'data-page-action': 'prev', 'title': _('Previous page') }, [ '‹' ]),
						info,
						E('button', { 'type': 'button', 'class': 'btn cbi-button cf-pager-btn', 'data-page-action': 'next', 'title': _('Next page') }, [ '›' ]),
						E('button', { 'type': 'button', 'class': 'btn cbi-button cf-pager-btn', 'data-page-action': 'last', 'title': _('Last page') }, [ '»' ])
					]);

					sizeSel.addEventListener('change', function() {
						tableState.size = parseInt(sizeSel.value, 10) || 20;
						tableState.page = 1;
						applyTablePage(pagerBar);
					});

					pager.addEventListener('click', function(ev) {
						const btn = ev.target.closest ? ev.target.closest('[data-page-action]') : null;
						if (!btn || btn.disabled)
							return;

						const pages = pagerBar._cfPages || 1;
						const action = btn.getAttribute('data-page-action');

						if (action === 'first') tableState.page = 1;
						else if (action === 'prev') tableState.page = Math.max(1, tableState.page - 1);
						else if (action === 'next') tableState.page = Math.min(pages, tableState.page + 1);
						else if (action === 'last') tableState.page = pages;

						applyTablePage(pagerBar);
					});

					pagerBar.appendChild(pager);

					const create = section.querySelector('.cbi-section-create');
					if (create && create.parentNode)
						create.parentNode.insertBefore(pagerBar, create.nextSibling);
					else if (table.parentNode)
						table.parentNode.insertBefore(pagerBar, table.nextSibling);
				}

				applyTablePage(pagerBar);
				setupSelectAll();
			}

			view._confirmOrphans = function() {
				return cfApi.action('ingress_dns', {}).then(function(r) {
					if (!r || !r.ok || !r.allow_delete || !r.orphaned || !r.orphaned.length)
						return true;

					return new Promise(function(resolve) {
						ui.showModal(_('Orphaned DNS (will be deleted on save)'), [
							E('p', {}, [ r.orphaned.join(', ') ]),
							E('div', { 'class': 'right' }, [
								E('button', {
									'class': 'btn cbi-button',
									'click': function() {
										ui.hideModal();
										resolve(false);
									}
								}, [ _('Cancel') ]),
								E('button', {
									'class': 'btn cbi-button cbi-button-negative',
									'click': function() {
										ui.hideModal();
										resolve(true);
									}
								}, [ _('Continue') ])
							])
						]);
					});
				});
			};

			view._syncEnabledTunnelDns = function() {
				const tunnels = (uci.sections('cloudflared', 'tunnel') || [])
					.map(function(tunnel) { return tunnel['.name']; });

				return tunnels.reduce(function(chain, section) {
					return chain.then(function(results) {
						return cfApi.action('dns_sync', { section: section }).then(function(r) {
							results.push(r);
							return results;
						}, function(err) {
							results.push({ ok: false, message: String(err) });
							return results;
						});
					});
				}, Promise.resolve([]));
			};

			view._setupColumns = setupColumns;
			view._setupIngressTools = setupIngressTools;
			setupColumns();
			setupIngressTools();

			let columnTimer = null;
			if (window.MutationObserver) {
				new MutationObserver(function() {
					if (columnTimer)
						clearTimeout(columnTimer);
					columnTimer = setTimeout(function() {
						setupColumns();
						setupIngressTools();
					}, 30);
				}).observe(node, { childList: true, subtree: true });
			}

			let warnedOrphans = false;
			let warnedErrors = false;

			function loadDns() {
				cfApi.action('ingress_dns', {}).then(function(r) {
					document.querySelectorAll('[id^="cf-dns-"]').forEach(function(el) {
						const section = el.id.substring('cf-dns-'.length);
						const state = (r && r.ok && r.status) ? r.status[section] : null;
						dom.content(el, [ dnsText(state) ]);
					});

					if (!warnedOrphans && r && r.ok && r.allow_delete && r.orphaned && r.orphaned.length) {
						warnedOrphans = true;
						ui.addNotification(null, E('p', {}, [
							_('Orphaned DNS (will be deleted on save)') + ': ' + r.orphaned.join(', ')
						]), 'warning');
					}

					if (!warnedErrors && r && r.ok && r.errors) {
						const lines = [];

						for (const section in r.errors) {
							const err = r.errors[section] || {};
							const name = err.name || section;

							if (err.code === 'missing_token')
								lines.push(_('DNS status unavailable for %s: no API token configured.').format(name));
							else if (err.code === 'missing_config')
								lines.push(_('DNS status unavailable for %s: tunnel ID or domain is missing.').format(name));
							else if (err.code === 'zone_failed')
								lines.push(_('DNS status unavailable for %s: the API token cannot read zone %s. Grant Zone:Zone:Read and Zone:DNS:Read.').format(name, err.domain || ''));
							else
								lines.push(_('DNS status unavailable for %s: Cloudflare API request failed.').format(name));
						}

						if (lines.length) {
							warnedErrors = true;
							ui.addNotification(null, E('ul', {}, lines.map(function(line) {
								return E('li', {}, [ line ]);
							})), 'warning');
						}
					}
				});
			}

			loadDns();
			poll.add(function() {
				if (document.visibilityState === 'hidden')
					return;
				loadDns();
			}, 10);

			node.addEventListener('click', function(ev) {
				const btn = ev.target.closest ? ev.target.closest('.cbi-button-remove') : null;
				if (!btn)
					return;

				const row = btn.closest('tr');
				const section_id = row
					? (row.getAttribute('data-sid') || row.getAttribute('data-section-id'))
					: null;
				const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;

				// Unsaved rows only exist in the form state; let LuCI remove them.
				if (!section_id || (creates && creates[section_id]))
					return;

				ev.preventDefault();
				ev.stopImmediatePropagation();
				openDeleteIngress(section_id);
			}, true);

			cfResult.consume(node, 'cf-ingress-delete-result');
			return node;
		});
	},

	handleSave: function(ev) {
		const self = this;

		return this.super('handleSave', [ ev ]).then(function() {
			if (typeof(self._setupColumns) === 'function')
				self._setupColumns();
			if (typeof(self._setupIngressTools) === 'function')
				self._setupIngressTools();
		});
	},

	handleSaveApply: function(ev) {
		const self = this;

		return self.handleSave(ev).then(function() {
			return (typeof(self._confirmOrphans) === 'function')
				? self._confirmOrphans()
				: true;
		}).then(function(ok) {
			if (!ok)
				return null;

			return cfApi.action('apply_config', {}).then(function(r) {
				if (!r || !r.ok)
					return r;
				return (typeof(self._syncEnabledTunnelDns) === 'function')
					? self._syncEnabledTunnelDns().then(function(syncResults) {
						r.dns_sync_results = syncResults;
						return r;
					})
					: r;
			});
		}).then(function(r) {
			if (r === null)
				return;

			if (!r || !r.ok) {
				ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
				return;
			}
			ui.addNotification(null, E('p', {}, [ _('Changes applied.') ]), 'info');
			return new Promise(function(resolve) {
				setTimeout(function() { location.reload(); }, 900);
				resolve();
			});
		});
	}
});

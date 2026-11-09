'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require cloudflared.api as cfApi';

function siblingValue(sectionObj, section_id, name) {
	for (let i = 0; i < sectionObj.children.length; i++) {
		if (sectionObj.children[i].option === name)
			return sectionObj.children[i].formvalue(section_id);
	}
	return '';
}

function showResult(title, text) {
	ui.showModal(title, [
		E('p', {}, [ text ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Dismiss') ])
		])
	]);
}

function failResult(title, r) {
	showResult(title, cfApi.message(r));
}

function quickError(r) {
	ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
}

function pickFile(accept) {
	return new Promise(function(resolve) {
		const input = E('input', { 'type': 'file', 'accept': accept || null, 'style': 'display:none' });
		input.addEventListener('change', function() {
			resolve(input.files && input.files.length ? input.files[0] : null);
			input.remove();
		});
		document.body.appendChild(input);
		input.click();
	});
}

function loginFlow(section_id, force) {
	let timer = null;
	let closed = false;
	let tries = 0;
	let sawUrl = false;

	const linkBox = E('div', { 'class': 'cf-login-box' });
	const stateEl = E('p', {}, [ _('Waiting for authorization...') ]);

	function stop() {
		closed = true;
		if (timer) {
			clearInterval(timer);
			timer = null;
		}
	}

	function dismiss() {
		stop();
		ui.hideModal();
	}

	function reauthorize() {
		stop();
		ui.hideModal();
		loginFlow(section_id, '1');
	}

	function update(st) {
		if (closed)
			return;

		if (st && st.url) {
			sawUrl = true;

			if (!linkBox.firstChild)
				linkBox.appendChild(E('a', { 'href': st.url, 'target': '_blank', 'rel': 'noopener' }, [ st.url ]));
		}

		stateEl.textContent = (st && st.message) ? st.message : _('Waiting for authorization...');

		if (st && st.state === 'done') {
			stop();

			if (!sawUrl) {
				stateEl.textContent = _('Already authorized, cert.pem exists.');
				return;
			}

			ui.hideModal();
			location.reload();
		}
		else if (st && st.state === 'failed') {
			stop();
			ui.hideModal();
			showResult(_('Authorize Tunnel'), st.message || _('Request failed'));
		}
	}

	ui.showModal(_('Authorize Tunnel'), [
		E('p', {}, [ _('Open this URL to authorize the tunnel:') ]),
		E('p', { 'class': 'cf-note' }, [ _('If the browser cannot reach this router, download cert.pem from Cloudflare and upload it instead.') ]),
		linkBox,
		stateEl,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': dismiss }, [ _('Dismiss') ]),
			E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': reauthorize }, [ _('Re-authorize') ])
		])
	]);

	cfApi.action('login_start', {
		section: section_id,
		force: force ? '1' : '0'
	}).then(function(r) {
		if (!r || !r.ok) {
			stop();
			ui.hideModal();
			showResult(_('Authorize Tunnel'), cfApi.message(r));
			return;
		}

		update(r);

		if (closed || r.state === 'done')
			return;

		timer = setInterval(function() {
			if (++tries > 120) {
				stop();
				return;
			}
			cfApi.action('login_status', { section: section_id }).then(update);
		}, 2500);
	});
}

return view.extend({
	load: function() {
		const view = this;

		return Promise.all([
			uci.load('cloudflared'),
			cfApi.action('tunnel_status', {})
		]).then(function(res) {
			view._tunnelStatus = (res[1] && res[1].status) || {};
		});
	},

	render: function() {
		const view = this;
		const map = new form.Map('cloudflared', _('Cloudflared Tunnels'),
			_('Each tunnel has its own domain, credentials and config.yml.') + ' ' + _('Save only stores changes; Save & Apply rebuilds config and restarts the service.'));

		const s = map.section(form.GridSection, 'tunnel', _('Tunnels'));
		s.anonymous = true;
		s.addremove = true;

		let o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = 'office';
		o.editable = true;

		o = s.option(form.Value, 'domain', _('Domain'),
			_('Root domain of this tunnel, e.g. example.com.'));
		o.placeholder = 'example.com';
		o.datatype = 'hostname';
		o.editable = true;

		o = s.option(form.Value, 'tunnel_id', _('Tunnel ID'),
			_('Cloudflare tunnel UUID. Must be unique.'));
		o.placeholder = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
		o.editable = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			let duplicate = false;
			uci.sections('cloudflared', 'tunnel', function(sec) {
				if (sec['.name'] !== section_id && sec.tunnel_id === value)
					duplicate = true;
			});

			return duplicate ? _('Tunnel ID already used by another tunnel') : true;
		};

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.DummyValue, '_state', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const st = view._tunnelStatus ? view._tunnelStatus[section_id] : null;

			if (!st)
				return E('span', {}, [ '—' ]);

			const state = st.state;

			if (state === 'running')
				return E('span', { 'class': 'cf-site-running' }, [ '● ' + _('Running') ]);
			if (state === 'pending')
				return E('span', { 'class': 'cf-site-pending' }, [ '● ' + _('Pending hot reload') ]);
			if (state === 'disabled')
				return E('span', { 'class': 'cf-site-disabled' }, [ '● ' + _('Inactive') ]);

			return E('span', { 'class': 'cf-site-abnormal' }, [ '● ' + _('Abnormal') ]);
		};

		o = s.option(form.DummyValue, '_quick', _('Actions'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const saved = uci.get('cloudflared', section_id, 'domain') || '';
			const row = document.getElementById('cbi-cloudflared-' + section_id);
			const input = row ? row.querySelector('[data-name="domain"] input') : null;
			const domain = (input && input.value) ? input.value : saved;

			return E('div', { 'class': 'cf-actions' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button',
					'click': function(ev) {
						ev.preventDefault();
						const btn = ev.currentTarget;
						btn.disabled = true;
						cfApi.action('dns_sync', { section: section_id }).then(function(r) {
							btn.disabled = false;
							if (!r || !r.ok)
								quickError(r);
							else
								ui.addNotification(null, E('p', {}, [ _('DNS sync completed.') ]), 'info');
						});
					}
				}, [ _('Sync DNS') ]),
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-apply',
					'click': function(ev) {
						ev.preventDefault();
						const btn = ev.currentTarget;

						if (!domain) {
							ui.addNotification(null, E('p', {}, [ _('Please enter a domain first') ]), 'warning');
							return;
						}
						if (!confirm(_('Switch domain and hot reload')))
							return;

						btn.disabled = true;
						cfApi.action('domain_switch', {
							section: section_id,
							new_domain: domain,
							rewrite_hosts: '1',
							sync_dns: '1',
							restart: '1'
						}).then(function(r) {
							btn.disabled = false;
							if (!r || !r.ok)
								quickError(r);
							else
								location.reload();
						});
					}
				}, [ _('Hot Reload') ])
			]);
		};

		o = s.option(form.Value, 'data_dir', _('Data Directory'),
			_('Leave empty to use &lt;base_path&gt;/tunnels/&lt;section&gt;.'));
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.Value, 'cert_path', _('Certificate Path'),
			_('Leave empty to use the default cert.pem.'));
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.Value, 'credentials_file', _('Credentials File'),
			_('Leave empty to auto-detect &lt;tunnel_id&gt;.json in the data directory.'));
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.Value, 'api_token', _('API Token Override'),
			_('Optional. Required only when this tunnel belongs to another Cloudflare account.'));
		o.password = true;
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.DummyValue, '_applied', _('Domain Status'));
		o.modalonly = true;
		o.textvalue = function(section_id) {
			const domain = uci.get('cloudflared', section_id, 'domain') || '';
			const applied = uci.get('cloudflared', section_id, 'applied_domain') || domain;

			if (!domain)
				return E('span', { 'style': 'color:var(--text-subtle, var(--v-text-3, #8a9099))' }, [ '—' ]);

			if (domain === applied)
				return E('span', {}, [
					E('span', { 'class': 'cf-site-running' }, [ '● ' + _('Applied') ]),
					' (' + applied + ')'
				]);

			return E('span', {}, [
				E('span', { 'class': 'cf-site-pending' }, [ '● ' + _('Pending hot reload') ]),
				' (' + applied + ' → ' + domain + ')'
			]);
		};

		o = s.option(form.Button, '_authorize', _('Authorize'));
		o.inputstyle = 'action';
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			loginFlow(section_id, '0');
		};

		o = s.option(form.Button, '_create', _('Create Tunnel'));
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			if (!uci.get('cloudflared', section_id)) {
				showResult(_('Create Tunnel'), _('Save this tunnel first, then create it.'));
				return;
			}

			const name = siblingValue(this.section, section_id, 'name');
			const existingId = uci.get('cloudflared', section_id, 'tunnel_id') || '';

			if (existingId && !confirm(_('This tunnel already has an ID. Creating a new tunnel will replace it. Continue?')))
				return;

			if (!confirm(_('Create a Cloudflare tunnel for this entry?')))
				return;

			cfApi.action('tunnel_create', {
				section: section_id,
				name: name,
				force: existingId ? '1' : '0'
			}).then(function(r) {
				if (!r || !r.ok)
					failResult(_('Create Tunnel'), r);
				else
					setTimeout(function() { location.reload(); }, 800);
			});
		};

		o = s.option(form.Button, '_dns', _('Sync DNS'));
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			cfApi.action('dns_sync', { section: section_id }).then(function(r) {
				if (!r || !r.ok)
					failResult(_('Sync DNS'), r);
				else {
					ui.hideModal();
					ui.addNotification(null, E('p', {}, [ _('DNS sync completed.') ]), 'info');
				}
			});
		};

		o = s.option(form.Button, '_reload', _('Hot Reload'));
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			const domain = siblingValue(this.section, section_id, 'domain');
			if (!domain) {
				ui.addNotification(null, E('p', {}, [ _('Please enter a domain first') ]), 'warning');
				return;
			}

			if (!confirm(_('Switch domain and hot reload')))
				return;

			cfApi.action('domain_switch', {
				section: section_id,
				new_domain: domain,
				rewrite_hosts: '1',
				sync_dns: '1',
				restart: '1'
			}).then(function(r) {
				if (!r || !r.ok)
					failResult(_('Hot Reload'), r);
				else
					setTimeout(function() { location.reload(); }, 900);
			});
		};

		o = s.option(form.Button, '_cert', _('Upload cert.pem'));
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			pickFile('.pem,.crt,.cer').then(function(file) {
				if (!file)
					return;

				cfApi.upload('upload_cert', section_id, file).then(function(r) {
					if (!r || !r.ok)
						failResult(_('Upload cert.pem'), r);
					else
						setTimeout(function() { location.reload(); }, 800);
				});
			});
		};

		o = s.option(form.Button, '_cred', _('Upload credentials.json'));
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			pickFile('.json,application/json').then(function(file) {
				if (!file)
					return;

				cfApi.upload('upload_credentials', section_id, file).then(function(r) {
					if (!r || !r.ok)
						failResult(_('Upload credentials.json'), r);
					else
						setTimeout(function() { location.reload(); }, 800);
				});
			});
		};

		return map.render().then(function(node) {
			document.head.appendChild(E('link', {
				'rel': 'stylesheet',
				'href': L.resource('view/cloudflared/cloudflared.css')
			}));

			node.addEventListener('click', function(ev) {
				const btn = ev.target.closest ? ev.target.closest('.cbi-button-remove') : null;
				if (btn && !confirm(_('Delete this tunnel?'))) {
					ev.preventDefault();
					ev.stopImmediatePropagation();
				}
			}, true);

			return node;
		});
	},

	handleSaveApply: function(ev) {
		return this.handleSave(ev).then(function() {
			return cfApi.action('apply_tunnels', {});
		}).then(function(r) {
			if (!r || !r.ok) {
				ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
				return;
			}
			ui.addNotification(null, E('p', {}, [ _('Changes applied.') ]), 'info');
			return new Promise(function(resolve) {
				setTimeout(function() { location.reload(); }, 700);
				resolve();
			});
		});
	}
});

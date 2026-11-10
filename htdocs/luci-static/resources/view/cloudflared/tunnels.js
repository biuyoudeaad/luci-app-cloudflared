'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require cloudflared.api as cfApi';
'require cloudflared.result as cfResult';

const activeLogins = {};

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

function requireSavedTunnel(section_id, title) {
	// uci.get() also returns in-memory sections created by uci.add(), so it
	// cannot distinguish a saved tunnel from an unsaved row in the modal.
	// Pending additions live in uci.state.creates until map.save() completes.
	const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;

	if (uci.get('cloudflared', section_id) && !(creates && creates[section_id]))
		return true;

	ui.addNotification(null, E('p', {}, [
		_('This tunnel is not saved yet. Click the page-level Save or Save & Apply button below the tunnel table first, then try again.')
	]), 'warning');
	return false;
}

function applyPendingChanges() {
	// LuCI "Save" writes to a per-session rpcd delta which the uci CLI used
	// by cloudflared-ctl cannot see. Commit it before any backend action.
	return uci.apply().then(function() {
		return true;
	}, function(err) {
		const msg = String((err && err.message) || err || '');
		if (/ubus code 5|no data/i.test(msg))
			return true;
		return false;
	});
}

function findModalSaveButton(ev) {
	const modal = (ev && ev.target && ev.target.closest ? ev.target.closest('.modal') : null)
		|| document.querySelector('#modal_overlay .modal')
		|| document.querySelector('#modal_overlay');

	if (!modal)
		return null;

	const buttons = modal.querySelectorAll('button');
	const saveText = _('Save');

	for (let i = 0; i < buttons.length; i++) {
		const btn = buttons[i];
		if (btn.classList.contains('cbi-button-positive') ||
		    btn.textContent.trim() === saveText)
			return btn;
	}

	return null;
}

function waitFor(predicate, interval, tries) {
	return new Promise(function(resolve) {
		let n = 0;

		(function check() {
			if (predicate()) {
				resolve(true);
				return;
			}
			if (++n >= tries) {
				resolve(false);
				return;
			}
			setTimeout(check, interval);
		})();
	});
}

function saveModalSection(sectionObj, section_id, ev) {
	const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;
	const pending = creates ? creates[section_id] : null;

	if (!pending)
		return Promise.resolve(section_id);

	// Prefer clicking the modal's own Save button. This works across LuCI
	// versions and themes and uses exactly the same path as a user save.
	const saveBtn = findModalSaveButton(ev);
	if (saveBtn) {
		saveBtn.click();

		return waitFor(function() {
			const still = uci.state && uci.state.creates && uci.state.creates.cloudflared;
			return !(still && still[section_id]);
		}, 100, 60).then(function(ok) {
			if (!ok)
				return null;

			// uci.save() updates the pending object with the server generated
			// section name before unloading the local UCI state.
			return (pending && pending['.name']) || section_id;
		});
	}

	// Fallback for older/custom modal layouts.
	if (typeof sectionObj.getActiveModalMap != 'function' ||
	    typeof sectionObj.handleModalSave != 'function')
		return Promise.resolve(null);

	const mapNode = sectionObj.getActiveModalMap();
	const modalMap = mapNode ? dom.findClassInstance(mapNode) : null;

	if (!modalMap)
		return Promise.resolve(null);

	return Promise.resolve(sectionObj.handleModalSave(modalMap, ev)).then(function() {
		const still = uci.state && uci.state.creates && uci.state.creates.cloudflared;
		if (still && still[section_id])
			return null;

		return (pending && pending['.name']) || section_id;
	});
}

function prepareSection(sectionObj, section_id, ev) {
	const creates = uci.state && uci.state.creates && uci.state.creates.cloudflared;
	const pending = creates ? creates[section_id] : null;
	const saved = pending ? saveModalSection(sectionObj, section_id, ev) : Promise.resolve(section_id);

	return saved.then(function(id) {
		if (!id) {
			ui.addNotification(null, E('p', {}, [
				_('Could not save this tunnel. Check the form values and try again.')
			]), 'danger');
			return null;
		}

		return applyPendingChanges().then(function(ok) {
			if (!ok) {
				ui.addNotification(null, E('p', {}, [
					_('Could not apply this tunnel. Please click Save & Apply on the page and try again.')
				]), 'danger');
				return null;
			}
			return id;
		});
	});
}

function dnsSummaryLine(r) {
	r = r || {};
	return _('Created: %s').format(r.created_count || 0) + ' · ' +
		_('Existing: %s').format(r.exists_count || 0) + ' · ' +
		_('Failed: %s').format(r.failed_count || 0);
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

function dnsBlock(title, list, messages) {
	if (!list || !list.length)
		return '';

	return E('div', { 'class': 'cf-dns-result-block' }, [
		E('strong', {}, [ title + ' (' + list.length + ')' ]),
		E('ul', {}, list.map(function(host) {
			const msg = messages ? dnsFailureMessage(messages[host]) : '';
			return E('li', {}, [
				E('code', {}, [ host ]),
				msg ? E('span', {}, [ ' — ' + msg ]) : ''
			]);
		}))
	]);
}

function dnsBlocks(r) {
	r = r || {};
	return [
		dnsBlock(_('Created'), r.created || []),
		dnsBlock(_('Existing'), r.exists || []),
		dnsBlock(_('Failed'), r.failed || [], r.failed_messages)
	];
}

function showDnsResult(r) {
	r = r || {};

	const children = [ E('p', {}, [ dnsSummaryLine(r) ]) ]
		.concat(dnsBlocks(r).filter(Boolean))
		.concat([
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Dismiss') ])
			])
		]);

	ui.showModal(_('DNS sync result'), children);
}

function migrateDomain(section_id, newDomain) {
	const current = uci.get('cloudflared', section_id, 'applied_domain') ||
		uci.get('cloudflared', section_id, 'domain') || '';
	const target = String(newDomain || '').replace(/^\s+|\s+$/g, '');

	if (!target) {
		showResult(_('Domain migration'), _('Please enter a domain first'));
		return;
	}

	if (!current) {
		showResult(_('Domain migration'), _('Current tunnel has no domain.'));
		return;
	}

	if (target === current) {
		showResult(_('Domain migration'), _('The new domain must differ from the current domain.'));
		return;
	}

	const tunnels = uci.sections('cloudflared', 'tunnel') || [];
	const single = (tunnels.length === 1) ? tunnels[0]['.name'] : '';
	const changed = [];
	const already = [];
	const unchanged = [];

	function underDomain(host, domain) {
		return host === domain ||
			(host.length > domain.length &&
			 host.substring(host.length - domain.length - 1) === '.' + domain);
	}

	(uci.sections('cloudflared', 'ingress') || []).forEach(function(rule) {
		const owner = rule.tunnel || single;
		if (owner !== section_id)
			return;
		if ((rule.enabled || '1') === '0')
			return;

		const host = rule.hostname || '';
		if (!host)
			return;

		if (underDomain(host, current)) {
			changed.push({
				from: host,
				to: (host === current)
					? target
					: host.substring(0, host.length - current.length) + target
			});
		}
		else if (underDomain(host, target)) {
			already.push(host);
		}
		else {
			unchanged.push(host);
		}
	});

	const rewrite = E('input', { 'type': 'checkbox', 'checked': '' });
	const sync = E('input', { 'type': 'checkbox', 'checked': '' });
	const restart = E('input', { 'type': 'checkbox', 'checked': '' });
	const migrateBtn = E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': function() {
			ui.hideModal();

			const opts = {
				rewrite: rewrite.checked,
				sync: sync.checked,
				restart: restart.checked
			};

			cfApi.action('domain_switch', {
				section: section_id,
				new_domain: target,
				rewrite_hosts: opts.rewrite ? '1' : '0',
				sync_dns: '0',
				restart: '0'
			}).then(function(r) {
				if (!r || !r.ok) {
					failResult(_('Domain migration'), r);
					return null;
				}

				if (!opts.sync)
					return r;

				return cfApi.action('dns_sync', { section: section_id }).then(function(dns) {
					r.dns = dns;
					return r;
				});
			}).then(function(r) {
				if (!r)
					return null;

				if (!opts.restart)
					return r;

				return cfApi.action('service', { op: 'restart' }).then(function(s) {
					r.restarted = !!(s && s.ok);
					if (!s || !s.ok)
						r.restart_message = cfApi.message(s);
					return r;
				});
			}).then(function(r) {
				if (!r)
					return;

				let parts = [
					E('p', {}, [ r.old + ' → ' + r.new ]),
					E('p', {}, [
						_('Rewritten %s rules').format(r.rewritten || 0)
					])
				];

				if (r.dns) {
					parts.push(E('p', {}, [ dnsSummaryLine(r.dns) ]));
					parts = parts.concat(dnsBlocks(r.dns).filter(Boolean));
				}

				if (r.restart_message)
					parts.push(E('p', { 'class': 'cf-note' }, [ r.restart_message ]));

				parts.push(E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': function() { location.reload(); }
					}, [ _('Dismiss') ])
				]));

				ui.showModal(_('Domain migration'), parts);
			});
		}
	}, [ _('Migrate') ]);

	const body = [
		E('p', {}, [ _('Old domain') + ': ' + current ]),
		E('p', {}, [ _('New domain') + ': ' + target ]),
		E('div', { 'class': 'cf-dns-result-block' }, [
			E('strong', {}, [ _('Will rewrite') + ' (' + changed.length + ')' ]),
			E('ul', {}, changed.map(function(item) {
				return E('li', {}, [ E('code', {}, [ item.from + ' → ' + item.to ]) ]);
			}))
		]),
		dnsBlock(_('Already using new domain'), already),
		dnsBlock(_('Unchanged'), unchanged),
		E('label', { 'class': 'cf-option-row' }, [ rewrite, E('span', {}, [ _('Rewrite ingress hostnames') ]) ]),
		E('label', { 'class': 'cf-option-row' }, [ sync, E('span', {}, [ _('Sync DNS') ]) ]),
		E('label', { 'class': 'cf-option-row' }, [ restart, E('span', {}, [ _('Restart service') ]) ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
			migrateBtn
		])
	];

	ui.showModal(_('Domain migration'), body);
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

function deleteOption(id, label, description, checked, disabled) {
	const box = E('input', {
		'type': 'checkbox',
		'id': id,
		'checked': checked ? '' : null,
		'disabled': disabled ? '' : null
	});

	return {
		box: box,
		node: E('label', { 'class': 'cf-option-row', 'for': id }, [
			box,
			E('span', {}, [
				E('strong', {}, [ label ]),
				description ? E('div', { 'class': 'cf-note' }, [ description ]) : ''
			])
		])
	};
}

function openDeleteTunnel(section_id) {
	const name = uci.get('cloudflared', section_id, 'name') || section_id;
	const tunnelId = uci.get('cloudflared', section_id, 'tunnel_id') || '';

	const localOpt = deleteOption('cf-del-local', _('Delete local tunnel data'),
		_('Removes config.yml, credentials, per-tunnel cert.pem and backups.'), true, false);
	const ingressOpt = deleteOption('cf-del-ingress', _('Delete associated ingress rules'),
		_('Removes all ingress rules that belong to this tunnel.'), true, false);
	const remoteOpt = deleteOption('cf-del-remote', _('Delete Cloudflare tunnel'),
		_('Deletes the remote tunnel from Cloudflare. This requires the account certificate or an API token with Account:Cloudflare Tunnel:Edit. This cannot be undone.'),
		!!tunnelId, !tunnelId);
	const dnsOpt = deleteOption('cf-del-dns', _('Delete associated DNS records'),
		_('Deletes DNS records associated with this tunnel.'),
		true, false);

	const certPath = uci.get('cloudflared', section_id, 'cert_path') || '';
	const globalCert = uci.get('cloudflared', 'main', 'cert_path') || '';
	let certShared = false;
	(uci.sections('cloudflared', 'tunnel') || []).forEach(function(sec) {
		if (sec['.name'] !== section_id && certPath !== '' && (sec.cert_path || '') === certPath)
			certShared = true;
	});
	const canRevoke = certPath !== '' && certPath !== globalCert && !certShared;
	const revokeOpt = deleteOption('cf-del-token', _("Revoke the certificate's Cloudflare Tunnel API Token"),
		_('The token is read from cert.pem automatically; no manual lookup is needed. Requires an API token with User:API Tokens:Edit. If this certificate is shared with other tunnels, they will lose management access.'),
		canRevoke, false);

	const continueBox = E('input', { 'type': 'checkbox', 'checked': '' });

	function syncRemoteOptions() {
		const on = remoteOpt.box.checked;
		continueBox.disabled = !on;
	}
	remoteOpt.box.addEventListener('change', syncRemoteOptions);
	syncRemoteOptions();

	const deleteBtn = E('button', {
		'class': 'btn cbi-button cbi-button-negative important',
		'click': function(ev) {
			const btn = ev.currentTarget;
			btn.disabled = true;
			btn.classList.add('spinning');

			const wantedRemote = remoteOpt.box.checked;

			cfApi.action('tunnel_delete', {
				section: section_id,
				delete_local: localOpt.box.checked ? '1' : '0',
				delete_ingress: ingressOpt.box.checked ? '1' : '0',
				delete_remote: wantedRemote ? '1' : '0',
				delete_dns: dnsOpt.box.checked ? '1' : '0',
				revoke_token: revokeOpt.box.checked ? '1' : '0',
				continue_on_remote_error: (wantedRemote && continueBox.checked) ? '1' : '0'
			}).then(function(r) {
				btn.disabled = false;
				btn.classList.remove('spinning');

				if (!r || !r.ok) {
					showResult(_('Delete Tunnel'), cfApi.message(r));
					return;
				}

				ui.hideModal();

				const parts = [ _('Tunnel deleted') ];
				if (wantedRemote) {
					if (r.remote_deleted)
						parts.push(_('Cloudflare tunnel deleted'));
					else if (r.remote_error)
						parts.push(_('Remote tunnel was not deleted: %s').format(r.remote_error));
				}
				if (r.ingress_deleted)
					parts.push(_('Ingress rules deleted: %s').format(r.ingress_deleted));
				if (r.dns_deleted || r.dns_failed)
					parts.push(_('DNS records deleted: %s, failed: %s').format(r.dns_deleted || 0, r.dns_failed || 0));
				if (r.local_removed)
					parts.push(_('Local files deleted'));
				if (r.local_skipped)
					parts.push(_('Local files not deleted: %s').format(r.local_skipped));
				if (r.token_revoked)
					parts.push(_('Cloudflare Tunnel API Token revoked'));
				if (r.token_revoke_error)
					parts.push(_('Token revoke failed: %s').format(r.token_revoke_error));

				const warnMap = {
					dns_missing: _('Missing API token, tunnel ID or domain; DNS records were not deleted'),
					dns_query_failed: _('Unable to query DNS records'),
					token_revoke_skipped_remote: _('Token not revoked because the remote tunnel was not deleted'),
					token_cert_missing: _('Token not revoked: cert.pem not found')
				};

				(r.warnings || []).forEach(function(w) {
					if (w === 'remote_delete_failed' || w === 'token_revoke_failed')
						return;
					parts.push(warnMap[w] || w);
				});

				const warn = (r.warnings && r.warnings.length) ||
					r.token_revoke_error || (wantedRemote && !r.remote_deleted);

				if (cfResult.store('cf-tunnel-delete-result', parts, warn ? 'warning' : 'info')) {
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

	ui.showModal(_('Delete Tunnel') + ' - ' + name, [
		E('p', {}, [ _('The tunnel configuration will be removed. Choose what else to delete:') ]),
		E('p', { 'class': 'cf-note' }, [ tunnelId ? _('Tunnel ID: %s').format(tunnelId) : _('Tunnel ID: not set') ]),
		localOpt.node,
		ingressOpt.node,
		remoteOpt.node,
		E('label', { 'class': 'cf-option-row' }, [
			continueBox,
			E('span', {}, [ _('Continue deleting local configuration if remote deletion fails') ])
		]),
		revokeOpt.node,
		dnsOpt.node,
		E('p', { 'class': 'cf-note' }, [ _('Unsaved changes on this page will be discarded.') ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
			' ',
			deleteBtn
		])
	]);
}

function askForceDelete(section_id, name, tunnelId) {
	return new Promise(function(resolve) {
		ui.showModal(_('Tunnel already exists'), [
			E('p', {}, [ _('A Cloudflare tunnel named "%s" already exists.').format(name) ]),
			tunnelId ? E('p', {}, [ _('Tunnel ID: %s').format(tunnelId) ]) : '',
			E('p', { 'style': 'color:var(--danger, var(--v-err, #c42b2b)); font-weight:600;' }, [
				_('Force deleting it will disconnect all clients using this tunnel and may break DNS records that point to it. This cannot be undone.')
			]),
			E('p', { 'class': 'cf-note' }, [
				_('A new tunnel will be created with the same name but a new tunnel ID. Sync DNS after creation if needed.')
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': function() { ui.hideModal(); resolve(false); }
				}, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'click': function() { ui.hideModal(); resolve(true); }
				}, [ _('Force delete and create') ])
			])
		]);
	});
}

function createTunnelFlow(section_id, name, existingId, force, forceDelete, remoteId) {
	return cfApi.action('tunnel_create', {
		section: section_id,
		name: name || '',
		force: force ? '1' : '0',
		force_delete: forceDelete ? '1' : '0',
		tunnel_id: remoteId || ''
	}).then(function(r) {
		if (r && r.ok) {
			ui.hideModal();

			let text = r.already_created
				? _('Tunnel already exists locally: %s').format(r.tunnel_id || '')
				: _('Tunnel created: %s').format(r.tunnel_id || '');
			let level = 'info';

			if (r.config === false) {
				text = _('Tunnel created, but config generation failed. Check the log.');
				level = 'warning';
			}
			else if (r.enabled !== false && r.running === false) {
				text = _('Tunnel created, but it is not running yet. Check the log or start the service.');
				level = 'warning';
			}

			ui.addNotification(null, E('p', {}, [ text ]), level);
			setTimeout(function() { location.reload(); }, 1200);
			return true;
		}

		if (r && r.exists) {
			const detectedId = r.tunnel_id || remoteId || existingId;
			return askForceDelete(section_id, name, detectedId).then(function(ok) {
				if (!ok)
					return false;
				return createTunnelFlow(section_id, name, existingId, force, true, detectedId);
			});
		}

		ui.hideModal();
		showResult(_('Create Tunnel'), cfApi.message(r));
		return false;
	});
}

function openImportTunnel() {
	const nameInput = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'placeholder': 'office'
	});
	const tokenInput = E('input', {
		'type': 'password',
		'class': 'cbi-input-text',
		'placeholder': 'Cloudflare API token'
	});
	const statusEl = E('p', { 'class': 'cf-note' });

	const importBtn = E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': function(ev) {
			const btn = ev.currentTarget;
			const name = (nameInput.value || '').trim();
			const token = (tokenInput.value || '').trim();

			if (!name || !token) {
				statusEl.textContent = _('Tunnel name and API token are required.');
				return;
			}

			btn.disabled = true;
			btn.classList.add('spinning');
			statusEl.textContent = _('Importing...');

			cfApi.action('tunnel_import', {
				name: name,
				api_token: token
			}).then(function(r) {
				btn.disabled = false;
				btn.classList.remove('spinning');

				if (!r || !r.ok) {
					showResult(_('Import Tunnel'), cfApi.message(r));
					return;
				}

				ui.hideModal();

				const parts = [
					r.created_section ? _('New tunnel created') : _('Existing tunnel updated'),
					_('Tunnel imported: %s').format(r.name || r.tunnel_id || '')
				];

				if (r.ingress_imported)
					parts.push(_('Ingress rules imported: %s').format(r.ingress_imported));
				if (r.ingress_updated)
					parts.push(_('Ingress rules updated: %s').format(r.ingress_updated));
				if (r.credentials_saved)
					parts.push(_('Credentials saved'));
				else
					parts.push(_('Credentials were not saved automatically. Upload the credentials JSON manually.'));

				if (r.config === false)
					parts.push(_('Config regeneration failed. Check the log.'));
				else if (r.restarted === false)
					parts.push(_('Service restart failed. Check the log.'));

				const warn = !r.credentials_saved || r.config === false || r.restarted === false;
				ui.addNotification(null, E('p', {}, [ parts.join(' · ') ]),
					warn ? 'warning' : 'info');

				setTimeout(function() { location.reload(); }, 900);
			});
		}
	}, [ _('Import') ]);

	ui.showModal(_('Import Tunnel'), [
		E('p', {}, [ _('Import a tunnel and its ingress rules from Cloudflare.') ]),
		E('label', { 'class': 'cbi-value' }, [
			E('span', { 'class': 'cbi-value-title' }, [ _('Tunnel Name') ]),
			E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
		]),
		E('label', { 'class': 'cbi-value' }, [
			E('span', { 'class': 'cbi-value-title' }, [ _('Cloudflare API Token') ]),
			E('div', { 'class': 'cbi-value-field' }, [ tokenInput ])
		]),
		E('p', { 'class': 'cf-note' }, [
			_('Required token permissions: Account:Cloudflare Tunnel:Read, Zone:Zone:Read, Zone:DNS:Read.')
		]),
		E('p', { 'class': 'cf-note' }, [
			_('Locally managed tunnels only provide DNS hostnames; fill origin services manually.')
		]),
		statusEl,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
			' ',
			importBtn
		])
	]);
}

function finishAuthorize(section_id) {
	const existingId = uci.get('cloudflared', section_id, 'tunnel_id') || '';
	if (existingId) {
		location.reload();
		return;
	}

	const name = uci.get('cloudflared', section_id, 'name') || '';

	ui.showModal(_('Create Tunnel'), [
		E('p', {}, [ _('Authorization complete. Creating the tunnel...') ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Dismiss') ])
		])
	]);

	return createTunnelFlow(section_id, name, '', false);
}

function loginFlow(section_id, force) {
	if (activeLogins[section_id])
		return Promise.resolve(false);

	activeLogins[section_id] = true;

	let timer = null;
	let closed = false;
	let tries = 0;
	let reauthBusy = false;

	const linkWaiting = E('div', { 'class': 'cf-login-waiting', 'role': 'status' }, [
		E('span', { 'class': 'cf-spinner', 'aria-hidden': 'true' }),
		E('span', {}, [ _('Generating authorization link, please wait...') ])
	]);
	const linkBox = E('div', { 'class': 'cf-login-box' }, [ linkWaiting ]);
	const stateEl = E('p', {}, [ _('Waiting for authorization...') ]);

	function stop() {
		closed = true;
		delete activeLogins[section_id];
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
		if (reauthBusy)
			return;
		reauthBusy = true;
		stop();
		ui.hideModal();
		loginFlow(section_id, '1');
	}

	function update(st) {
		if (closed)
			return;

		if (st && st.url) {
			if (linkWaiting.parentNode)
				linkWaiting.remove();
			if (!linkBox.querySelector('a'))
				linkBox.appendChild(E('a', { 'href': st.url, 'target': '_blank', 'rel': 'noopener' }, [ st.url ]));
		}

		stateEl.textContent = (st && st.message) ? st.message : _('Waiting for authorization...');

		if (st && st.state === 'done') {
			stop();
			ui.hideModal();
			finishAuthorize(section_id);
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

	return cfApi.action('login_start', {
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
					'class': 'btn cbi-button cbi-button-apply',
					'click': function(ev) {
						ev.preventDefault();
						migrateDomain(section_id, domain);
					}
				}, [ _('Migrate Domain') ])
			]);
		};

		o = s.option(form.Value, 'data_dir', _('Data Directory'),
			_('Leave empty to use /etc/cloudflared/tunnels/<section>.'));
		o.placeholder = '/etc/cloudflared/tunnels/<section>';
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.Value, 'cert_path', _('Certificate Path'),
			_('Leave empty to use <data_dir>/cert.pem; authorization writes here. If it does not exist, the global certificate is used. Different Cloudflare accounts need different certificates.'));
		o.placeholder = '<data_dir>/cert.pem';
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.Value, 'credentials_file', _('Credentials File'),
			_('Leave empty to auto-detect <tunnel_id>.json in the data directory.'));
		o.placeholder = '<data_dir>/<tunnel_id>.json';
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.Value, 'api_token', _('Cloudflare API Token Override'),
			_('Optional per-tunnel API token for DNS status, DNS deletion, remote import, remote tunnel deletion and certificate token revocation. This is not the tunnel run token. Authorization does not fill this field. Leave empty to use the global API token.'));
		o.password = true;
		o.rmempty = true;
		o.modalonly = true;

		o = s.option(form.DummyValue, '_api_token_link', '');
		o.modalonly = true;
		o.textvalue = function() {
			const fallback = 'https://dash.cloudflare.com/profile/api-tokens';
			const link = E('a', {
				'href': uci.get('cloudflared', 'main', 'api_token_url') || fallback,
				'target': '_blank',
				'rel': 'noopener noreferrer'
			}, [ _('Get Cloudflare API Token') ]);
			return E('div', { 'class': 'cf-token-link' }, [ link ]);
		};

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

		o = s.option(form.Flag, 'use_global_cert', _('Use Global Certificate'),
			_('Reuse the account certificate for this tunnel. Tunnels in the same Cloudflare account can share this certificate and avoid creating another authorization token.'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Button, '_authorize', _('Authorize'));
		o.inputstyle = 'action';
		o.modalonly = true;
		o.description = _('Authorization creates a new Cloudflare Tunnel API Token inside cert.pem. Reuse the global certificate for tunnels in the same account to avoid extra tokens.');
		o.onclick = function(ev, section_id) {
			const btn = ev.currentTarget;
			if (btn) {
				btn.disabled = true;
				btn.classList.add('spinning');
			}

			return prepareSection(this.section, section_id, ev).then(function(savedId) {
				if (!savedId) {
					if (btn) {
						btn.disabled = false;
						btn.classList.remove('spinning');
					}
					return;
				}

				return loginFlow(savedId, '0');
			}, function(err) {
				if (btn) {
					btn.disabled = false;
					btn.classList.remove('spinning');
				}
				throw err;
			});
		};

		o = s.option(form.Button, '_create', _('Create Tunnel'));
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			if (!requireSavedTunnel(section_id, _('Create Tunnel')))
				return;

			const name = siblingValue(this.section, section_id, 'name');
			const existingId = uci.get('cloudflared', section_id, 'tunnel_id') || '';

			if (existingId && !confirm(_('This tunnel already has an ID. Creating a new tunnel will replace it. Continue?')))
				return;

			if (!confirm(_('Create a Cloudflare tunnel for this entry?')))
				return;

			return createTunnelFlow(section_id, name, existingId, !!existingId);
		};

		o = s.option(form.Button, '_reload', _('Migrate Domain'));
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			if (!requireSavedTunnel(section_id, _('Domain migration')))
				return;

			migrateDomain(section_id, siblingValue(this.section, section_id, 'domain'));
		};

		o = s.option(form.Button, '_cert', _('Upload cert.pem'));
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			if (!requireSavedTunnel(section_id, _('Upload cert.pem')))
				return;

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
		o.description = _('The tunnel run credentials generated by Cloudflare. This is not an API token.');
		o.modalonly = true;
		o.onclick = function(ev, section_id) {
			if (!requireSavedTunnel(section_id, _('Upload credentials.json')))
				return;

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
				openDeleteTunnel(section_id);
			}, true);

			const importBtn = E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': openImportTunnel
			}, [ _('Import from Remote') ]);

			const toolbar = E('div', { 'class': 'cf-table-toolbar' }, [ importBtn ]);

			function placeToolbar() {
				const table = node.querySelector('table');
				if (table && table.parentNode) {
					if (toolbar.parentNode !== table.parentNode || toolbar.nextSibling !== table)
						table.parentNode.insertBefore(toolbar, table);
				}
				else if (!toolbar.parentNode) {
					node.insertBefore(toolbar, node.firstChild);
				}
			}

			placeToolbar();
			if (typeof MutationObserver !== 'undefined') {
				new MutationObserver(function() { placeToolbar(); })
					.observe(node, { childList: true, subtree: true });
			}

			cfResult.consume(node, 'cf-tunnel-delete-result');
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

'use strict';
'require view';
'require form';
'require ui';
'require poll';
'require cloudflared.api as cfApi';

function card(cls, label, valueNode, subNode, title) {
	return E('div', { 'class': 'cf-stat ' + cls, 'title': title || null }, [
		E('div', { 'class': 'cf-stat-label' }, [ label ]),
		E('div', { 'class': 'cf-stat-value' }, [ valueNode ]),
		subNode ? E('div', { 'class': 'cf-stat-sub' }, [ subNode ]) : ''
	]);
}

function serviceButton(op, label, style) {
	return E('button', {
		'type': 'button',
		'class': 'btn cbi-button ' + (style || ''),
		'click': function() {
			return cfApi.action('service', { op: op }).then(function(r) {
				if (!r || !r.ok) {
					ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
					return;
				}
				ui.addNotification(null, E('p', {}, [ _('Service operation completed.') ]), 'info');
				setTimeout(function() { location.reload(); }, 900);
			});
		}
	}, [ label ]);
}

return view.extend({
	render: function() {
		// Render the page header ourselves and keep the form header empty.
		// The form is placed below the status cards, but the title should stay
		// at the top of the page.
		const map = new form.Map('cloudflared', '', '');

		const pageHeader = E('div', {}, [
			E('h2', { 'name': 'content' }, [ _('Cloudflared Overview') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Configure Cloudflare Tunnel') + ' ' + _('Save only stores changes; Save & Apply rebuilds config and restarts the service.')
			])
		]);

		let s = map.section(form.NamedSection, 'main', 'main', _('Main Settings'));
		s.addremove = false;

		let o = s.option(form.Value, 'data_path', _('Data Directory'),
			_('Persistent directory for certificates, tunnel credentials and generated configs. Backed up by sysupgrade.'));
		o.placeholder = '/etc/cloudflared';

		o = s.option(form.Value, 'cloudflared_path', _('Cloudflared Binary Path'),
			_('Leave empty to auto-detect /opt/cloudflared/bin/cloudflared or /usr/bin/cloudflared.'));
		o.placeholder = '/opt/cloudflared/bin/cloudflared';
		o.rmempty = true;

		o = s.option(form.Value, 'cert_path', _('Global Certificate Path'),
			_('Account-level cert.pem used when a tunnel has no certificate of its own. New tunnel authorization writes to the tunnel data directory instead.'));
		o.placeholder = '/etc/cloudflared/cert.pem';
		o.rmempty = true;

		o = s.option(form.DummyValue, '_runtime_paths', _('Runtime Paths'));
		o.textvalue = function() {
			return E('div', {}, [
				E('div', {}, [ _('Core directory') + ': ', E('code', {}, [ '/opt/cloudflared/bin' ]) ]),
				E('div', {}, [ _('Backup directory') + ': ', E('code', {}, [ '/opt/cloudflared/backups' ]) ]),
				E('div', {}, [ _('Runtime state') + ': ', E('code', {}, [ '/tmp/cloudflared' ]) ]),
				E('div', {}, [ _('Logs') + ': ', E('code', {}, [ '/var/log/cloudflared' ]) ])
			]);
		};

		o = s.option(form.Value, 'api_token', _('Cloudflare API Token'));
		o.password = true;

		o = s.option(form.Value, 'download_url', _('Download URL'),
			_('Base URL for cloudflared releases. Useful for mirrors.'));
		o.default = 'https://github.com/cloudflare/cloudflared/releases/latest/download';
		o.rmempty = true;

		o = s.option(form.Flag, 'allow_dns_delete', _('Allow DNS Deletion'),
			_('Disabled by default. Only delete records matching the current tunnel target when enabled.'));
		o.default = '0';
		o.rmempty = false;

		return Promise.all([
			cfApi.action('overview', {}),
			cfApi.action('site_stats', {})
		]).then(function(res) {
			let ov = res[0] || {};
			let sites = (res[1] && res[1].counts) ? res[1].counts : null;

			document.head.appendChild(E('link', {
				'rel': 'stylesheet',
				'href': L.resource('view/cloudflared/cloudflared.css')
			}));

			const stats = E('div', { 'class': 'cf-stat-grid' }, [
				card(ov.running ? 'ok' : 'bad', _('Connection'),
					E('span', { 'style': 'color:' + (ov.running ? 'var(--success, var(--v-ok, #0b7f6c))' : 'var(--danger, var(--v-err, #c42b2b))') },
						[ (ov.running ? '● ' + _('Running') : '● ' + _('Stopped')) ]),
					_('Enable on boot') + ': ' + (ov.service_enabled ? _('Enabled') : _('Inactive'))),
				(function() {
					const tc = ov.tunnel_counts || { total: 0, running: 0, pending: 0, abnormal: 0, disabled: 0 };

					return card((tc.abnormal > 0) ? 'warn' : 'ok',
						_('Tunnels') + ' · ' + tc.total,
						E('span', { 'class': 'cf-site-running' }, [
							_('Running') + ' ' + tc.running
						]),
						E('div', { 'class': 'cf-site-counts' }, [
							E('span', { 'class': 'cf-site-pending' }, [ _('Pending') + ' ' + tc.pending ]),
							E('span', { 'class': 'cf-site-abnormal' }, [ _('Abnormal') + ' ' + tc.abnormal ]),
							E('span', { 'class': 'cf-site-disabled' }, [ _('Site Disabled') + ' ' + tc.disabled ])
						]));
				})(),
				card('cf-stat-wide ' + ((sites && sites.abnormal > 0) ? 'warn' : 'ok'), _('Sites'),
					E('span', { 'class': 'cf-site-running' }, [
						_('Running') + ' ' + (sites ? sites.running : '—')
					]),
					E('div', { 'class': 'cf-site-counts' }, [
						E('span', { 'class': 'cf-site-pending' }, [ _('Pending') + ' ' + (sites ? sites.pending : '—') ]),
						E('span', { 'class': 'cf-site-abnormal' }, [ _('Abnormal') + ' ' + (sites ? sites.abnormal : '—') ]),
						E('span', { 'class': 'cf-site-disabled' }, [ _('Site Disabled') + ' ' + (sites ? sites.disabled : '—') ]),
						E('span', {}, [ _('Sites') + ' ' + (sites ? sites.total : '—') ])
					]),
					_('Site counts use saved ingress rules. Running means valid configuration, a running tunnel process and a synced CNAME; origin reachability is not tested.'))
			]);

			const guideRow = E('div', { 'class': 'cf-stat-guide-row' }, [
				E('a', {
					'class': 'cf-stat-guide',
					'href': 'https://blog.chdao.com.cn/archives/luci-app-cloudflared-cao-zuo-zhi-yin',
					'target': '_blank',
					'rel': 'noopener noreferrer'
				}, [ _('操作指引') ])
			]);

			const enableBox = E('input', {
				'type': 'checkbox',
				'checked': ov.service_enabled ? '' : null
			});

			enableBox.addEventListener('change', function() {
				const want = enableBox.checked;
				cfApi.action('service_enable', { enabled: want ? '1' : '0' }).then(function(r) {
					if (!r || !r.ok) {
						enableBox.checked = !want;
						ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
					}
				});
			});

			let installTimer = null;

			const progressWrap = E('div', { 'class': 'cf-progress-wrap', 'hidden': '' }, [
				E('div', { 'class': 'cf-progress-head' }, [
					E('span', { 'id': 'cf-progress-label' }),
					E('span', { 'id': 'cf-progress-pct' }),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button',
						'click': function() {
							cfApi.action('core_cancel', {}).then(function(r) {
								if (installTimer) {
									clearInterval(installTimer);
									installTimer = null;
								}
								progressWrap.hidden = true;
								if (!r || !r.ok)
									ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
								else
									ui.addNotification(null, E('p', {}, [ _('Install cancelled') ]), 'warning');
							});
						}
					}, [ _('Cancel') ])
				]),
				E('div', { 'class': 'cf-progress' }, [
					E('div', { 'id': 'cf-progress-bar', 'class': 'cf-progress-bar' })
				])
			]);

			const out = E('pre', { 'id': 'cf-core-out', 'class': 'cf-out' });
			const fileInput = E('input', { 'type': 'file', 'style': 'display:none' });

			function setProgress(mode, pct) {
				const bar = document.getElementById('cf-progress-bar');
				const pctEl = document.getElementById('cf-progress-pct');
				progressWrap.hidden = false;

				if (!bar)
					return;

				bar.className = 'cf-progress-bar';

				if (mode === 'indeterminate') {
					bar.className += ' cf-indeterminate';
					bar.style.width = '';
					if (pctEl) pctEl.textContent = '';
				}
				else {
					bar.style.width = (pct || 0) + '%';
					if (mode === 'done') bar.className += ' cf-done';
					if (mode === 'fail') bar.className += ' cf-fail';
					if (pctEl) pctEl.textContent = (pct || 0) > 0 ? (pct + '%') : '';
				}
			}

			function pollCore() {
				return cfApi.action('core_status', {}).then(function(r) {
					const el = document.getElementById('cf-progress-label');
					if (el) el.textContent = (r && r.message) ? r.message : '';
					if (out) out.textContent = (r && r.log_tail) ? r.log_tail : '';

					if (!r || r.state === 'done' || r.state === 'failed') {
						setProgress(r && r.state === 'failed' ? 'fail' : 'done', 100);
						return false;
					}

					setProgress(r.state === 'downloading' ? 'indeterminate' : 'progress', 0);
					return true;
				});
			}

			const checkBody = E('div', { 'class': 'cf-check-body' });
			const checkCard = E('div', { 'class': 'cf-check-card', 'hidden': '' }, [
				E('div', { 'class': 'cf-check-head' }, [
					E('strong', {}, [ _('Check Status') ]),
					E('button', {
						'type': 'button',
						'class': 'btn cbi-button',
						'title': _('Dismiss'),
						'click': function() { checkCard.hidden = true; }
					}, [ '×' ])
				]),
				checkBody
			]);

			function checkRow(label, value) {
				return E('div', { 'class': 'cf-check-row' }, [
					E('span', { 'class': 'cf-check-label' }, [ label ]),
					E('span', { 'class': 'cf-check-value' }, [ value || '—' ])
				]);
			}

			function showCheck(r) {
				r = r || {};

				let statusText = _('Unknown');
				if (!r.installed)
					statusText = _('Not installed');
				else if (r.up_to_date)
					statusText = _('Up to date');
				else if (r.latest && r.current)
					statusText = _('Update available');

				while (checkBody.firstChild)
					checkBody.removeChild(checkBody.firstChild);

				checkBody.appendChild(checkRow(_('Installed'), r.installed ? _('Yes') : _('No')));
				checkBody.appendChild(checkRow(_('Current version'), r.current));
				checkBody.appendChild(checkRow(_('Latest version'), r.latest || _('Unknown')));
				checkBody.appendChild(checkRow(_('Status'), statusText));
				checkBody.appendChild(checkRow(_('Binary'), r.binary));

				checkCard.hidden = false;
			}

			function compareVersion(a, b) {
				const pa = String(a || '').replace(/^v/, '').split('.').map(function(v) { return parseInt(v, 10) || 0; });
				const pb = String(b || '').replace(/^v/, '').split('.').map(function(v) { return parseInt(v, 10) || 0; });
				const len = Math.max(pa.length, pb.length);

				for (let i = 0; i < len; i++) {
					const x = pa[i] || 0, y = pb[i] || 0;
					if (x !== y)
						return (x > y) ? 1 : -1;
				}
				return 0;
			}

			function startInstall() {
				setProgress('indeterminate', 0);

				cfApi.action('core_install', {}).then(function(r) {
					if (!r || !r.ok) {
						setProgress('fail', 100);
						ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
						return;
					}

					let tries = 0;
					if (installTimer)
						clearInterval(installTimer);
					installTimer = setInterval(function() {
						pollCore().then(function(again) {
							if (!again || ++tries > 300) {
								clearInterval(installTimer);
								installTimer = null;
								location.reload();
							}
						});
					}, 1000);
				});
			}

			function checkThenInstall() {
				setProgress('indeterminate', 0);

				const label = document.getElementById('cf-progress-label');
				if (label)
					label.textContent = _('Checking for updates...');

				cfApi.action('core_check', {}).then(function(r) {
					showCheck(r);

					if (!r || !r.ok) {
						setProgress('fail', 100);
						ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
						return;
					}

					if (!r.installed) {
						startInstall();
						return;
					}

					if (!r.latest) {
						progressWrap.hidden = true;
						ui.addNotification(null, E('p', {}, [ _('Unable to determine the latest version') ]), 'warning');
						return;
					}

					const cmp = compareVersion(r.latest, r.current);

					if (cmp > 0) {
						startInstall();
						return;
					}

					progressWrap.hidden = true;
					ui.addNotification(null, E('p', {}, [
						cmp < 0
							? _('Local version is newer than the remote version, no update needed.')
							: _('Already the latest version, no update needed.')
					]), 'info');
				});
			}

			const top = E('div', { 'class': 'cf-top-grid' }, [
				E('div', { 'class': 'cf-top-col' }, [
					E('h3', {}, [ _('Service Control') ]),
					E('div', { 'class': 'cf-actions' }, [
						serviceButton('start', _('Start'), 'cbi-button-apply'),
						serviceButton('stop', _('Stop'), 'cbi-button-reset'),
						serviceButton('restart', _('Restart'), 'cbi-button-reload')
					]),
					E('div', { 'class': 'cf-enable-row' }, [
						enableBox,
						E('label', {}, [ _('Enable on boot') ])
					])
				]),
				E('div', { 'class': 'cf-top-col' }, [
					E('h3', {}, [ _('Cloudflared Core') ]),
					E('div', { 'class': 'cf-meta' }, [
						E('div', {}, [ _('Architecture') + ': ', E('strong', {}, [ ov.arch || '—' ]) ]),
						E('div', {}, [ _('Current version') + ': ', E('strong', {}, [ ov.version || '—' ]) ]),
						E('div', {}, [ _('Binary') + ': ', E('code', {}, [ ov.binary || '—' ]) ])
					]),
					E('div', { 'class': 'cf-actions' }, [
						E('button', {
							'type': 'button',
							'class': 'btn cbi-button cbi-button-apply',
							'click': checkThenInstall
						}, [ _('Install / Update') ]),
						E('button', {
							'type': 'button',
							'class': 'btn cbi-button',
							'click': function() {
								return cfApi.action('core_check', {}).then(function(r) {
									showCheck(r);
									if (!r || !r.ok)
										ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
								});
							}
						}, [ _('Check Status') ]),
						ov.asset_url ? E('a', {
							'class': 'btn cbi-button',
							'href': ov.asset_url,
							'target': '_blank',
							'rel': 'noopener',
							'download': ov.asset_name || null
						}, [ _('Download Core') ]) : E('button', { 'class': 'btn cbi-button', 'disabled': '' }, [ _('Download Core') ]),
						E('button', {
							'type': 'button',
							'class': 'btn cbi-button',
							'click': function() { fileInput.click(); }
						}, [ _('Upload Core') ])
					]),
					fileInput,
					out,
					progressWrap
				])
			]);

			fileInput.addEventListener('change', function() {
				if (!fileInput.files || !fileInput.files.length)
					return;

				const file = fileInput.files[0];
				ui.showModal(_('Uploading...'), [
					E('p', {}, [ _('Upload complete, reloading...') ])
				]);

				cfApi.upload('core_upload', '', file).then(function(r) {
					ui.hideModal();
					if (!r || !r.ok) {
						ui.addNotification(null, E('p', {}, [ cfApi.message(r) ]), 'danger');
						return;
					}
					location.reload();
				});
			});

			return map.render().then(function(formNode) {
				return E('div', {}, [ pageHeader, checkCard, guideRow, stats, top, formNode ]);
			});
		});
	},

	handleSaveApply: function(ev) {
		return this.handleSave(ev).then(function() {
			return cfApi.action('apply_config', {});
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

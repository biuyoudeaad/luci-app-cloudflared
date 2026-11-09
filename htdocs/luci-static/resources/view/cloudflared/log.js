'use strict';
'require view';
'require form';
'require poll';
'require ui';
'require cloudflared.api as cfApi';

const LogViewer = form.DummyValue.extend({
	__init__: function() {
		this.super('__init__', arguments);
		this.which = 'app';
	},

	renderWidget: function() {
		const which = this.which;
		const filter = E('input', {
			'type': 'text',
			'class': 'cbi-input-text cf-log-filter',
			'placeholder': _('Filter expression (grep -E)')
		});
		const interval = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '0' }, [ _('Disabled') ]),
			E('option', { 'value': '2000' }, [ '2s' ]),
			E('option', { 'value': '5000', 'selected': '' }, [ '5s' ]),
			E('option', { 'value': '10000' }, [ '10s' ]),
			E('option', { 'value': '30000' }, [ '30s' ])
		]);
		const info = E('span', { 'class': 'cf-log-info' });
		const out = E('pre', { 'class': 'cf-log-view' });
		let paused = false;

		function load() {
			if (paused || !out.offsetParent || out.clientHeight <= 0)
				return Promise.resolve();

			const atBottom = out.scrollTop + out.clientHeight >= out.scrollHeight - 24;
			const pattern = filter.value.replace(/^\s+|\s+$/g, '');

			return cfApi.action('get_log', { which: which, filter: pattern, lines: 800 }).then(function(r) {
				if (!r || !r.ok) {
					out.textContent = (r && r.message) ? r.message : _('Failed to load log');
					return;
				}

				out.textContent = r.log ? r.log : (_('No log content yet.') + '\n' + (r.path || ''));
				info.textContent = r.path || '';

				if (atBottom)
					out.scrollTop = out.scrollHeight;
			});
		}

		function clear() {
			if (!confirm(_('Clear the current log?')))
				return;

			cfApi.action('clear_log', { which: which }).then(function(r) {
				if (!r || !r.ok)
					ui.addNotification(null, E('p', {}, [ (r && r.message) || _('Failed to load log') ]), 'danger');
				load();
			});
		}

		filter.addEventListener('keydown', function(ev) {
			if (ev.key === 'Enter')
				load();
		});

		const pauseBtn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button',
			'click': function() {
				paused = !paused;
				pauseBtn.textContent = paused ? _('Resume') : _('Pause');
				if (!paused)
					load();
			}
		}, [ _('Pause') ]);

		out.dataset.cfLogWhich = which;
		out.cfLoad = load;
		out.cfInterval = interval;
		out.cfPaused = function() { return paused; };

		return E('div', { 'class': 'cf-log-wrap' }, [
			E('div', { 'class': 'cf-log-toolbar' }, [
				filter,
				interval,
				E('button', { 'type': 'button', 'class': 'btn cbi-button', 'click': function() { load(); } }, [ _('Refresh') ]),
				E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-reset', 'click': clear }, [ _('Clear') ]),
				pauseBtn,
				E('button', { 'type': 'button', 'class': 'btn cbi-button', 'click': function() { out.scrollTop = out.scrollHeight; } }, [ _('Scroll To Bottom') ]),
				info
			]),
			out
		]);
	}
});

return view.extend({
	load: function() {
		return Promise.resolve();
	},

	render: function() {
		const map = new form.Map('cloudflared', _('Log'), _('Cloudflared log settings and viewers.'));

		let s = map.section(form.NamedSection, 'log', 'log', _('Log'));
		s.addremove = false;

		s.tab('settings', _('Log Settings'));
		s.tab('app', _('Plugin Log'));
		s.tab('core', _('Core Log'));

		let o = s.taboption('settings', form.Flag, 'clear_at_stop', _('Clear At Stop'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('settings', form.Flag, 'scheduled_clear', _('Scheduled Cleanup'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('settings', form.Value, 'scheduled_clear_cron', _('Cron Expression'),
			_('Standard five-field cron expression, e.g. */5 * * * *.'));
		o.default = '*/5 * * * *';
		o.depends('scheduled_clear', '1');
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			if (!/^[\d*\/,\-]+\s+[\d*\/,\-]+\s+[\d*\/,\-]+\s+[\d*\/,\-]+\s+[\d*\/,\-]+$/.test(value))
				return _('Invalid cron expression');
			return true;
		};

		o = s.taboption('settings', form.Value, 'log_max_size', _('Log Size Limit'),
			_('Clean a log file when it exceeds this size at the scheduled time. 0 clears it every time.'));
		o.default = '1';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.depends('scheduled_clear', '1');

		o = s.taboption('settings', form.ListValue, 'log_max_unit', _('Size Unit'));
		o.value('KB', 'KB');
		o.value('MB', 'MB');
		o.value('GB', 'GB');
		o.default = 'MB';
		o.rmempty = false;
		o.depends('scheduled_clear', '1');

		o = s.taboption('app', LogViewer, '_app_log');
		o.which = 'app';

		o = s.taboption('core', LogViewer, '_core_log');
		o.which = 'core';

		return map.render().then(function(node) {
			document.head.appendChild(E('link', {
				'rel': 'stylesheet',
				'href': L.resource('view/cloudflared/cloudflared.css')
			}));

			const last = { app: 0, core: 0 };

			poll.add(function() {
				const now = Date.now();

				['app', 'core'].forEach(function(which) {
					const view = document.querySelector('.cf-log-view[data-cf-log-which="' + which + '"]');
					if (!view || !view.cfLoad || !view.offsetParent)
						return;
					if (view.cfPaused && view.cfPaused())
						return;

					const wait = view.cfInterval ? parseInt(view.cfInterval.value, 10) : 5000;

					if (!wait || wait <= 0 || now - last[which] < wait)
						return;

					last[which] = now;
					view.cfLoad();
				});
			}, 2);

			['app', 'core'].forEach(function(which) {
				const view = document.querySelector('.cf-log-view[data-cf-log-which="' + which + '"]');
				if (view && view.cfLoad)
					view.cfLoad();
			});

			document.addEventListener('click', function(ev) {
				const link = ev.target.closest ? ev.target.closest('.cbi-tabmenu a, .tabs a') : null;
				if (!link)
					return;
				setTimeout(function() {
					['app', 'core'].forEach(function(which) {
						const view = document.querySelector('.cf-log-view[data-cf-log-which="' + which + '"]');
						if (view && view.cfLoad)
							view.cfLoad();
					});
				}, 100);
			});

			return node;
		});
	},

	handleSaveApply: function(ev) {
		const self = this;

		return this.handleSave(ev).then(function() {
			return cfApi.action('apply_log', {});
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

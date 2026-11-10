'use strict';
'require baseclass';

function store(key, parts, level) {
	try {
		sessionStorage.setItem(key, JSON.stringify({
			parts: parts || [],
			level: level || 'info'
		}));
		return true;
	}
	catch (e) {
		return false;
	}
}

function consume(node, key) {
	let data = null;

	try {
		const raw = sessionStorage.getItem(key);
		if (raw) {
			sessionStorage.removeItem(key);
			data = JSON.parse(raw);
		}
	}
	catch (e) {}

	if (!node || !data || !data.parts || !data.parts.length)
		return null;

	let card = null;
	let timer = null;

	function remove() {
		if (timer) {
			clearTimeout(timer);
			timer = null;
		}
		if (card && card.parentNode)
			card.parentNode.removeChild(card);
	}

	card = E('div', { 'class': 'cf-result-card ' + (data.level || 'info'), 'role': 'status' }, [
		E('div', { 'class': 'cf-result-body' }, [ data.parts.join(' · ') ]),
		E('button', {
			'type': 'button',
			'class': 'btn cbi-button cf-result-close',
			'click': remove
		}, [ _('Close') ])
	]);

	node.insertBefore(card, node.firstChild);
	timer = setTimeout(remove, 15000);
	return card;
}

return baseclass.extend({
	store: store,
	consume: consume
});

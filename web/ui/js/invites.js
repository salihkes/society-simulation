// Invites: create one (link and QR code), list yours, revoke the active ones.
import { $, api, el, frameForUser, say, when } from './common.js';

async function revoke(token) {
	if (!confirm('revoke this invite? it cannot be undone.'))
		return;
	const reply = await api('/api/invites/revoke', { token });
	if (!reply.success)
		say('message', reply.message);
	await load();
}

function row(inv) {
	const active = inv.status === 'ok';
	return el('tr', { class: active ? '' : 'spent' },
		el('td', {}, when(inv.created_at)),
		el('td', {}, active ? 'active' : inv.status),
		el('td', {}, `${inv.uses_remaining} / ${inv.max_uses}`),
		el('td', {}, when(inv.expires_at)),
		el('td', { class: 'link' }, el('a', { href: inv.url }, inv.url)),
		el('td', {}, active && el('button', { class: 'secondary', onclick: () => revoke(inv.token) }, 'revoke')));
}

async function load() {
	const reply = await api('/api/invites');
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	$('allowed').hidden = false;
	$('rows').replaceChildren(...reply.invites.map(row));
	$('none').hidden = reply.invites.length > 0;
}

async function create(e) {
	e.preventDefault();
	const form = new FormData(e.target);
	const reply = await api('/api/invites/create', {
		max_uses: parseInt(form.get('max_uses'), 10),
		ttl_days: parseFloat(form.get('ttl_days')),
	});
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	say('message', '');
	$('created').hidden = false;
	$('created-url').textContent = reply.url;
	// The SVG is drawn by the server's qrcode package from the invite URL.
	if (reply.qr_svg)
		$('created-qr').innerHTML = reply.qr_svg;
	else
		$('created-qr').replaceChildren(el('p', { class: 'muted' }, 'no QR code: the server has no qrcode package.'));
	await load();
}

if (await frameForUser('your invites')) {
	$('create').addEventListener('submit', create);
	await load();
}

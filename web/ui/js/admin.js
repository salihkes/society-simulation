// The admin users page: the invite tree with ban and unban buttons.
import { $, api, el, frameForUser, say } from './common.js';

let roles = { admins: [], posters: [], current_admin: '' };

async function act(path, username, question, reason) {
	if (reason === null || (question && !confirm(question)))
		return;
	const reply = await api(path, { username, reason: reason || '' });
	say('message', reply.success ? `${reply.message}: ${username}` : `failed: ${reply.message}`,
		reply.success ? 'info' : 'error');
	await load();
}

function ban(name) {
	const reason = prompt(`reason for banning ${name}:\n\n(everyone they invited, transitively, is cascade-banned too)`);
	act('/api/admin/ban', name, null, reason);
}

function unban(name) {
	act('/api/admin/unban', name,
		`unban ${name}? everyone they invited who was cascade-banned comes back too.`);
}

function action(node) {
	if (node.username === roles.current_admin)
		return '(you)';
	if (roles.admins.includes(node.username))
		return 'admin — demote in roles.yaml first';
	if (node.banned)
		return el('button', { class: 'secondary', onclick: () => unban(node.username) }, 'unban');
	if (!node.effective_banned)
		return el('button', { class: 'secondary', onclick: () => ban(node.username) }, 'ban');
	return `(unban ${node.cascade_from} to restore)`;
}

function tags(node) {
	const out = [];
	if (roles.admins.includes(node.username))
		out.push(el('span', { class: 'tag admin' }, 'admin'));
	else if (roles.posters.includes(node.username))
		out.push(el('span', { class: 'tag poster' }, 'poster'));
	if (!node.invited_by)
		out.push(el('span', { class: 'tag' }, 'root'));
	if (node.banned) {
		out.push(el('span', { class: 'tag banned' }, 'banned'));
		out.push(el('span', { class: 'muted' }, `by ${node.banned_by}` + (node.ban_reason ? ` — "${node.ban_reason}"` : '')));
	} else if (node.effective_banned) {
		out.push(el('span', { class: 'tag cascade' }, `cascade-banned (from ${node.cascade_from})`));
	}
	return out;
}

function branch(node) {
	return el('li', {},
		el('div', { class: 'user-row' }, el('strong', {}, node.username), tags(node),
			el('span', { class: 'actions' }, action(node))),
		node.children.length > 0 && el('ul', {}, node.children.map(branch)));
}

async function load() {
	const reply = await api('/api/admin/users');
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	roles = reply;
	$('tree').replaceChildren(...reply.tree.map(branch));
	$('none').hidden = reply.tree.length > 0;
}

if (await frameForUser('users (admin)'))
	await load();

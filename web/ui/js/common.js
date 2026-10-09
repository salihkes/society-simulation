// Shared by every page: API calls, the header and footer, and small DOM helpers.

export async function api(path, data) {
	const init = { credentials: 'same-origin', headers: { Accept: 'application/json' } };
	if (data !== undefined) {
		init.method = 'POST';
		if (data instanceof FormData) {
			init.body = data;
		} else {
			init.headers['Content-Type'] = 'application/json';
			init.body = JSON.stringify(data);
		}
	}
	let reply;
	try {
		const response = await fetch(path, init);
		reply = await response.json();
		reply.status = response.status;
	} catch (e) {
		reply = { success: false, status: 0, message: 'the server could not be reached' };
	}
	return reply;
}

let identityCache = null;

export async function identity() {
	if (!identityCache)
		identityCache = await api('/api/identity');
	return identityCache;
}

export function el(tag, attrs, ...children) {
	const node = document.createElement(tag);
	for (const [key, value] of Object.entries(attrs || {})) {
		if (key === 'class')
			node.className = value;
		else if (key.startsWith('on'))
			node.addEventListener(key.slice(2), value);
		else if (value !== false && value !== null && value !== undefined)
			node.setAttribute(key, value === true ? '' : value);
	}
	for (const child of children.flat()) {
		if (child !== null && child !== undefined && child !== false)
			node.append(child instanceof Node ? child : String(child));
	}
	return node;
}

export function $(id) {
	return document.getElementById(id);
}

// Shows `text` in the message box with id `id` (kind: error, info or warn); empty text hides it.
export function say(id, text, kind = 'error') {
	const box = $(id);
	box.textContent = text || '';
	box.className = 'message ' + kind;
	box.hidden = !text;
}

export function formData(form) {
	return Object.fromEntries(new FormData(form).entries());
}

export function goLogin() {
	const here = location.pathname + location.search;
	location.href = '/login?next=' + encodeURIComponent(here);
}

// The ?next= path to return to after logging in; only a path on this site.
export function nextPath() {
	const next = new URLSearchParams(location.search).get('next') || '/';
	return next.startsWith('/') && !next.startsWith('//') ? next : '/';
}

export function when(seconds) {
	return seconds ? new Date(seconds * 1000).toLocaleString() : 'never';
}

function userBar(s) {
	if (!s.user) {
		return el('div', { class: 'user-bar' },
			el('a', { href: '/login' }, 'login'), el('a', { href: '/register' }, 'register'));
	}
	return el('div', { class: 'user-bar' },
		el('span', { class: 'username' }, s.user),
		s.can_invite && el('a', { href: '/invites' }, 'invites'),
		s.can_admin && el('a', { href: '/admin/users' }, 'admin'),
		el('a', { href: '/settings' }, 'settings'),
		el('a', { href: '/logout' }, 'logout'));
}

function navBar(active) {
	const tab = (href, name) => el('a', { href, class: 'nav-tab' + (active === name ? ' active' : '') }, name);
	return el('div', { class: 'nav-inner' },
		tab('/', 'home'), tab('/r/', 'communities'),
		el('a', { href: '/play/', class: 'play-link' }, 'play'));
}

// Draws the header and footer, titles the page, and returns the session.
export async function frame(title, active) {
	const [id, s] = await Promise.all([identity(), api('/api/session')]);
	const product = id.product_name || '';
	document.title = title ? `${title} - ${product}` : product;
	$('top').replaceChildren(
		el('div', { class: 'header' }, el('div', { class: 'header-inner' },
			el('div', {}, el('a', { href: '/', class: 'logo' }, product),
				el('span', { class: 'tagline' }, 'the virtual world')),
			userBar(s))),
		el('nav', { class: 'nav' }, navBar(active)));
	$('bottom').replaceChildren(el('div', { class: 'footer' },
		el('a', { href: '/' }, 'home'), '|', el('a', { href: '/r/' }, 'communities'), '|',
		el('a', { href: '/play/' }, 'play'), '|', product));
	return s;
}

// The session of a logged-in user; null, and off to the login page, for anyone else.
export async function frameForUser(title, active) {
	const s = await frame(title, active);
	if (s.user)
		return s;
	goLogin();
	return null;
}

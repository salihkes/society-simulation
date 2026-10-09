// Community boards, one page for every /r/ address: the list, a board, a post, submit, wiki, create.
import { $, api, el, frame, goLogin, say } from './common.js';

let s = {};
let boards = [];
let product = '';

function retitle(text) {
	document.title = `${text} - ${product}`;
}

function box(title, ...body) {
	const header = typeof title === 'string' ? title && el('div', { class: 'box-header' }, title) : title;
	return el('div', { class: 'box' }, header, el('div', { class: 'box-body' }, ...body));
}

function boardLink(name, label) {
	return el('a', { href: `/r/${encodeURIComponent(name)}/` }, label || `r/${name}`);
}

function postLink(post, label) {
	return el('a', { href: `/r/${encodeURIComponent(post.subreddit)}/comments/${post.id}/` }, label);
}

async function castVote(kind, item, value, scoreNode, upNode, downNode) {
	if (!s.user) {
		goLogin();
		return;
	}
	const reply = await api('/api/vote', { kind, id: item.id, value: item.user_vote === value ? 0 : value });
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	item.user_vote = reply.user_vote;
	scoreNode.textContent = reply.score;
	upNode.classList.toggle('active', reply.user_vote === 1);
	downNode.classList.toggle('active', reply.user_vote === -1);
}

function voter(kind, item) {
	const score = el('span', { class: 'score' }, item.score);
	const up = el('button', { class: 'up' + (item.user_vote === 1 ? ' active' : ''), title: 'upvote' }, '▲');
	const down = el('button', { class: 'down' + (item.user_vote === -1 ? ' active' : ''), title: 'downvote' }, '▼');
	up.addEventListener('click', () => castVote(kind, item, 1, score, up, down));
	down.addEventListener('click', () => castVote(kind, item, -1, score, up, down));
	return el('div', { class: 'vote' }, up, score, down);
}

function domainOf(url) {
	return url.includes('://') ? url.split('/')[2] : url;
}

function sidebar(sub) {
	const parts = [];
	if (sub) {
		let posting;
		if (s.can_post)
			posting = el('a', { class: 'button', href: `/r/${sub.name}/submit` }, 'submit a post');
		else if (s.user)
			posting = el('p', { class: 'muted' }, 'posting in this community is restricted to approved authors.');
		else
			posting = el('p', { class: 'muted' }, el('a', { href: '/login' }, 'log in'), ' to comment or vote. posting is restricted to approved authors.');
		parts.push(box(`about r/${sub.name}`, el('p', {}, el('strong', {}, sub.title)),
			el('p', { class: 'note' }, sub.description), posting,
			el('p', {}, el('a', { href: `/r/${sub.name}/wiki` }, 'wiki'))));
	}
	parts.push(box('communities', el('ul', { class: 'board-list' }, boards.map((b) => el('li', {}, boardLink(b.name)))),
		s.can_admin && el('p', {}, el('a', { href: '/r/create' }, '+ create community'))));
	$('side').replaceChildren(...parts);
}

function showList() {
	retitle('communities');
	$('view').replaceChildren(box('all communities',
		el('ul', { class: 'board-list' }, boards.map((b) => el('li', {},
			el('strong', {}, boardLink(b.name)), ` — ${b.title}`, el('div', { class: 'muted' }, b.description)))),
		s.can_admin && el('p', {}, el('a', { href: '/r/create' }, '+ create a new community'))));
	$('side').replaceChildren(box('about', el('p', { class: 'note' },
		'communities are themed feeds for game announcements, discussions, and updates. anyone can comment and vote; posting is restricted to approved authors.')));
}

function postRow(post, rank) {
	const title = post.url
		? [el('a', { href: post.url, target: '_blank', rel: 'noopener' }, post.title), ' ', el('span', { class: 'post-domain' }, `(${domainOf(post.url)})`)]
		: [postLink(post, post.title)];
	return el('div', { class: 'post-row' }, el('div', { class: 'rank' }, rank), voter('post', post),
		el('div', {}, el('div', { class: 'post-title' }, title),
			el('div', { class: 'post-meta' }, `submitted by ${post.author} to `, boardLink(post.subreddit), ' · ',
				postLink(post, `${post.comment_count} comments`))));
}

async function showBoard(name) {
	const sort = new URLSearchParams(location.search).get('sort') || 'hot';
	const reply = await api(`/api/r/${encodeURIComponent(name)}?sort=${encodeURIComponent(sort)}`);
	if (!reply.success) {
		location.replace('/r/');
		return;
	}
	const sub = reply.subreddit;
	retitle(`r/${sub.name} - ${reply.sort}`);
	const tabs = el('div', { class: 'sort-tabs' },
		['hot', 'new', 'rising', 'controversial', 'top'].map((key) => el('a',
			{ class: 'sort-tab' + (key === reply.sort ? ' active' : ''), href: `?sort=${key}` }, key)),
		el('a', { class: 'sort-tab right', href: `/r/${sub.name}/wiki` }, 'wiki'));
	const rows = reply.posts.map((p, i) => postRow(p, i + 1));
	if (rows.length === 0) {
		rows.push(box('', el('p', {}, `no posts in r/${sub.name} yet. `,
			s.can_post && el('a', { href: `/r/${sub.name}/submit` }, 'submit the first one'))));
	}
	$('view').replaceChildren(tabs, ...rows);
	sidebar(sub);
}

function commentForm(post, parentId, placeholder, label) {
	const form = el('form', {},
		el('textarea', { name: 'body', placeholder, required: true }),
		el('div', { class: 'button-row' }, el('button', { type: 'submit' }, label)));
	form.addEventListener('submit', async (e) => {
		e.preventDefault();
		const reply = await api(`/api/r/${post.subreddit}/posts/${post.id}/comments`,
			{ body: form.elements.body.value, parent_id: parentId });
		if (reply.success)
			location.reload();
		else
			say('message', reply.message);
	});
	return form;
}

function comment(post, c) {
	const reply = el('div', { class: 'reply-form' }, commentForm(post, c.id, `reply to ${c.author}...`, 'reply'));
	reply.hidden = true;
	const toggle = s.user
		? el('a', { href: '#', onclick: (e) => { e.preventDefault(); reply.hidden = !reply.hidden; } }, 'reply')
		: el('a', { href: '/login' }, 'log in to reply');
	return el('div', { class: 'comment' },
		el('div', { class: 'comment-meta' }, voter('comment', c), el('span', { class: 'author' }, c.author)),
		el('div', { class: 'comment-text' }, c.body),
		el('div', { class: 'comment-actions' }, toggle),
		s.user && reply,
		c.children.length > 0 && el('div', { class: 'comment-children' }, c.children.map((k) => comment(post, k))));
}

async function showPost(name, postId) {
	const reply = await api(`/api/r/${encodeURIComponent(name)}/posts/${encodeURIComponent(postId)}`);
	if (!reply.success) {
		location.replace(`/r/${encodeURIComponent(name)}/`);
		return;
	}
	const { post, comments, subreddit } = reply;
	retitle(`${post.title} : r/${subreddit.name}`);
	const title = post.url ? el('a', { href: post.url, target: '_blank', rel: 'noopener' }, post.title) : post.title;
	const count = comments.length;
	$('view').replaceChildren(
		el('div', { class: 'post-detail' }, voter('post', post),
			el('div', {}, el('div', { class: 'post-title' }, title),
				el('div', { class: 'post-meta' }, 'submitted by ', el('strong', {}, post.author), ' to ', boardLink(subreddit.name)),
				post.body && el('div', { class: 'post-text' }, post.body))),
		box('add a comment', s.user ? commentForm(post, null, 'what are your thoughts?', 'comment')
			: el('p', { class: 'note' }, el('a', { href: '/login' }, 'log in'), ' or ', el('a', { href: '/register' }, 'register'), ' to comment.')),
		box(`${count} top-level comment${count === 1 ? '' : 's'}`,
			count ? comments.map((c) => comment(post, c)) : el('p', { class: 'muted' }, 'no comments yet. be the first.')));
	sidebar(subreddit);
}

function field(label, input) {
	return el('div', { class: 'form-row' }, el('label', { for: input.id }, label), input);
}

function showSubmit(name) {
	retitle(`submit to r/${name}`);
	if (!s.user) {
		goLogin();
		return;
	}
	if (!s.can_post) {
		$('view').replaceChildren(box(`submit a new post to r/${name}`, el('div', { class: 'message info' },
			'your account does not have posting privileges in this community. posting is restricted to approved authors; comments and voting are open to everyone.')));
		return;
	}
	const form = el('form', {},
		field('title', el('input', { type: 'text', id: 'title', name: 'title', maxlength: 300, required: true })),
		field('link (optional)', el('input', { type: 'url', id: 'url', name: 'url', placeholder: 'https://...' })),
		field('text (optional)', el('textarea', { id: 'body', name: 'body', placeholder: 'plain text only.' })),
		el('div', { class: 'button-row' }, el('button', { type: 'submit' }, 'submit'),
			el('a', { class: 'button secondary', href: `/r/${name}/` }, 'cancel')));
	form.addEventListener('submit', async (e) => {
		e.preventDefault();
		const reply = await api(`/api/r/${encodeURIComponent(name)}/posts`, Object.fromEntries(new FormData(form)));
		if (reply.success)
			location.href = `/r/${name}/comments/${reply.post.id}/`;
		else
			say('message', reply.message);
	});
	$('view').replaceChildren(box(`submit a new post to r/${name}`, form));
	sidebar(boards.find((b) => b.name === name));
}

async function showWiki(name) {
	const reply = await api(`/api/r/${encodeURIComponent(name)}?sort=new`);
	if (!reply.success) {
		location.replace('/r/');
		return;
	}
	const sub = reply.subreddit;
	retitle(`wiki - r/${sub.name}`);
	const editing = new URLSearchParams(location.search).get('edit') === '1' && s.can_admin;
	const header = el('div', { class: 'box-header' }, `r/${sub.name} wiki`,
		s.can_admin && !editing && el('a', { href: '?edit=1' }, 'edit'));
	if (!editing) {
		$('view').replaceChildren(box(header, el('div', { class: 'wiki-text' }, sub.wiki)));
		sidebar(sub);
		return;
	}
	const text = el('textarea', { name: 'body', class: 'tall' });
	text.value = sub.wiki;
	const form = el('form', {}, el('div', { class: 'form-row' }, text),
		el('div', { class: 'button-row' }, el('button', { type: 'submit' }, 'save'),
			el('a', { class: 'button secondary', href: `/r/${sub.name}/wiki` }, 'cancel')));
	form.addEventListener('submit', async (e) => {
		e.preventDefault();
		const saved = await api(`/api/r/${encodeURIComponent(sub.name)}/wiki`, { body: text.value });
		if (saved.success)
			location.href = `/r/${sub.name}/wiki`;
		else
			say('message', saved.message);
	});
	$('view').replaceChildren(box(header, form));
	sidebar(sub);
}

function showCreate() {
	retitle('create community');
	if (!s.can_admin) {
		say('message', 'only admins can create communities.');
		return;
	}
	const form = el('form', {},
		field('name (lowercase, alphanumeric + underscores)', el('input', { type: 'text', id: 'name', name: 'name', required: true, pattern: '[a-zA-Z0-9_]+', maxlength: 40 })),
		field('display title', el('input', { type: 'text', id: 'title', name: 'title', required: true, maxlength: 100 })),
		field('description', el('textarea', { id: 'description', name: 'description', maxlength: 500 })),
		el('button', { type: 'submit' }, 'create'));
	form.addEventListener('submit', async (e) => {
		e.preventDefault();
		const reply = await api('/api/r', Object.fromEntries(new FormData(form)));
		if (reply.success)
			location.href = `/r/${reply.name}/`;
		else
			say('message', reply.message);
	});
	$('view').replaceChildren(box('create a new community', form));
	sidebar(null);
}

// /r/, /r/create, /r/<name>/, /r/<name>/submit, /r/<name>/comments/<id>/, /r/<name>/wiki
function route() {
	const path = location.pathname;
	const parts = path.split('/').filter(Boolean).slice(1).map(decodeURIComponent);
	if (parts.length === 0)
		return showList();
	if (parts.length === 1 && parts[0] === 'create' && !path.endsWith('/'))
		return showCreate();
	const [name, what, id] = parts;
	if (what === 'submit')
		return showSubmit(name);
	if (what === 'wiki')
		return showWiki(name);
	if (what === 'comments' && id)
		return showPost(name, id);
	return showBoard(name);
}

s = await frame('', 'communities');
product = document.title;
boards = (await api('/api/r')).subreddits || [];
await route();

// The login form; an account with 2FA continues on /login/2fa.
import { $, api, formData, frame, identity, nextPath, say } from './common.js';

const s = await frame('login');
if (s.user)
	location.replace(nextPath());
$('guest').hidden = !(await identity()).enable_guest;

$('login').addEventListener('submit', async (e) => {
	e.preventDefault();
	const reply = await api('/api/login', formData(e.target));
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	if (reply.next === '2fa')
		location.href = '/login/2fa' + location.search;
	else
		location.href = nextPath();
});

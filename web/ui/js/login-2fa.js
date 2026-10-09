// The second login step: a TOTP or backup code for the account whose password was accepted.
import { $, api, formData, frame, nextPath, say } from './common.js';

const s = await frame('two-factor');
if (!s.pending_2fa_user)
	location.replace('/login' + location.search);
$('who').textContent = s.pending_2fa_user || '';

$('verify').addEventListener('submit', async (e) => {
	e.preventDefault();
	const reply = await api('/api/login/2fa', formData(e.target));
	if (reply.success) {
		location.href = nextPath();
		return;
	}
	const now = await api('/api/session');
	if (!now.pending_2fa_user)
		location.href = '/login' + location.search;
	else
		say('message', reply.message);
});

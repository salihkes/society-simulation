// Registration: through an invite link, the dev passphrase, or open registration when it is on.
import { $, api, formData, frame, say } from './common.js';

const INVITE_PROBLEMS = {
	expired: 'ask for a fresh one.',
	exhausted: 'it has already been used the maximum number of times.',
	revoked: 'the inviter cancelled it.',
	inviter_banned: 'the inviter has been banned.',
	unknown: 'double-check the link you opened.',
};

const s = await frame('register');
if (s.user)
	location.replace('/');
const invite = new URLSearchParams(location.search).get('invite') || '';
const info = await api('/api/register?invite=' + encodeURIComponent(invite));

if (invite && info.invite_path_ok) {
	say('invite', `you were invited by ${info.inviter}. your account will be linked to theirs in the invite chain.`, 'info');
} else if (invite) {
	const status = info.invite_status || 'unknown';
	say('invite', `this invite is ${status} — ${INVITE_PROBLEMS[status] || ''}`);
} else if (!info.open_path_ok && !info.has_dev_passphrase) {
	say('invite', 'registration is invite-only. ask an existing user to send you an invite link and open it on this device.', 'warn');
}
$('register').hidden = !(info.invite_path_ok || info.open_path_ok || info.has_dev_passphrase);
$('dev').hidden = !(info.has_dev_passphrase && !info.invite_path_ok);

$('register').addEventListener('submit', async (e) => {
	e.preventDefault();
	const reply = await api('/api/register', { ...formData(e.target), invite });
	if (reply.success)
		location.href = '/';
	else
		say('message', reply.message);
});

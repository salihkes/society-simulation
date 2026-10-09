// The account page: links to the decal, 2FA, invite and admin pages.
import { $, api, frameForUser } from './common.js';

const s = await frameForUser('settings');
if (s) {
	$('who').textContent = s.user;
	$('invites').hidden = !s.can_invite;
	$('admin').hidden = !s.can_admin;
	const twofa = await api('/api/settings/2fa');
	$('twofa').textContent = twofa.has_totp ? 'on' : 'off';
}

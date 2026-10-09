// Two-factor settings: status, enrollment (scan, confirm, backup codes) and disabling.
import { $, api, el, formData, frameForUser, say } from './common.js';

function showOnly(id) {
	for (const section of ['enabled', 'disabled', 'enroll', 'codes'])
		$(section).hidden = section !== id;
}

async function showStatus() {
	const status = await api('/api/settings/2fa');
	$('remaining').textContent = `${status.backup_remaining} / ${status.backup_total}`;
	showOnly(status.has_totp ? 'enabled' : 'disabled');
	if (!status.has_totp && !status.totp_available) {
		$('start').disabled = true;
		say('message', 'two-factor authentication is unavailable: the server has no pyotp package.', 'warn');
	}
}

async function startEnroll() {
	const reply = await api('/api/settings/2fa/enroll', {});
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	say('message', '');
	$('secret').textContent = reply.secret;
	$('account').textContent = reply.account;
	$('uri').textContent = reply.provisioning_uri;
	// The SVG is drawn by the server's qrcode package from the provisioning URI.
	if (reply.qr_svg)
		$('qr').innerHTML = reply.qr_svg;
	else
		$('qr').replaceChildren(el('p', { class: 'muted' }, 'no QR code: the server has no qrcode package. use the manual key.'));
	showOnly('enroll');
}

async function confirmEnroll(e) {
	e.preventDefault();
	const reply = await api('/api/settings/2fa/confirm', formData(e.target));
	if (!reply.success) {
		say('message', reply.message);
		return;
	}
	say('message', '');
	$('code-list').replaceChildren(...reply.codes.map((c) => el('div', {}, c)));
	showOnly('codes');
}

async function disable(e) {
	e.preventDefault();
	if (!confirm('disable 2FA? your backup codes stop working too.'))
		return;
	const reply = await api('/api/settings/2fa/disable', formData(e.target));
	say('message', reply.success ? '2FA disabled.' : reply.message, reply.success ? 'info' : 'error');
	e.target.reset();
	if (reply.success)
		showStatus();
}

if (await frameForUser('two-factor authentication')) {
	$('start').addEventListener('click', startEnroll);
	$('confirm').addEventListener('submit', confirmEnroll);
	$('disable').addEventListener('submit', disable);
	await showStatus();
}

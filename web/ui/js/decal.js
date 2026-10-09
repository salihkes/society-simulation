// Decal upload: checks the file here first, then posts it to /api/upload-decal.
import { $, api, frameForUser, say } from './common.js';

const MAX_BYTES = 5 * 1024 * 1024;

function pick() {
	const file = $('file').files[0];
	$('preview').hidden = true;
	if (!file)
		return;
	if (file.type !== 'image/png' || file.size > MAX_BYTES) {
		say('message', file.type !== 'image/png' ? 'Please select a PNG image file.' : 'File is too large. Maximum size is 5MB.');
		$('file').value = '';
		return;
	}
	say('message', '');
	$('preview').src = URL.createObjectURL(file);
	$('preview').hidden = false;
}

async function send(e) {
	e.preventDefault();
	$('send').disabled = true;
	say('message', 'uploading…', 'info');
	const reply = await api('/api/upload-decal', new FormData(e.target));
	$('send').disabled = false;
	if (!reply.success) {
		say('message', reply.message || 'Failed to upload decal.');
		return;
	}
	say('message', reply.message || 'Decal uploaded.', 'info');
	e.target.reset();
	$('preview').hidden = true;
}

const s = await frameForUser('character decal');
if (s) {
	$('name-humanoid').textContent = `${s.user}.png`;
	$('name-countryball').textContent = `${s.user}_countryball.png`;
	$('file').addEventListener('change', pick);
	$('upload').addEventListener('submit', send);
}

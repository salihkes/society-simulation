// The landing page: play with an account, play as a guest, or log in first.
import { $, frame, identity } from './common.js';

const s = await frame('', 'home');
const id = await identity();
$('guest').hidden = !id.enable_guest;
if (!s.user) {
	$('play').href = '/login?next=' + encodeURIComponent('/play/');
	$('signed-out').hidden = false;
}

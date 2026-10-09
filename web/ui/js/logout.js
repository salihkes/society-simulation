// Ends the session, then shows the login page.
import { api } from './common.js';

await api('/api/logout', {});
location.replace('/login');

export const domains = Object.freeze({claude: ['claude.ai'], codex: ['chatgpt.com', 'auth.openai.com'], grok: ['grok.com', 'auth.x.ai']});
export const DEFAULT_STORE = typeof browser !== 'undefined' && typeof browser.runtime?.getBrowserInfo === 'function' ? 'firefox-default' : '0';
export function allowedHost(provider, host) {
  return Object.hasOwn(domains, provider) && typeof host === 'string' && domains[provider].some(root => host === root || (!root.startsWith('auth.') && host.endsWith('.' + root)));
}
export function validateCookies(provider, cookies, now = Date.now() / 1000, store = DEFAULT_STORE) {
  if (!['0', 'firefox-default'].includes(store)) throw Error('Unsupported cookie store');
  if (!Object.hasOwn(domains, provider) || !Array.isArray(cookies) || !cookies.length || cookies.length > 500) throw Error('Invalid session');
  const keys = new Set();
  for (const c of cookies) {
    if (!c || typeof c !== 'object' || typeof c.domain !== 'string' || !/^\.?[a-z0-9.-]+$/.test(c.domain) || !allowedHost(provider, c.domain.replace(/^\./, '')) ||
      typeof c.name !== 'string' || !c.name.length || /[\x00-\x20\x7f;,=]/.test(c.name) || typeof c.value !== 'string' || /[\x00-\x1f\x7f]/.test(c.value) || c.value.length > 65536 ||
      typeof c.path !== 'string' || !c.path.startsWith('/') || /[\x00-\x20\x7f?#]/.test(c.path) ||
      typeof c.hostOnly !== 'boolean' || typeof c.secure !== 'boolean' || typeof c.httpOnly !== 'boolean' || typeof c.session !== 'boolean' ||
      !['no_restriction', 'lax', 'strict', 'unspecified'].includes(c.sameSite) || c.storeId !== store || c.partitionKey != null || (c.firstPartyDomain != null && c.firstPartyDomain !== '') ||
      (!c.session && (!Number.isFinite(c.expirationDate) || c.expirationDate <= now)) ||
      (c.hostOnly && c.domain.startsWith('.'))) throw Error('Unsupported or expired session');
    const key = `${c.domain}|${c.path}|${c.name}`;
    if (keys.has(key)) throw Error('Duplicate cookie');
    keys.add(key);
  }
  return cookies;
}
export function cookieURL(c) { return `https://${c.domain.replace(/^\./, '')}${c.path}`; }
export function cookieDetails(c) {
  const d = {url: cookieURL(c), name: c.name, value: c.value, path: c.path, secure: c.secure, httpOnly: c.httpOnly, sameSite: c.sameSite, storeId: c.storeId};
  if (!c.hostOnly) d.domain = c.domain;
  if (!c.session) d.expirationDate = c.expirationDate;
  return d;
}
export async function readCookies(api, provider, store = DEFAULT_STORE) {
  if (!domains[provider]) throw Error('Unsupported provider');
  if (!['0', 'firefox-default'].includes(store)) throw Error('Unsupported cookie store');
  const all = await api.getAll({storeId: store});
  const selected = all.filter(c => allowedHost(provider, c.domain.replace(/^\./, '')));
  if (selected.some(c => c.storeId !== store || c.partitionKey != null || (c.firstPartyDomain != null && c.firstPartyDomain !== ''))) throw Error('Partitioned sessions unsupported');
  return selected;
}
async function replace(api, provider, target, store) {
  for (const c of await readCookies(api, provider, store)) {
    const result = await api.remove({url: cookieURL(c), name: c.name, storeId: store});
    if (!result) throw Error('Cookie removal failed');
  }
  for (const c of target) {
    if (!await api.set(cookieDetails(c))) throw Error('Cookie write failed');
  }
  const actual = await readCookies(api, provider, store);
  const normalize = cookies => cookies.map(c => JSON.stringify([c.domain.replace(/^\./, ''), c.hostOnly, c.name, c.value, c.path, c.secure, c.httpOnly, c.sameSite, c.session, c.session ? null : Math.floor(c.expirationDate)])).sort();
  if (JSON.stringify(normalize(actual)) !== JSON.stringify(normalize(target))) throw Error('Cookie verification failed');
}
export async function applySession(api, provider, target, store = DEFAULT_STORE) {
  validateCookies(provider, target, Date.now() / 1000, store);
  const previous = await readCookies(api, provider, store);
  if (previous.length) validateCookies(provider, previous, Date.now() / 1000, store);
  try { await replace(api, provider, target, store); }
  catch {
    try { await replace(api, provider, previous, store); }
    catch { throw Error('Session failed; rollback failed. Sign in manually.'); }
    throw Error('Session failed; previous cookies restored.');
  }
}

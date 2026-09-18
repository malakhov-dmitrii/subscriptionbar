import test from 'node:test';
import assert from 'node:assert/strict';
import {validateCookies, cookieDetails, applySession, allowedHost} from './cookies.mjs';
const cookie = (value = 'old') => ({domain: '.claude.ai', hostOnly: false, name: 'sessionKey', value, path: '/', secure: true, httpOnly: true, session: false, sameSite: 'lax', storeId: '0', expirationDate: Date.now() / 1000 + 3600});
test('rejects unrelated hosts, ambiguous stores, partitions, and expired sessions', () => {
  for (const patch of [{domain: '.evilclaude.ai'}, {domain: '.openai.com'}, {storeId: '1'}, {partitionKey: {topLevelSite: 'https://claude.ai'}}, {expirationDate: 1}, {name: 'bad\nname'}, {path: '/?evil'}]) assert.throws(() => validateCookies('claude', [{...cookie(), ...patch}]));
  assert.equal(allowedHost('codex', 'auth.openai.com'), true);
  assert.equal(allowedHost('codex', 'other.auth.openai.com'), false);
  assert.equal(allowedHost('grok', 'x.com'), false);
});
test('host-only and persistent cookie attributes survive mapping', () => {
  const c = {...cookie(), domain: 'claude.ai', hostOnly: true};
  const details = cookieDetails(c);
  assert.equal(details.domain, undefined); assert.equal(details.expirationDate, c.expirationDate); assert.equal(details.httpOnly, true);
});
function fakeAPI(initial, failValue) {
  let state = structuredClone(initial), mutations = 0;
  return {getAll: async () => structuredClone(state), remove: async ({name}) => { mutations++; state = state.filter(c => c.name !== name); return {}; }, set: async d => {
    mutations++; if (d.value === failValue) throw Error('write failed');
    const c = {...d, domain: d.domain || new URL(d.url).hostname, hostOnly: !d.domain, session: d.expirationDate === undefined}; delete c.url; state.push(c); return c;
  }, state: () => state, mutations: () => mutations};
}
test('expired target fails before changing current session', async () => {
  const api = fakeAPI([cookie()]);
  await assert.rejects(applySession(api, 'claude', [{...cookie('new'), expirationDate: 1}]));
  assert.equal(api.mutations(), 0);
});
test('successful transaction writes and verifies target', async () => {
  const api = fakeAPI([cookie()]); await applySession(api, 'claude', [cookie('new')]); assert.equal(api.state()[0].value, 'new');
});
test('failed target write restores previous session', async () => {
  const api = fakeAPI([cookie()], 'new');
  await assert.rejects(applySession(api, 'claude', [cookie('new')]), /previous cookies restored/);
  assert.equal(api.state()[0].value, 'old');
});
test('failed rollback is explicit', async () => {
  const api = fakeAPI([cookie()]); api.set = async () => { throw Error('blocked'); };
  await assert.rejects(applySession(api, 'claude', [cookie('new')]), /rollback failed/);
});

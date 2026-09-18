import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {validateCookies, applySession} from './cookies.mjs';
const cookie = value => ({domain: '.claude.ai', hostOnly: false, name: 'sessionKey', value, path: '/', secure: true, httpOnly: true, session: true, sameSite: 'lax', storeId: 'firefox-default', firstPartyDomain: ''});
test('Firefox API detection selects the regular store without examining user containers', async () => {
  const previous = globalThis.browser;
  try {
    globalThis.browser = {runtime: {getBrowserInfo() {}}};
    const firefox = await import('./cookies.mjs?firefox-platform-test');
    assert.equal(firefox.DEFAULT_STORE, 'firefox-default');
    assert.doesNotThrow(() => firefox.validateCookies('claude', [cookie('test')]));
  } finally {
    if (previous === undefined) delete globalThis.browser;
    else globalThis.browser = previous;
  }
});
test('Firefox default store accepted only when explicitly selected; containers and private stores rejected', () => {
  assert.doesNotThrow(() => validateCookies('claude', [cookie('test')], Date.now() / 1000, 'firefox-default'));
  assert.throws(() => validateCookies('claude', [cookie('test')]));
  for (const changes of [{storeId: 'firefox-private'}, {storeId: 'firefox-container-1'}, {storeId: '0'}, {firstPartyDomain: 'claude.ai'}, {partitionKey: {topLevelSite: 'https://claude.ai'}}]) {
    assert.throws(() => validateCookies('claude', [{...cookie('test'), ...changes}], Date.now() / 1000, 'firefox-default'));
  }
});
test('Firefox transaction uses only default store for reads, removal and replacement', async () => {
  let state = [cookie('old')];
  const api = {
    getAll: async options => { assert.equal(options.storeId, 'firefox-default'); return structuredClone(state); },
    remove: async options => { assert.equal(options.storeId, 'firefox-default'); state = []; return {}; },
    set: async options => { assert.equal(options.storeId, 'firefox-default'); const c = {...cookie(options.value), ...options}; delete c.url; state.push(c); return c; }
  };
  await applySession(api, 'claude', [cookie('new')], 'firefox-default');
  assert.equal(state[0].value, 'new');
});
test('Firefox artifact has matching host ID, script background, and deterministic shared code', () => {
  const root = new URL('./', import.meta.url);
  const generated = new URL('firefox/background.js', root);
  const before = readFileSync(generated, 'utf8');
  execFileSync(process.execPath, [new URL('build-firefox.mjs', root).pathname]);
  assert.equal(readFileSync(generated, 'utf8'), before);
  const manifest = JSON.parse(readFileSync(new URL('firefox/manifest.json', root)));
  assert.equal(manifest.browser_specific_settings.gecko.id, 'subscriptionbar@local.example');
  assert.deepEqual(manifest.background, {scripts: ['background.js']});
  assert.equal(manifest.key, undefined);
  assert.equal(manifest.incognito, 'not_allowed');
  assert.equal(/^import |^export /m.test(before), false);
  assert.equal(/\bchrome\./.test(before), false);
  const installer = readFileSync(new URL('../scripts/install-browser-host.command', root), 'utf8');
  assert.ok(installer.includes("['subscriptionbar@local.example']"));
  assert.ok(installer.includes('Mozilla/NativeMessagingHosts/com.local.subscriptionbar.json'));
});

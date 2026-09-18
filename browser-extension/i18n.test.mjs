import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {messages, languageFor, translate, stateFor, siteFor} from './i18n.js';

test('Russian and English have complete matching catalogs and safe locale fallback', () => {
 assert.deepEqual(Object.keys(messages.ru).sort(), Object.keys(messages.en).sort());
 for (const catalog of Object.values(messages)) for (const value of Object.values(catalog)) assert.ok(value.trim());
 assert.equal(languageFor('ru-RU'), 'ru');
 assert.equal(languageFor('en-US'), 'en');
 assert.equal(languageFor('de'), 'en');
 assert.equal(languageFor(null), 'en');
 assert.equal(translate('ru', 'Connected'), 'Подключено');
 assert.equal(translate('en', 'Connected'), 'Connected');
 // An unmapped status is still information from the app; replacing it with a
 // generic failure used to turn successes into errors.
 assert.equal(translate('ru', 'untrusted server text'), 'untrusted server text');
 assert.equal(translate('ru', undefined), '');
});

test('status severity never reports an unknown status as a failure', () => {
 assert.equal(stateFor('Connected'), 'ok');
 assert.equal(stateFor('Website cookies applied; server account not verified'), 'ok');
 assert.equal(stateFor('SubscriptionBar timed out'), 'error');
 assert.equal(stateFor('Capture failed'), 'error');
 assert.equal(stateFor('connecting'), 'warn');
 assert.equal(stateFor('a status from a newer app'), 'warn');
 assert.equal(siteFor('codex'), 'chatgpt.com');
 assert.equal(siteFor('mystery'), 'mystery');
});

test('all status messages shown by background or popup have translations', () => {
 const background = readFileSync(new URL('background.js', import.meta.url), 'utf8');
 const popup = readFileSync(new URL('popup.js', import.meta.url), 'utf8');
 const keys = [...background.matchAll(/\bstatus\s*[:=]\s*'([^']+)'/g), ...popup.matchAll(/setStatus\('([^']+)'\)/g)].map(match => match[1]);
 keys.push('Session could not be applied', 'Session failed; rollback failed. Sign in manually.');
 for (const key of keys) for (const catalog of Object.values(messages)) assert.ok(Object.hasOwn(catalog, key), key);
 const html = readFileSync(new URL('popup.html', import.meta.url), 'utf8');
 for (const [, key] of html.matchAll(/data-i18n="([^"]+)"/g)) assert.ok(Object.hasOwn(messages.en, key), key);
 assert.match(html, /type="module" src="popup.js"/);
 assert.match(popup, /storage\.local\.set\(\{language\}\)/);
});

test('Firefox ships identical catalogs and localized popup', () => {
 for (const name of ['i18n.js', 'popup.html']) {
  assert.equal(readFileSync(new URL(`firefox/${name}`, import.meta.url), 'utf8'), readFileSync(new URL(name, import.meta.url), 'utf8'));
 }
 const popup = readFileSync(new URL('firefox/popup.js', import.meta.url), 'utf8');
 assert.match(popup, /import .* from '.\/i18n.js'/);
 assert.equal(/\bchrome\./.test(popup), false);
});

test('extension metadata is localized in both browser packages', () => {
 for (const prefix of ['', 'firefox/']) {
  const manifest = JSON.parse(readFileSync(new URL(`${prefix}manifest.json`, import.meta.url), 'utf8'));
  assert.equal(manifest.default_locale, 'en');
  for (const locale of ['ru', 'en']) {
   const catalog = JSON.parse(readFileSync(new URL(`${prefix}_locales/${locale}/messages.json`, import.meta.url), 'utf8'));
   for (const field of ['name', 'description']) {
    const key = manifest[field].match(/^__MSG_(.+)__$/)?.[1];
    assert.ok(key && catalog[key]?.message, `${prefix}${locale}:${field}`);
   }
  }
 }
});

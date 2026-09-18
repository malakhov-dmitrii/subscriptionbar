import {languageFor, translate, stateFor, siteFor} from './i18n.js';
const select = document.querySelector('#account');
const status = document.querySelector('#status');
const statusText = document.querySelector('#statusText');
const site = document.querySelector('#site');
const button = document.querySelector('#capture');
const languageSelect = document.querySelector('#language');
let language = languageFor(navigator.language), statusKey = 'connecting', busy = false, ready = false;

function render() {
 document.documentElement.lang = language;
 languageSelect.value = language;
 for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = translate(language, element.dataset.i18n);
 statusText.textContent = translate(language, statusKey);
 status.dataset.state = stateFor(statusKey);
 const selected = select.selectedOptions[0];
 const provider = selected?.dataset.provider;
 site.textContent = provider ? translate(language, 'appliesTo').replace('%s', siteFor(provider)) : '';
 button.textContent = translate(language, busy ? 'capturing' : 'capture');
 button.disabled = busy || !ready;
}
function setStatus(key) { statusKey = key; render(); }
render();

browser.storage.local.get('language').then(stored => {
 if (stored.language) language = languageFor(stored.language);
 render();
}).catch(() => {});

languageSelect.addEventListener('change', async () => {
 language = languageFor(languageSelect.value);
 render();
 try { await browser.storage.local.set({language}); } catch { /* preference only */ }
});

select.addEventListener('change', render);

browser.runtime.sendMessage({op: 'status'}).then(result => {
 for (const account of result.accounts) {
  const option = document.createElement('option');
  option.value = account.id;
  option.dataset.provider = account.provider;
  option.textContent = `${account.provider} — ${account.label}`;
  select.append(option);
 }
 ready = select.options.length > 0;
 if (!ready) {
  // An empty dropdown with a dead button explains nothing; name the missing step.
  // A disabled sole option renders as a blank box; leave it selectable so the
  // reason is visible. The button stays disabled either way.
  const option = document.createElement('option');
  option.textContent = translate(language, 'noAccounts');
  select.append(option);
  setStatus('noAccountsStatus');
  return;
 }
 setStatus(result.status);
}).catch(() => { ready = false; setStatus('companionUnavailable'); });

button.addEventListener('click', async () => {
 busy = true; setStatus('capturing');
 try { const result = await browser.runtime.sendMessage({op: 'capture', accountID: select.value}); busy = false; setStatus(result.status); }
 catch { busy = false; setStatus('captureUnavailable'); }
});

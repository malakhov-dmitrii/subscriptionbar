import {domains, allowedHost, readCookies, validateCookies, applySession} from './cookies.mjs';
const HOST = 'com.local.subscriptionbar';
let port, instanceID, accounts = [], status = 'Connecting to SubscriptionBar…', polling = false;
let queue = Promise.resolve();
const requests = new Map(), processing = new Set();
function serialize(fn) { const next = queue.then(fn); queue = next.catch(() => {}); return next; }
function rpc(payload) {
  if (!port) return Promise.reject(Error('SubscriptionBar is unavailable'));
  const requestID = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { requests.delete(requestID); reject(Error('SubscriptionBar timed out')); }, 15000);
    requests.set(requestID, {resolve, reject, timer});
    port.postMessage({...payload, browserInstanceID: instanceID, requestID});
  });
}
function validAccount(a) { return a && typeof a.id === 'string' && a.id.length > 0 && a.id.length < 200 && typeof a.label === 'string' && a.label.length < 300 && Object.hasOwn(domains, a.provider); }
async function poll() {
  if (polling || !port) return;
  polling = true;
  try {
    const response = await rpc({op: 'hello'});
    if (response.ok !== true || !Array.isArray(response.accounts) || !response.accounts.every(validAccount) || !Array.isArray(response.pending)) throw Error('Invalid host response');
    accounts = response.accounts;
    if (status.startsWith('Connecting') || status.startsWith('SubscriptionBar')) status = 'Connected';
    for (const command of response.pending) {
      if (!command || command.op !== 'activate' || typeof command.id !== 'string' || command.id.length > 200 || !accounts.some(a => a.id === command.accountID && a.provider === command.provider) || processing.has(command.id)) continue;
      processing.add(command.id);
      serialize(async () => {
        const {completed = [], lastResult, receipts = []} = await chrome.storage.local.get(['completed', 'lastResult', 'receipts']);
        const receipt = receipts.find(r => r.commandID === command.id);
        if (receipt) { await rpc({op: 'result', ...receipt}); return; }
        if (lastResult?.commandID === command.id) { await rpc({op: 'result', ...lastResult}); return; }
        if (completed.includes(command.id)) { await rpc({op: 'result', commandID: command.id, ok: true}); return; }
        let ok = false, error;
        try {
          const result = await rpc({op: 'load', accountID: command.accountID, provider: command.provider, commandID: command.id});
          if (result.ok !== true) throw Error('Session unavailable');
          validateCookies(command.provider, result.cookies);
          const {activeAccounts = {}} = await chrome.storage.local.get('activeAccounts');
          // The user pairs captures with account labels. Active metadata cannot prove
          // website identity after manual login, so never auto-save outgoing cookies.
          // A process crash after this receipt must never replay the mutation automatically.
          await chrome.storage.local.set({receipts: [...receipts, {commandID: command.id, ok: false, error: 'Session transaction interrupted; inspect browser sign-in'}].slice(-1000)});
          await applySession(chrome.cookies, command.provider, result.cookies);
          await chrome.storage.local.set({activeAccounts: {...activeAccounts, [command.provider]: command.accountID}});
          await chrome.storage.local.set({completed: [...completed, command.id].slice(-1000)});
          ok = true;
          status = 'Website cookies applied; server account not verified';
          const tabs = await chrome.tabs.query({});
          for (const tab of tabs) {
            if (tab.incognito || !tab.url || tab.id === undefined) continue;
            const url = new URL(tab.url);
            if (url.protocol === 'https:' && allowedHost(command.provider, url.hostname)) await chrome.tabs.reload(tab.id).catch(() => {});
          }
        } catch (e) { error = e.message.includes('rollback') ? e.message : 'Session could not be applied'; status = error; }
        // Persist failed results as well: retries must never silently repeat a destructive switch.
        const savedResult = {commandID: command.id, ok, ...(error ? {error} : {})};
        await chrome.storage.local.set({lastResult: savedResult, receipts: [...receipts.filter(r => r.commandID !== command.id), savedResult].slice(-1000)});
        await rpc({op: 'result', commandID: command.id, ok, ...(error ? {error} : {})});
      }).catch(() => { status = 'SubscriptionBar disconnected; result pending'; }).finally(() => processing.delete(command.id));
    }
  } catch { status = 'SubscriptionBar unavailable or incompatible'; }
  finally { polling = false; }
}
async function connect() {
  if (port) return;
  const stored = await chrome.storage.local.get('browserInstanceID');
  instanceID = stored.browserInstanceID || crypto.randomUUID();
  await chrome.storage.local.set({browserInstanceID: instanceID});
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener(message => {
    if (!message || typeof message.requestID !== 'string') return;
    const request = requests.get(message.requestID);
    if (!request) return;
    clearTimeout(request.timer); requests.delete(message.requestID); request.resolve(message);
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = undefined; status = 'SubscriptionBar disconnected';
    for (const request of requests.values()) { clearTimeout(request.timer); request.reject(Error('Disconnected')); }
    requests.clear();
  });
  const {lastResult} = await chrome.storage.local.get('lastResult');
  if (lastResult) await rpc({op: 'result', ...lastResult}).catch(() => {});
  await poll();
}
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id) return;
  if (message?.op === 'status') { reply({accounts, status}); return; }
  if (message?.op !== 'capture') return;
  serialize(async () => {
    const account = accounts.find(a => a.id === message.accountID);
    if (!account) throw Error('Select an account');
    const cookies = validateCookies(account.provider, await readCookies(chrome.cookies, account.provider));
    const result = await rpc({op: 'capture', accountID: account.id, provider: account.provider, cookies});
    if (result.ok !== true) throw Error('Capture failed');
    const {activeAccounts = {}} = await chrome.storage.local.get('activeAccounts');
    await chrome.storage.local.set({activeAccounts: {...activeAccounts, [account.provider]: account.id}});
    status = 'Website cookies saved; confirm this is the selected account';
    return {ok: true, status};
  }).then(reply, () => reply({ok: false, status: 'Capture failed. Check the app and sign into the selected website account.'}));
  return true;
});
chrome.alarms.create('reconnect', {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener(() => { if (!port) connect().catch(() => {}); else poll(); });
setInterval(poll, 5000);
connect().catch(() => { status = 'SubscriptionBar unavailable'; });

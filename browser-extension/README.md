# SubscriptionBar browser companion

Local MV3 extension for Chrome, Edge, and Brave. Load this directory unpacked using the browser's Extensions page with Developer mode enabled. Install the native messaging host through the Mac application first. Safari is not supported by this build.

Firefox Developer Edition: a generated companion is staged in `firefox/`. Open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select `firefox/manifest.json`. This is a temporary unsigned development add-on, removed when Firefox restarts. Its ID is `subscriptionbar@local.example`; the native installer supplies `allowed_extensions` under `Mozilla/NativeMessagingHosts`. Firefox MV3 uses a script background, generated from the shared code with `node build-firefox.mjs`. Automated tests cover generation and cookie-store behavior; live Firefox/native-host compatibility remains unverified. Grant the listed website permissions explicitly in Firefox before capture.

Stable extension ID: `bcagcmegeimpjhbkgfmeapjmkfmljlch`. Native host `allowed_origins` must include `chrome-extension://bcagcmegeimpjhbkgfmeapjmkfmljlch/`. The manifest contains only the public RSA key; no private key is retained.

Permissions: cookies and HTTPS access only to Claude, ChatGPT and Grok domains declared in the manifest; native messaging to `com.local.subscriptionbar`; local storage for browser ID and command receipts; alarms for reconnection. The extension never writes cookies, tokens or credentials to extension storage or logs. Captured cookie values travel to the local native host, which must store them securely. Only the regular default cookie store is supported: `0` on Chromium and `firefox-default` on Firefox. Incognito and partitioned cookies are rejected.

Create accounts in the Mac app. In each browser profile, sign into a website, select the matching account in the extension popup, and click **Capture current website session**. This labels the current cookies; it does not verify the server-side account identity. Repeat for each account. The native app requests automatic switches. After a verified cookie write, matching website tabs reload; failed writes attempt to restore the previous cookies. Local storage and other website state are not migrated, so services depending on additional browser state may require manual sign-in.

## Native protocol

Session snapshots are not automatically refreshed. If a saved session expires or its tokens rotate, sign into that account and capture again. Account pairing is the user's explicit choice; the extension cannot prove which server account owns captured cookies. It never saves outgoing cookies automatically because a manual website login may have changed the account.

Browser switching covers only browser profiles that have explicitly captured the target account. All those profiles must be connected before a switch starts. Unpaired profiles are outside this switch. The host stops accepting new session loads after a terminal result or timeout; an already running cookie transaction can still finish, so timeout is reported as an unknown outcome.

The extension maintains a `connectNative('com.local.subscriptionbar')` port. Every request carries `requestID` (UUID) and `browserInstanceID` (stable UUID per browser profile). Every response must echo `requestID`. Requests expire after 15 seconds. No unsolicited host commands are accepted. The native host uses standard Chrome native-messaging framing (four-byte little-endian byte length, UTF-8 JSON).

- `hello` every five seconds: `{op:'hello',requestID,browserInstanceID}` → `{requestID,ok:true,accounts:[{id,label,provider}],pending:[{id,accountID,provider,op:'activate'}]}`.
- `capture`: `{op:'capture',requestID,browserInstanceID,accountID,provider,cookies:[ChromeCookie]}` → `{requestID,ok:true}`.
- `load`: `{op:'load',requestID,browserInstanceID,accountID,provider,commandID}` → `{requestID,ok:true,cookies:[ChromeCookie]}`.
- `result`: `{op:'result',requestID,browserInstanceID,commandID,ok,error?}` → `{requestID,ok:true}`. Errors contain generic messages, never cookie values.

Providers are `claude`, `codex`, and `grok`. Hosts: `claude.ai` and subdomains; `chatgpt.com` and subdomains plus exact `auth.openai.com`; `grok.com` and subdomains plus exact `auth.x.ai`. Host responses must provide full Chrome cookie objects including the platform's default `storeId` (`0` or `firefox-default`), `hostOnly`, `session`, `sameSite`, and expiration for persistent cookies. All target cookies must be unexpired before the first mutation. The host must durably acknowledge results and remove completed commands. Results prove cookie application only, not server authentication or account identity. Restarts during a transaction may require manual recovery; cross-process atomic browser cookie transactions are unavailable.

Run verification with `node --test cookies.test.mjs`. Live browser/native host integration must be checked separately before enabling automatic switching.

For Firefox run `node --test cookies.test.mjs firefox.test.mjs`. Runtime detection selects Firefox's regular `firefox-default` store or Chromium's regular `0` store; no container or private store is selected. Mixed stores, partitioned cookies and nonempty first-party domains are rejected. Existing Chromium account captures cannot be replayed into Firefox.

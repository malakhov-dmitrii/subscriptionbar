# Security

SubscriptionBar copies and rewrites the sign-in credentials of other clients on
your Mac. That is its whole job, so the handling is documented rather than
assumed.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/malakhov-dmitrii/subscriptionbar/security/advisories/new).
Please do not open a public issue for anything that exposes credentials.

There is no bounty. This is a personal tool released as-is under MIT.

## What the app touches

| Data | Where it lives | When it is read |
| --- | --- | --- |
| CLI credentials (`~/.claude`, `~/.codex`, `~/.grok`) | Left in place; a copy goes to Keychain | On capture, on switch, and to confirm the active account still matches |
| API keys and subscription keys | macOS Keychain, single record `vault-v1` | On each usage poll |
| Browser cookies for claude.ai / chatgpt.com / grok.com | macOS Keychain, via the companion extension | On capture and on switch |
| Settings and last-known readings | `~/Library/Application Support/SubscriptionBar` | On launch and on change |

## Guarantees

- **No server and no telemetry.** The app contacts each provider's own usage
  endpoint and nothing else. There is no analytics, crash reporting or update
  check.
- **Read-only usage requests.** Every provider request is a `GET` to a fixed
  HTTPS endpoint, with shared cookies and cache disabled and redirects refused.
  The app deliberately does not use Claude's one-token Messages workaround for
  usage, because that would consume your quota.
- **Tokens never reach logs.** Credentials and response bodies are excluded from
  error messages and receipts.
- **No automatic Keychain dialogs.** `kSecUseAuthenticationUI` is set to fail on
  launch. A system prompt only ever follows a button you pressed; background
  polling cannot raise one.
- **No password entry.** The app never asks for a subscription password. It
  copies credentials the client already wrote. API keys go into a secure field.
- **Fail closed.** Unreadable, malformed or stale data stops automation instead
  of being interpreted.

## Known limits

- Anything running as your user can read your Keychain after you unlock it. This
  app raises no privilege boundary that did not already exist.
- Applying saved cookies does not verify with the website server which account
  the session actually belongs to. The interface says so instead of claiming the
  switch succeeded.
- A CLI process already running may keep its previous sign-in in memory. The app
  does not force-kill processes to work around this.
- The Firefox companion is unsigned and installs out of band.

## Using several accounts

Rotating between multiple subscriptions of the same service may conflict with
that provider's terms of service. Check the terms for your own accounts. This
project takes no position on it and provides no way to share one subscription
between people.

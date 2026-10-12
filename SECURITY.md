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
| CLI credentials (`~/.claude`, configured Codex data folders, `~/.grok`) | Left in place; a copy goes to Keychain | On capture, on switch, and to reconcile configured client logins |
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
- **No automatic Keychain dialogs.** The main process disables legacy Keychain
  UI at launch; every background query also gets a fresh noninteractive
  `LAContext` plus macOS's per-query UI-fail flag. An **Allow access** click starts
  a short-lived copy of the signed executable whose only job is one interactive
  read. The main process then proves ordinary access with a noninteractive read
  of the same persistent item before polling resumes.
- **No password entry.** The app never asks for a subscription password. It
  copies credentials the client already wrote. API keys go into a secure field.
- **Fail closed.** Unreadable, malformed or stale data stops automation instead
  of being interpreted.
- Codex subject changes require matching nonempty `chatgpt_user_id` and
  `chatgpt_account_id` in both saved and current ID/access tokens. These decoded
  claims establish local continuity; the current bearer must also read usage
  successfully before the saved binding changes. Settings and the vault update
  use compare-and-swap checks and rollback. This recovery never writes client
  credentials, restarts Codex or rotates refresh tokens.
- Codex usage polling uses each saved account independently of the selected
  client. Each configured data home is observed separately. Missing, unknown or
  rejected source credentials cannot relabel a different saved account. Newer
  same-account credentials are checked with the provider before being saved;
  older source snapshots cannot downgrade the saved login.
- Codex profiles require distinct canonical data homes. Native switches match
  the selected application and observed process data home, then recheck before
  mutation. Ambiguous instances, shared storage and unsupported credential stores
  stop the operation. Other configured homes are not switch destinations.
- A target account already used by another configured Codex home cannot be
  copied into the selected home. Select the profile that owns that login.
  Selecting a profile preserves the current automatic-switch setting.
- With multiple Codex profiles, native switching does not apply browser cookies:
  browser sessions have no native-profile binding. The optional browser switch
  remains available for a single-profile configuration.
- A failed reconciliation reloads settings after a partial commit. Concurrent
  settings or vault changes prevent later profile writes from reusing an obsolete
  snapshot. The account list and selected profile are not replaced by source data.

- Explicit Codex reauthentication runs an owned native helper in a private
  temporary home, with file-backed auth and a saved-workspace restriction.
  Browser/device instructions come from correlated protocol responses. The
  helper must stop before its credential file is accepted and the folder is
  removed. Stable user/workspace continuity and fresh quota are checked before
  the existing UUID is updated through guarded settings/vault transactions.
  Cancellation remains available until the save/activation boundary; a saved
  login and a successful native activation are reported separately.
- Explicit Claude capture derives UUID, email and organization from the
  authenticated provider profile and rechecks the raw source before returning.
  Stale local metadata cannot relabel that token. This does not authorize
  silently rebinding a saved switch target to another provider identity.

## Known limits

- Anything running as your user can read your Keychain after you unlock it. This
  app raises no privilege boundary that did not already exist.
- Applying saved cookies does not verify with the website server which account
  the session actually belongs to. The interface says so instead of claiming the
  switch succeeded.
- Browser cookies do not renew native Codex OAuth credentials. Revocation or
  expiry can invalidate a saved login even when a browser session still works.
- Codex native switching supports file-backed `auth.json`, not explicit `keyring`, `auto` or
  `ephemeral` storage. Multi-instance isolation uses disposable test fixtures;
  live user-account switching and task resumption are not verified end to end.
- A CLI process already running may keep its previous sign-in in memory. The app
  does not force-kill processes to work around this.
- Claude Code can replace its Keychain item when it rotates credentials. That
  replacement may require one new explicit approval in SubscriptionBar. Recovery
  reads the item only; it never rewrites or replays the failed operation.
- The Firefox companion is unsigned and installs out of band.

## Using several accounts

Rotating between multiple subscriptions of the same service may conflict with
that provider's terms of service. Check the terms for your own accounts. This
project takes no position on it and provides no way to share one subscription
between people.

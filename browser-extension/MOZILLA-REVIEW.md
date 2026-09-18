# SubscriptionBar Firefox companion

Distribution: unlisted (On your own). This extension requires the separately installed SubscriptionBar macOS application and its native messaging host, `com.local.subscriptionbar`.

## Build

Use Node.js with no third-party packages:

```sh
node build-firefox.mjs
node --test *.test.mjs
```

Archive the contents of `firefox/` at the ZIP root, including `i18n.js` and the `_locales/` subdirectories. The build concatenates the shared cookie helpers and background code, removes module imports/exports, and adapts the browser API namespace. No minification or remote executable code is used.

## Behavior and review setup

Install the companion and the macOS application's native messaging host. The popup reports connection status and lists configured accounts. A user can explicitly save the current supported website session to a selected account. The native application can request activation of a saved session when account rotation is enabled. The extension replaces supported cookies, verifies the replacement, attempts rollback on failure, and reloads matching tabs. Private browsing, Firefox containers, and partitioned sessions are not supported.

The application is required to test the native messaging operations. Without it, the extension reports that SubscriptionBar is unavailable. No reviewer credentials are included.

## Privacy disclosure

The extension reads and changes cookies for Claude, ChatGPT and Grok and their specified authentication domains. These cookies can authenticate an account. Cookie snapshots are sent through native messaging to the locally installed SubscriptionBar application for storage in macOS Keychain and are returned when activating an account. Account labels, provider identifiers, browser instance identifiers, and operation receipts are used to coordinate the local extension and application. Extension storage retains coordination metadata and receipts.

SubscriptionBar uses account credentials to make authenticated usage requests to the corresponding original service providers. Activated cookies are used by the browser with those providers in normal website requests. The extension does not send cookies to Mozilla, the SubscriptionBar developer, or an analytics service, and does not collect browsing history or page bodies. Mozilla receives the extension package and review materials for signing. These packages contain source code, not user accounts, cookies, or API keys.

Removing the extension removes its browser integration; saved credentials in the native application's Keychain vault are managed separately by SubscriptionBar.

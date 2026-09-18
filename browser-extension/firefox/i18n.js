export const messages = {
  "en": {
    "language": "Language",
    "account": "SubscriptionBar account",
    "appliesTo": "Saves the session for %s.",
    "captureHelp": "Sign into the selected account on its website before saving the session.",
    "capture": "Save website session",
    "capturing": "Saving…",
    "autoHelp": "Automatic switching requires browser switching to be enabled for this account in SubscriptionBar.",
    "connecting": "Connecting…",
    "companionUnavailable": "SubscriptionBar is not responding. Open the app, then reopen this popup.",
    "captureUnavailable": "Could not reach SubscriptionBar. Open the app and try again.",
    "noAccounts": "No accounts yet",
    "noAccountsStatus": "Connect an account in SubscriptionBar first.",
    "Connected": "Connected",
    "Connecting to SubscriptionBar…": "Connecting to SubscriptionBar…",
    "SubscriptionBar disconnected": "SubscriptionBar disconnected. Open the app to reconnect.",
    "SubscriptionBar disconnected; result pending": "SubscriptionBar disconnected; result pending",
    "SubscriptionBar unavailable": "SubscriptionBar unavailable. Open the app to reconnect.",
    "SubscriptionBar unavailable or incompatible": "SubscriptionBar unavailable or incompatible",
    "Website cookies applied; server account not verified": "Website cookies applied; server account not verified",
    "Website cookies saved; confirm this is selected account": "Website cookies saved; confirm this is selected account",
    "Capture failed. Check app and sign into selected website account.": "Capture failed. Check app and sign into selected website account.",
    "Session could not be applied": "Session could not be applied",
    "Session failed; rollback failed. Sign in manually.": "Session failed; rollback failed. Sign in manually.",
    "Session failed; previous cookies restored.": "Session failed; previous cookies restored.",
    "Session transaction interrupted; inspect browser sign-in": "Session transaction interrupted; inspect browser sign-in",
    "SubscriptionBar is unavailable": "SubscriptionBar is unavailable",
    "SubscriptionBar timed out": "SubscriptionBar did not answer in time. Open the app and try again.",
    "Disconnected": "Disconnected",
    "Invalid host response": "SubscriptionBar sent a response this extension could not read. Update both to the same version.",
    "Select an account": "Select an account",
    "Capture failed": "Capture failed",
    "Session unavailable": "Session unavailable",
    "Website cookies saved; confirm this is the selected account": "Website cookies saved; confirm this is the selected account",
    "Capture failed. Check the app and sign into the selected website account.": "Capture failed. Check the app and sign into the selected website account."
  },
  "ru": {
    "language": "Язык",
    "account": "Аккаунт SubscriptionBar",
    "appliesTo": "Сохранит сессию для %s.",
    "captureHelp": "Перед сохранением сессии войдите на сайте в выбранный аккаунт.",
    "capture": "Сохранить сессию сайта",
    "capturing": "Сохраняем…",
    "autoHelp": "Для автопереключения включите переключение браузера для этого аккаунта в SubscriptionBar.",
    "connecting": "Подключение…",
    "companionUnavailable": "SubscriptionBar не отвечает. Откройте приложение и откройте это окно заново.",
    "captureUnavailable": "Не удалось связаться с SubscriptionBar. Откройте приложение и повторите.",
    "noAccounts": "Аккаунтов пока нет",
    "noAccountsStatus": "Сначала подключите аккаунт в SubscriptionBar.",
    "Connected": "Подключено",
    "Connecting to SubscriptionBar…": "Подключение к SubscriptionBar…",
    "SubscriptionBar disconnected": "Соединение с SubscriptionBar потеряно. Откройте приложение.",
    "SubscriptionBar disconnected; result pending": "Соединение с SubscriptionBar потеряно; результат ожидает отправки",
    "SubscriptionBar unavailable": "SubscriptionBar недоступен. Откройте приложение.",
    "SubscriptionBar unavailable or incompatible": "SubscriptionBar недоступен или несовместим",
    "Website cookies applied; server account not verified": "Cookies сайта применены; аккаунт на сервере не проверен",
    "Website cookies saved; confirm this is selected account": "Cookies сайта сохранены; убедитесь, что это выбранный аккаунт",
    "Capture failed. Check app and sign into selected website account.": "Не удалось сохранить сессию. Проверьте приложение и войдите на сайте в выбранный аккаунт.",
    "Session could not be applied": "Не удалось применить сессию",
    "Session failed; rollback failed. Sign in manually.": "Не удалось применить сессию или восстановить прежнюю. Войдите вручную.",
    "Session failed; previous cookies restored.": "Не удалось применить сессию; прежние cookies восстановлены.",
    "Session transaction interrupted; inspect browser sign-in": "Переключение сессии прервано; проверьте вход в браузере",
    "SubscriptionBar is unavailable": "SubscriptionBar недоступен",
    "SubscriptionBar timed out": "SubscriptionBar не ответил вовремя. Откройте приложение и повторите.",
    "Disconnected": "Соединение потеряно",
    "Invalid host response": "SubscriptionBar прислал ответ, который расширение не смогло прочитать. Обновите оба до одной версии.",
    "Select an account": "Выберите аккаунт",
    "Capture failed": "Не удалось сохранить сессию",
    "Session unavailable": "Сессия недоступна",
    "Website cookies saved; confirm this is the selected account": "Cookies сайта сохранены; убедитесь, что это выбранный аккаунт",
    "Capture failed. Check the app and sign into the selected website account.": "Не удалось сохранить сессию. Проверьте приложение и войдите на сайте в выбранный аккаунт."
  }
};

const sites = {claude: "claude.ai", codex: "chatgpt.com", grok: "grok.com"};
const okStatuses = new Set(["Connected", "Website cookies applied; server account not verified",
  "Website cookies saved; confirm this is selected account",
  "Website cookies saved; confirm this is the selected account"]);
const errorStatuses = new Set(["companionUnavailable", "captureUnavailable",
  "SubscriptionBar disconnected", "SubscriptionBar unavailable", "SubscriptionBar unavailable or incompatible",
  "SubscriptionBar is unavailable", "SubscriptionBar timed out", "Disconnected", "Invalid host response",
  "Capture failed", "Capture failed. Check app and sign into selected website account.",
  "Capture failed. Check the app and sign into the selected website account.",
  "Session could not be applied", "Session unavailable",
  "Session failed; rollback failed. Sign in manually.",
  "Session transaction interrupted; inspect browser sign-in"]);

export function languageFor(value) { return typeof value === "string" && /^ru(?:-|$)/i.test(value) ? "ru" : "en"; }

/// An unmapped status is still information from the app. Showing it verbatim
/// beats replacing a success with a generic failure message.
export function translate(language, key) {
  return messages[languageFor(language)][key] ?? (typeof key === "string" ? key : "");
}
/// Unknown means uncertain, not failed, so it stays neutral.
export function stateFor(key) {
  if (okStatuses.has(key)) return "ok";
  if (errorStatuses.has(key)) return "error";
  return "warn";
}
export function siteFor(provider) { return sites[provider] ?? provider; }

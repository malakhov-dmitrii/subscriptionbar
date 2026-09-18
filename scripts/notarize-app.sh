#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /absolute/path/SubscriptionBar.app" >&2
    exit 2
fi
app_path="$1"
profile="${SUBSCRIPTIONBAR_NOTARY_PROFILE:-pulse-notary}"
notary_work="${SUBSCRIPTIONBAR_NOTARY_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/subscriptionbar-notary.XXXXXX")}"
mkdir -p "$notary_work"
codesign --verify --strict "$app_path"
codesign -d --verbose=4 "$app_path" 2> "$notary_work/signature.txt"
python3 - "$notary_work/signature.txt" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
required=['Authority=Developer ID Application:', 'Timestamp=', '(runtime)']
if not all(x in s for x in required):
    raise SystemExit('Developer ID, secure timestamp and hardened runtime are required before upload.')
PY
archive="$notary_work/SubscriptionBar-upload.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --output-format json > "$notary_work/submission.json"
submission_id="$(python3 - "$notary_work/submission.json" <<'PY'
import json,sys,uuid
value=json.load(open(sys.argv[1]))['id']
print(str(uuid.UUID(value)))
PY
)"
echo "Apple submission: $submission_id"
# The UUID is durable before waiting. A timeout must be resumed with notarytool
# wait/info for this UUID, never by blindly resubmitting the same archive.
xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout 15m --output-format json > "$notary_work/status.json"
xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$notary_work/log.json"
python3 - "$notary_work/status.json" <<'PY'
import json,sys
status=json.load(open(sys.argv[1])).get('status')
if status!='Accepted': raise SystemExit('Apple notarization status: '+str(status))
print('Apple notarization: Accepted')
PY
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --strict "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
echo "Notarization receipt directory: $notary_work"

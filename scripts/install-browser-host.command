#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$script_dir/../MacOS/SubscriptionBar" ]]; then
    app_binary="$script_dir/../MacOS/SubscriptionBar"
else
    app_binary="$script_dir/../../SubscriptionBar.app/Contents/MacOS/SubscriptionBar"
fi
if [[ ! -x "$app_binary" ]]; then
    echo "SubscriptionBar.app not found. Build the app first."
    exit 1
fi
/usr/bin/python3 - "$app_binary" <<'PY'
import json, os, pathlib, shlex, sys, tempfile
binary = str(pathlib.Path(sys.argv[1]).resolve())
support = pathlib.Path.home() / 'Library/Application Support'
root = support / 'SubscriptionBar'
root.mkdir(mode=0o700, parents=True, exist_ok=True)
def atomic(path, data, mode):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink(): raise RuntimeError('Refusing symlink: ' + str(path))
    fd, temp = tempfile.mkstemp(prefix='.subscriptionbar-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as out:
            out.write(data); out.flush(); os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)
host = root / 'native-host'
atomic(host, '#!/bin/sh\nexec ' + shlex.quote(binary) + ' --native-host "$@"\n', 0o700)
manifest = {'name':'com.local.subscriptionbar', 'description':'SubscriptionBar local account sessions',
            'path':str(host), 'type':'stdio',
            'allowed_origins':['chrome-extension://bcagcmegeimpjhbkgfmeapjmkfmljlch/']}
for browser in ['Google/Chrome', 'Microsoft Edge', 'BraveSoftware/Brave-Browser']:
    target = support / browser / 'NativeMessagingHosts/com.local.subscriptionbar.json'
    atomic(target, json.dumps(manifest, indent=2) + '\n', 0o600)
firefox_manifest = dict(manifest)
firefox_manifest.pop('allowed_origins')
firefox_manifest['allowed_extensions'] = ['subscriptionbar@local.example']
atomic(support / 'Mozilla/NativeMessagingHosts/com.local.subscriptionbar.json', json.dumps(firefox_manifest, indent=2) + '\n', 0o600)
print('Browser connection installed. Reload the SubscriptionBar extension in your browser.')
print('If you move SubscriptionBar.app, run this installer again.')
PY

#!/usr/bin/env bash
# Test à sec : exécute install.sh contre de faux gcloud/curl et affiche les appels.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$here/fake-gcloud" "$here/fake-curl"
tmp="$(mktemp -d)"; mkdir -p "$tmp/bin" "$tmp/state"
ln -s "$here/fake-gcloud" "$tmp/bin/gcloud"; ln -s "$here/fake-curl" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_STATE="$tmp/state"
export GWS_OAUTH_CLIENT_SECRET="GOCSPX-test"
[[ "${1:-}" == "--existing" ]] && touch "$tmp/state/existing" && shift
cd "$tmp" && bash "$here/../install.sh" --project demo-client --client-id 123-abc.apps.googleusercontent.com --yes "$@"
echo; echo "----- appels gcloud -----"; cat "$tmp/log"
echo "----- résumé -----"; cat "$tmp"/gws-mcp-*.txt

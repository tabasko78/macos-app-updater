#!/bin/zsh
# Publishes a new version on GitHub: ./publier.sh "what changed"
# Bumps the patch number (1.0.3 -> 1.0.4), commits, pushes, builds the public zip, creates the release.
set -euo pipefail
cd "$(dirname "$0")"
[[ $# -ge 1 ]] || { echo "Usage: ./publier.sh \"what changed\""; exit 1; }
NOTES="$1"

V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Ressources/Info.plist)
B=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Ressources/Info.plist)
NV="${V%.*}.$(( ${V##*.} + 1 ))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NV" -c "Set :CFBundleVersion $(( B + 1 ))" Ressources/Info.plist

./construire.sh --public --zip
git add -A
git commit -q -m "v$NV: $NOTES"
git push -q
gh release create "v$NV" "build/macOS App Updater.zip" --title "v$NV" --notes "$NOTES"
echo "Published v$NV"

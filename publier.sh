#!/bin/zsh
# Sends work to GitHub.
#   ./publier.sh "what changed"              commit + push only (no downloadable release)
#   ./publier.sh --version "release notes"   new downloadable release: bumps the version (1.1.0 -> 1.1.1),
#                                            builds the public zip, commits, pushes, creates the GitHub release
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0
[[ "${1:-}" == "--version" ]] && { VERSION=1; shift; }
[[ $# -ge 1 ]] || { echo "Usage: ./publier.sh [--version] \"text\""; exit 1; }
TEXTE="$1"

if [[ $VERSION == 0 ]]; then
    git add -A
    git commit -q -m "$TEXTE"
    git push -q
    echo "Pushed: $TEXTE"
    exit 0
fi

V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Ressources/Info.plist)
B=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Ressources/Info.plist)
NV="${V%.*}.$(( ${V##*.} + 1 ))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NV" -c "Set :CFBundleVersion $(( B + 1 ))" Ressources/Info.plist

./construire.sh --public --zip
git add -A
git commit -q -m "v$NV"
git push -q
gh release create "v$NV" "build/macOS App Updater.zip" --title "v$NV" --notes "$TEXTE"
echo "Released v$NV"

#!/bin/zsh
# Sends work to GitHub.
#   ./publier.sh "what changed"              commit + push only (no downloadable release)
#   ./publier.sh --version "release notes"   new downloadable release: bumps the version (1.1.0 -> 1.1.1),
#                                            builds the public zip, commits, pushes, creates the GitHub release
set -euo pipefail
cd "$(dirname "$0")"

# Publishing guard (perso/, never published): without it, or if it finds anything personal, nothing is sent.
GARDE=perso/verifier-publication.sh
[[ -x "$GARDE" ]] || { echo "Publishing guard missing ($GARDE): nothing is published."; exit 1; }

VERSION=0
[[ "${1:-}" == "--version" ]] && { VERSION=1; shift; }
[[ $# -ge 1 ]] || { echo "Usage: ./publier.sh [--version] \"text\""; exit 1; }
TEXTE="$1"
# The text goes to GitHub (commit message or release notes): checked first, before anything changes.
NOTES=$(mktemp); print -r -- "$TEXTE" > "$NOTES"
"$GARDE" --message "$NOTES" || { rm -f "$NOTES"; exit 1; }
rm -f "$NOTES"

if [[ $VERSION == 0 ]]; then
    "$GARDE" || exit 1
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
"$GARDE" || exit 1
"$GARDE" --zip "build/macOS App Updater.zip" || exit 1
git add -A
git commit -q -m "v$NV"
git push -q
gh release create "v$NV" "build/macOS App Updater.zip" --title "v$NV" --notes "$TEXTE"
echo "Released v$NV"

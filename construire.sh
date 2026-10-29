#!/bin/zsh
# Build the app into build/.
#   ./construire.sh             personal copy if perso/config.json exists, public version otherwise
#   ./construire.sh --public    public version (the one published on GitHub), whatever is in perso/
#   ./construire.sh --installer also copies the app into /Applications (the running copy is quit first)
#   ./construire.sh --zip       also makes build/<name>.zip, ready to attach to a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

PUBLIC=0; INSTALLER=0; ZIP=0
for a in "$@"; do
    case "$a" in
        --public) PUBLIC=1 ;;
        --installer) INSTALLER=1 ;;
        --zip) ZIP=1 ;;
    esac
done
PERSO=""
[[ $PUBLIC == 0 && -f perso/config.json ]] && PERSO=perso/config.json

# SwiftPM's new build system fails with the Command Line Tools alone (no Xcode): use the native one.
if ! swift build -c release --build-system native > .build-journal.txt 2>&1; then
    grep -E "error:" .build-journal.txt | sort -u
    echo "Build failed, details: $PWD/.build-journal.txt"
    exit 1
fi

if [[ ! -f Ressources/AppIcon.icns ]]; then
    tmp=$(mktemp -d)
    swift outils/icone.swift "$tmp/icone.png"
    mkdir "$tmp/AppIcon.iconset"
    for t in 16 32 128 256 512; do
        sips -z $t $t "$tmp/icone.png" --out "$tmp/AppIcon.iconset/icon_${t}x${t}.png" >/dev/null
        sips -z $((t*2)) $((t*2)) "$tmp/icone.png" --out "$tmp/AppIcon.iconset/icon_${t}x${t}@2x.png" >/dev/null
    done
    iconutil -c icns "$tmp/AppIcon.iconset" -o Ressources/AppIcon.icns
    rm -rf "$tmp"
fi

NOM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Ressources/Info.plist)
[[ -n "$PERSO" ]] && NOM=$(plutil -extract nom raw "$PERSO")
APP="build/$NOM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AppUpdater "$APP/Contents/MacOS/"
cp Ressources/Info.plist "$APP/Contents/"
cp Ressources/AppIcon.icns "$APP/Contents/Resources/"
if [[ -n "$PERSO" ]]; then
    # Personal copy: its own identifier and name (so its settings are kept), and its defaults (theme, language…).
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(plutil -extract bundleId raw "$PERSO")" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $NOM" -c "Set :CFBundleDisplayName $NOM" "$APP/Contents/Info.plist"
    cp "$PERSO" "$APP/Contents/Resources/perso.json"
fi
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"

if [[ $ZIP == 1 ]]; then
    rm -f "build/$NOM.zip"
    ditto -c -k --keepParent "$APP" "build/$NOM.zip"
    echo "Zip: $PWD/build/$NOM.zip"
fi

if [[ $INSTALLER == 1 ]]; then
    ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
    osascript -e "tell application id \"$ID\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$NOM.app"
    ditto "$APP" "/Applications/$NOM.app"
    echo "Installed: /Applications/$NOM.app"
fi

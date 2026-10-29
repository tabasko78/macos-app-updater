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
# Universal app: one build per processor (Apple silicon and Intel), joined with lipo. macOS only loads the part
# for its own processor, so this costs about 1 MB on disk and nothing in memory.
: > .build-journal.txt
for arch in arm64 x86_64; do
    # Un dossier de travail par processeur : alterner les deux dans le même dossier fait échouer SwiftPM.
    if ! swift build -c release --build-system native --arch $arch --scratch-path .build/arch-$arch >> .build-journal.txt 2>&1; then
        grep -E "error:" .build-journal.txt | sort -u
        echo "Build failed ($arch), details: $PWD/.build-journal.txt"
        exit 1
    fi
done
mkdir -p .build/universel
lipo -create .build/arch-arm64/release/AppUpdater .build/arch-x86_64/release/AppUpdater -output .build/universel/AppUpdater

# Icon drawn by the app itself, in the colours of the default theme (the Dock icon then follows the chosen theme).
THEME="Graphite"
[[ -n "$PERSO" ]] && THEME=$(plutil -extract theme raw "$PERSO" 2>/dev/null || echo Graphite)
tmp=$(mktemp -d)
.build/universel/AppUpdater --icone "$THEME" "$tmp/icone.png"
mkdir "$tmp/AppIcon.iconset"
for t in 16 32 128 256 512; do
    sips -z $t $t "$tmp/icone.png" --out "$tmp/AppIcon.iconset/icon_${t}x${t}.png" >/dev/null
    sips -z $((t*2)) $((t*2)) "$tmp/icone.png" --out "$tmp/AppIcon.iconset/icon_${t}x${t}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$tmp/AppIcon.icns"

NOM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Ressources/Info.plist)
[[ -n "$PERSO" ]] && NOM=$(plutil -extract nom raw "$PERSO")
APP="build/$NOM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/universel/AppUpdater "$APP/Contents/MacOS/"
cp Ressources/Info.plist "$APP/Contents/"
cp "$tmp/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$tmp"
if [[ -n "$PERSO" ]]; then
    # Personal copy: its own identifier and name (so its settings are kept), and its defaults (theme, language…).
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(plutil -extract bundleId raw "$PERSO")" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $NOM" -c "Set :CFBundleDisplayName $NOM" "$APP/Contents/Info.plist"
    cp "$PERSO" "$APP/Contents/Resources/perso.json"
fi
# Copie perso : signée avec son identité fixe (« macOS App Updater (local) », dans le trousseau), pour que macOS
# lui garde ses autorisations d'une version à l'autre (Gestion des apps, trousseau, Little Snitch).
# Version publique : signature jetable.
SIG="-"
[[ -n "$PERSO" ]] && SIG=$(plutil -extract signature raw "$PERSO" 2>/dev/null || echo "-")
codesign --force --sign "$SIG" "$APP"
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

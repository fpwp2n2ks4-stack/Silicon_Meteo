#!/bin/bash
#
# Build de l'application barre de menus.
#
# Utilise uniquement les Command Line Tools (pas de Xcode) : le binaire est
# produit par swiftc, puis placé dans un .app minimal avec son Info.plist.
#

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Toasty"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALL_DIR="/Applications"

# Par défaut le build ne produit que `build/Toasty.app`, à côté des sources.
# `--install` demande en plus une copie dans /Applications : c'est une copie,
# jamais un déplacement, et c'est elle que pointe un élément de connexion, un
# élément de connexion étant un chemin qui ne suit pas le dépôt.
INSTALL=0
SOURCES=(
    Sensors/Sensors.swift
    App/StatusItemView.swift
    App/PopupView.swift
    App/AppDelegate.swift
    App/main.swift
)

# Un argument inconnu est rejeté plutôt qu'ignoré : taper `--instal` de mémoire
# doit échouer bruyamment, pas produire un build silencieux sans installation.
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "option inconnue : $arg" >&2
           echo "usage : $0 [--install]" >&2
           exit 2 ;;
    esac
done

echo "▸ Nettoyage"
rm -rf "$APP_BUNDLE"

echo "▸ Création du bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "▸ Compilation (arm64 natif)"
swiftc \
    -O \
    -whole-module-optimization \
    -target arm64-apple-macosx14.0 \
    -framework AppKit \
    -framework IOKit \
    -o "$BINARY" \
    "${SOURCES[@]}"

# Retrait des symboles locaux : ~48 Ko sur 224, soit 21 % du binaire. Doit
# précéder la signature — stripper après invalide le CodeDirectory et l'app
# ne se lance plus.
echo "▸ Strip"
strip -x "$BINARY"

echo "▸ Info.plist"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Agent de barre de menus : pas d'icône dans le Dock, pas de menu App -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "▸ Signature ad-hoc"
# Signature ad-hoc : suffisante pour un lancement local, et nécessaire
# car les accès IOKit sont refusés à un binaire non signé.
codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>/dev/null \
    || echo "  (signature ignorée)"

echo "▸ Vérification"
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | head -2 || true

if [ "$INSTALL" = "1" ]; then
    echo "▸ Installation dans $INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "$INSTALL_DIR/$APP_NAME.app"
    codesign --verify --strict "$INSTALL_DIR/$APP_NAME.app" \
        && echo "  → $INSTALL_DIR/$APP_NAME.app (signature vérifiée)"
fi

echo
echo "✓ $APP_BUNDLE construit"
echo "  Lancer    : open $APP_BUNDLE"
[ "$INSTALL" = "1" ] && echo "  Installée : open $INSTALL_DIR/$APP_NAME.app"

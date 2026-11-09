#!/bin/zsh
# Compile iBaobab et produit build/iBaobab.app
# Variables facultatives :
#   UNIVERSAL=1        binaire universel (Apple Silicon + Intel)
#   VERSION=1.2.0      numéro de version écrit dans Info.plist
#   BUILD_NUMBER=42    numéro de build écrit dans Info.plist
#   SIGN_IDENTITY=…    identité de signature (par défaut : signature ad hoc « - »)
set -euo pipefail
cd "${0:A:h}"
CONFIG=${1:-release}
PRODUCT=iBaobab
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    # Une compilation par architecture puis lipo ; chaque tranche est copiée aussitôt
    # (selon la version de SwiftPM, le dossier de sortie est commun).
    SLICES=()
    mkdir -p build/slices
    for ARCH in arm64 x86_64; do
        TRIPLE="$ARCH-apple-macosx15.0"
        swift build -c "$CONFIG" --triple "$TRIPLE" --product "$PRODUCT"
        cp "$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/$PRODUCT" "build/slices/$PRODUCT-$ARCH"
        SLICES+=("build/slices/$PRODUCT-$ARCH")
    done
    BIN=build/$PRODUCT-universal
    lipo -create -output "$BIN" "${SLICES[@]}"
else
    swift build -c "$CONFIG" --product "$PRODUCT"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/$PRODUCT"
fi
APP=build/$PRODUCT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Traductions de l'interface (fr.lproj, en.lproj).
cp -R Resources/*.lproj "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
# Sans identité donnée : le certificat personnel créé par Tools/make-local-cert.sh s'il existe
# (signature stable, macOS garde les autorisations d'un build à l'autre), sinon signature ad hoc.
LOCAL_CERT="Local Code Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "$LOCAL_CERT" >/dev/null 2>&1; then
    if ! codesign --force --timestamp=none --sign "$LOCAL_CERT" "$APP" >/dev/null 2>&1; then
        # Trousseau verrouillé (session SSH…) : signature ad hoc pour ne pas bloquer le build.
        echo "Signature « $LOCAL_CERT » impossible, signature ad hoc." >&2
        codesign --force --timestamp=none --sign - "$APP" >/dev/null
    fi
else
    codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
fi
echo "$APP"

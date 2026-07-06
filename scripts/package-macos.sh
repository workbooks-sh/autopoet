#!/usr/bin/env bash
# Build, bundle, sign, notarize, and package Autopoet.app → Autopoet.dmg
# (macOS, Apple Silicon). Self-contained: bundles ERTS + the mix release + the
# app/home surface + the lean ML weights, and RELOCATES the Homebrew native
# dylibs (wxWidgets, onnxruntime, openssl) into the bundle so it runs on a Mac
# with no Homebrew, no Elixir.
#
#   scripts/package-macos.sh                # full: build → sign → notarize → dmg
#   SKIP_BUILD=1 scripts/package-macos.sh   # reuse _build/prod/rel/autopoet
#   SKIP_NOTARY=1 scripts/package-macos.sh  # signed-but-unnotarized (fast, local)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Autopoet.app"
DMG="$DIST/Autopoet.dmg"
REL_SRC="$ROOT/_build/prod/rel/autopoet"
VERSION="${VERSION:-0.0.1}"
TEAM_ID="${APPLE_TEAM_ID:-BJJZ79J5NL}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Shane Murphy ($TEAM_ID)}"
ENTITLEMENTS="$ROOT/native/Autopoet.entitlements"

# notary creds (App Store Connect API key) — shared machine profile
for envfile in "$HOME/.workbooks/notary.env"; do
  [[ -f "$envfile" ]] && { set -a; source "$envfile"; set +a; }
done
NOTARY_KEY="${APPLE_NOTARY_KEY_PATH:-${APPLE_API_KEY_PATH:-}}"
NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-${APPLE_API_KEY:-}}"
NOTARY_ISSUER="${APPLE_NOTARY_ISSUER:-${APPLE_API_ISSUER:-}}"

say() { printf '\n\033[1m→ %s\033[0m\n' "$*"; }

# ── 1. build the prod release (self-contained ERTS) ─────────────────────────
if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  say "building prod release"
  ( cd "$ROOT" && MIX_ENV=prod mix release autopoet --overwrite )
fi
[[ -d "$REL_SRC" ]] || { echo "✘ no release at $REL_SRC" >&2; exit 1; }

# ── 2. assemble the .app ────────────────────────────────────────────────────
say "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/native/Info.plist"      "$APP/Contents/Info.plist"
cp "$ROOT/priv/static/autopoet.icns" "$APP/Contents/Resources/autopoet.icns"
cp "$ROOT/native/launch.sh"       "$APP/Contents/MacOS/Autopoet"
chmod +x "$APP/Contents/MacOS/Autopoet"

# 2a. the mix release
cp -R "$REL_SRC" "$APP/Contents/Resources/rel"

# 2b. the app/home surface (Nexus.Server root = AUTOPOET_HOME/app/home)
mkdir -p "$APP/Contents/Resources/app-home/app"
cp -R "$ROOT/app/home" "$APP/Contents/Resources/app-home/app/home"
# strip any stray dev state that may sit under the source tree
rm -rf "$APP/Contents/Resources/app-home/app/home/.DS_Store"

# 2c. lean ML weights — ONLY what loads at runtime (Kokoro fp32 + Moonshine + Affect)
M="$APP/Contents/Resources/models"
mkdir -p "$M/kokoro/voices" "$M/moonshine" "$M/affect"
cp "$ROOT/data/models/kokoro/model_fp32.onnx" "$M/kokoro/"
cp "$ROOT/data/models/kokoro/tokenizer.json"  "$M/kokoro/"
cp "$ROOT"/data/models/kokoro/voices/*.bin    "$M/kokoro/voices/"
cp "$ROOT/data/models/moonshine/encoder_model.onnx"            "$M/moonshine/"
cp "$ROOT/data/models/moonshine/decoder_model.onnx"           "$M/moonshine/"
cp "$ROOT/data/models/moonshine/decoder_with_past_model.onnx" "$M/moonshine/"
cp "$ROOT/data/models/moonshine/tokenizer.json"               "$M/moonshine/"
cp "$ROOT/data/models/affect/model_quantized.onnx" "$M/affect/"
cp "$ROOT/data/models/affect/tokenizer.json"       "$M/affect/"

# 2d. the empty-world deploy manifest (seeded per-install on first run)
mkdir -p "$APP/Contents/Resources/seed"
cp "$ROOT/data/nexus/index.work" "$APP/Contents/Resources/seed/index.work"

# 2e. drop the OpenSSL engine-test NIF (never used; one less thing to relocate/sign)
rm -f "$APP"/Contents/Resources/rel/lib/crypto-*/priv/lib/otp_test_engine.so
# ship Kokoro only: the Qwen python sidecar scripts don't belong in this canary
# (Autopoet.QwenTts isn't in the spine; without a venv these could never run anyway)
rm -rf "$APP"/Contents/Resources/rel/lib/autopoet-*/priv/qwen_tts

# 2f. bundle espeak-ng — Kokoro phonemizes through it and end-user Macs have no
# Homebrew. Binary + its two dylibs + the dictionary data, relocated to the bundle.
say "bundling espeak-ng (Kokoro's phonemizer)"
ESPEAK_SRC="$(brew --prefix espeak-ng)"
PCAUDIO_SRC="$(brew --prefix pcaudiolib)"
ESP="$APP/Contents/Resources/espeak"
mkdir -p "$ESP/bin" "$ESP/lib" "$ESP/share"
cp "$ESPEAK_SRC/bin/espeak-ng" "$ESP/bin/"
cp "$ESPEAK_SRC/lib/libespeak-ng.1.dylib" "$ESP/lib/"
cp "$PCAUDIO_SRC/lib/libpcaudio.0.dylib"  "$ESP/lib/"
cp -R "$ESPEAK_SRC/share/espeak-ng-data" "$ESP/share/espeak-ng-data"
chmod -R u+w "$ESP"
# rewrite the Homebrew install names to bundle-relative ones
for lib in libespeak-ng.1.dylib libpcaudio.0.dylib; do
  install_name_tool -id "@executable_path/../lib/$lib" "$ESP/lib/$lib"
done
for target in "$ESP/bin/espeak-ng" "$ESP/lib/libespeak-ng.1.dylib"; do
  otool -L "$target" | awk '/homebrew/ {print $1}' | while read -r dep; do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$target"
  done
done
# verify: no homebrew links left in the espeak tree
if otool -L "$ESP/bin/espeak-ng" "$ESP/lib/"*.dylib | grep -qi homebrew; then
  echo "✘ espeak-ng still links Homebrew paths" >&2; exit 1
fi

# ── 3. relocate the Homebrew native dylibs into the bundle ───────────────────
say "relocating native dylibs (wx · onnxruntime · openssl) → erts Frameworks"
REL="$APP/Contents/Resources/rel"
ERTS_DIR="$(cd "$REL"/erts-* && pwd)"
FW="$ERTS_DIR/Frameworks"        # @executable_path(beam.smp)/../Frameworks
WXE=$(echo "$REL"/lib/wx-*/priv/wxe_driver.so)
CRYPTO=$(echo "$REL"/lib/crypto-*/priv/lib/crypto.so)
ORTEX=$(echo "$REL"/lib/ortex-*/priv/native/ortex.so)
dylibbundler -of -b -cd \
  -x "$WXE" -x "$CRYPTO" -x "$ORTEX" \
  -d "$FW" -p "@executable_path/../Frameworks/" \
  -s /opt/homebrew/lib \
  -s /opt/homebrew/opt/onnxruntime/lib \
  -s /opt/homebrew/opt/wxwidgets@3.2/lib \
  -s /opt/homebrew/opt/openssl@3/lib </dev/null
echo "bundled $(ls "$FW" | wc -l | xargs) dylib(s) into $FW"

# dylibbundler can stamp its LC_RPATH twice on a file it processes both as an
# `-x` target and as a dependency (e.g. ortex.so, whose own id is @rpath/…) — and
# dyld REFUSES to load a Mach-O with a duplicate LC_RPATH. Dedupe to a single copy.
say "de-duplicating LC_RPATH (dyld rejects duplicates)"
count_fw_rpath() {
  otool -l "$1" 2>/dev/null | awk '
    /cmd LC_RPATH/ { r=1; next }
    r && /^[[:space:]]*path / { if ($2=="@executable_path/../Frameworks/") c++; r=0 }
    END { print c+0 }'
}
find "$APP" -type f \( -name "*.so" -o -name "*.dylib" -o -perm +111 \) | while read -r f; do
  file "$f" | grep -q "Mach-O" || continue
  while [ "$(count_fw_rpath "$f")" -gt 1 ]; do
    install_name_tool -delete_rpath "@executable_path/../Frameworks/" "$f" 2>/dev/null || break
  done
done

# ── 4. sign every Mach-O bottom-up, then the bundle ─────────────────────────
say "signing (Developer ID + hardened runtime + entitlements)"
sign_file() {
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$1" 2>/dev/null
}
export -f sign_file; export IDENTITY ENTITLEMENTS
find "$APP" -type f \( -name "*.so" -o -name "*.dylib" -o -perm +111 \) | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then sign_file "$f"; fi
done
# the app bundle last
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

say "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -t exec -vv "$APP" 2>&1 || true   # will say "rejected/unnotarized" until step 6

# ── 5. build the DMG ────────────────────────────────────────────────────────
say "creating dmg"
rm -f "$DMG"
STAGE="$DIST/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Autopoet" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"

# ── 6. notarize + staple ────────────────────────────────────────────────────
if [[ "${SKIP_NOTARY:-}" == "1" ]]; then
  say "SKIP_NOTARY=1 — signed but NOT notarized (Gatekeeper needs a manual override)"
  exit 0
fi
[[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]] || {
  echo "✘ no notary creds in ~/.workbooks/notary.env (APPLE_NOTARY_KEY_PATH/_ID/_ISSUER)" >&2; exit 1; }
say "notarizing (App Store Connect API key $NOTARY_KEY_ID) — this waits for Apple"
xcrun notarytool submit "$DMG" \
  --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
say "stapling"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true

say "done → $DMG"

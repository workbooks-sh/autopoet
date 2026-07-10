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

# every stage banner carries the elapsed clock — the build's own profiler, so
# "why is bundling slow" is always answerable from any build log
T0=$SECONDS
say() { printf '\n\033[1m→ [%3ds] %s\033[0m\n' "$((SECONDS - T0))" "$*"; }

# APFS copy-on-write clone (instant, zero extra disk) with a real-copy fallback
# for cross-volume targets — the 1.2GB app otherwise gets byte-copied TWICE
# (dmg staging + /Applications install)
clone() { cp -c -R "$1" "$2" 2>/dev/null || ditto "$1" "$2"; }

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
# The main executable is the NATIVE SWIFT SHELL (wb-402zq): a real AppKit app
# that owns the window/WKWebView/Dock/menus/TCC on THIS bundle and spawns the
# BEAM release headless via Resources/launch.sh. (The old lane — launcher.c
# exec'ing launch.sh into a wx window — kept fighting AppKit from outside.)
cp "$ROOT/native/launch.sh" "$APP/Contents/Resources/launch.sh"
chmod +x "$APP/Contents/Resources/launch.sh"
say "compiling the Swift shell"
swiftc -O "$ROOT/native/AutopoetShell.swift" -o "$APP/Contents/MacOS/Autopoet"

# 2a. the mix release
clone "$REL_SRC" "$APP/Contents/Resources/rel"

# 2a'. the RUNTIME HELPER bundle — beam.smp must carry a real app-bundle
# identity (mainBundle → usage strings → TCC). An unbundled beam in erts/bin
# has NO Info.plist: AVFoundation/WebKit find no usage description and deny
# capture without prompting. Structure (the Electron-helper pattern):
#   AutopoetRuntime.app/Contents/MacOS/beam.smp   ← the real binary
#   AutopoetRuntime.app/Contents/Frameworks/      ← bundled dylibs (so beam's
#       @executable_path/../Frameworks/… install names resolve naturally)
#   erts-*/bin/beam.smp                            ← exec shim (mainBundle
#       follows the LITERAL exec path, so a symlink is not enough)
ERTS_DIR=$(ls -d "$APP/Contents/Resources/rel/erts-"*)
HELPER="$APP/Contents/Resources/rel/AutopoetRuntime.app"
mkdir -p "$HELPER/Contents/MacOS"
mv "$ERTS_DIR/bin/beam.smp" "$HELPER/Contents/MacOS/beam.smp"
cat > "$ERTS_DIR/bin/beam.smp" <<'SHIM'
#!/bin/bash
# exec the REAL beam inside the helper .app so the process carries a proper
# bundle identity (mainBundle → usage strings → TCC can finally prompt)
exec "$(cd "$(dirname "$0")/../.." && pwd)/AutopoetRuntime.app/Contents/MacOS/beam.smp" "$@"
SHIM
chmod +x "$ERTS_DIR/bin/beam.smp"
# the RUNNING GUI process is this helper — macOS hangs the Dock tile/icon on
# ITS bundle, not the outer app's, so the helper must carry the same icon
mkdir -p "$HELPER/Contents/Resources"
cp "$ROOT/priv/static/autopoet.icns" "$HELPER/Contents/Resources/autopoet.icns"
cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>ai.zaius.autopoet</string>
	<key>CFBundleName</key>
	<string>Autopoet</string>
	<key>CFBundleExecutable</key>
	<string>beam.smp</string>
	<key>CFBundleDisplayName</key>
	<string>Autopoet</string>
	<key>CFBundleIconFile</key>
	<string>autopoet</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Autopoet listens to your voice so you can speak with your companion.</string>
	<key>NSCameraUsageDescription</key>
	<string>Autopoet can use the camera for expressive, face-aware interactions.</string>
</dict>
</plist>
PLIST

# 2b. the app/home surface (Nexus.Server root = AUTOPOET_HOME/app/home)
mkdir -p "$APP/Contents/Resources/app-home/app"
clone "$ROOT/app/home" "$APP/Contents/Resources/app-home/app/home"
# strip any stray dev state that may sit under the source tree
rm -rf "$APP/Contents/Resources/app-home/app/home/.DS_Store"
# overlay the TRACKED vendor code from priv/static onto the gitignored app/home/static
# tree — app/home/static is the SERVED static root but holds untracked blobs, so it
# drifts; v0.0.1 shipped a client importing GLTFLoader.mjs that this tree lacked
# (module 404→SPA-shell HTML → the whole avatar module died, no cube). Code files
# are canonical in priv/static/vendor; the big wasm/onnx blobs stay app-local.
cp -f "$ROOT"/priv/static/vendor/*.mjs "$ROOT"/priv/static/vendor/*.js "$ROOT"/priv/static/vendor/*.glb \
  "$APP/Contents/Resources/app-home/app/home/static/vendor/"

# 2c. lean ML weights — ONLY what loads at runtime (Kokoro fp32 + Moonshine + Affect)
M="$APP/Contents/Resources/models"
mkdir -p "$M/kokoro/voices" "$M/moonshine" "$M/affect"
cp -c "$ROOT/data/models/kokoro/model_fp32.onnx" "$M/kokoro/" 2>/dev/null || cp "$ROOT/data/models/kokoro/model_fp32.onnx" "$M/kokoro/"
cp -c "$ROOT/data/models/kokoro/tokenizer.json"  "$M/kokoro/" 2>/dev/null || cp "$ROOT/data/models/kokoro/tokenizer.json"  "$M/kokoro/"
cp -c "$ROOT"/data/models/kokoro/voices/*.bin    "$M/kokoro/voices/" 2>/dev/null || cp "$ROOT"/data/models/kokoro/voices/*.bin    "$M/kokoro/voices/"
cp -c "$ROOT/data/models/moonshine/encoder_model.onnx"            "$M/moonshine/" 2>/dev/null || cp "$ROOT/data/models/moonshine/encoder_model.onnx"            "$M/moonshine/"
cp -c "$ROOT/data/models/moonshine/decoder_model.onnx"           "$M/moonshine/" 2>/dev/null || cp "$ROOT/data/models/moonshine/decoder_model.onnx"           "$M/moonshine/"
cp -c "$ROOT/data/models/moonshine/decoder_with_past_model.onnx" "$M/moonshine/" 2>/dev/null || cp "$ROOT/data/models/moonshine/decoder_with_past_model.onnx" "$M/moonshine/"
cp -c "$ROOT/data/models/moonshine/tokenizer.json"               "$M/moonshine/" 2>/dev/null || cp "$ROOT/data/models/moonshine/tokenizer.json"               "$M/moonshine/"
cp -c "$ROOT/data/models/affect/model_quantized.onnx" "$M/affect/" 2>/dev/null || cp "$ROOT/data/models/affect/model_quantized.onnx" "$M/affect/"
cp -c "$ROOT/data/models/affect/tokenizer.json"       "$M/affect/" 2>/dev/null || cp "$ROOT/data/models/affect/tokenizer.json"       "$M/affect/"

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
# Destination = the HELPER bundle's Frameworks: beam.smp really executes at
# AutopoetRuntime.app/Contents/MacOS, so @executable_path/../Frameworks resolves
# THERE. A compat symlink at erts-*/Frameworks covers the small erts helpers
# (epmd/inet_gethost run from erts/bin as their own processes). The symlink
# stays INSIDE the outer bundle, which codesign allows.
say "relocating native dylibs (wx · onnxruntime · openssl) → runtime-helper Frameworks"
REL="$APP/Contents/Resources/rel"
ERTS_DIR="$(cd "$REL"/erts-* && pwd)"
FW="$REL/AutopoetRuntime.app/Contents/Frameworks"   # @executable_path(real beam)/../Frameworks
mkdir -p "$FW"
ln -sfn ../AutopoetRuntime.app/Contents/Frameworks "$ERTS_DIR/Frameworks"
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
# the runtime helper: beam must claim the SAME identifier its helper bundle
# declares (TCC validates the signature against the claimed CFBundleIdentifier;
# codesign's filename-derived "beam" identifier reads as spoofing), then the
# helper bundle itself gets sealed BEFORE the outer app seals over it.
codesign --force --options runtime --timestamp --identifier ai.zaius.autopoet \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$HELPER/Contents/MacOS/beam.smp"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$HELPER"
# the app bundle last
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

say "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -t exec -vv "$APP" 2>&1 || true   # will say "rejected/unnotarized" until step 6

# ── 4b. install = a real COPY into /Applications, AFTER signing completes ───
# A symlinked .app is not reliably indexed by Spotlight/Launchpad (the app was
# unfindable). The copy cannot go stale: this script is the only installer and
# refreshes it on every build. Runs after notarize+staple (or before the
# SKIP_NOTARY exit) so the installed app carries the final ticket.
install_app() {
  say "installing /Applications/Autopoet.app (real copy — Spotlight/Launchpad index it)"
  rm -rf "/Applications/Autopoet.app"
  clone "$APP" "/Applications/Autopoet.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/Autopoet.app" >/dev/null 2>&1 || true
}

# ── 5. build the DMG ────────────────────────────────────────────────────────
say "creating dmg"
rm -f "$DMG"
STAGE="$DIST/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
clone "$APP" "$STAGE/Autopoet.app"
ln -s /Applications "$STAGE/Applications"
# ULFO (lzfse): the payload is ~70% ML weights — high-entropy bytes neither
# codec shrinks (UDZO managed only 24%) — so pay lzfse's fast compressor, not
# zlib's slow one; the dmg lands within a few % of the same size, minutes sooner
hdiutil create -volname "Autopoet" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"

# ── 6. notarize + staple ────────────────────────────────────────────────────
if [[ "${SKIP_NOTARY:-}" == "1" ]]; then
  say "SKIP_NOTARY=1 — signed but NOT notarized (Gatekeeper needs a manual override)"
  install_app
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

install_app

say "done → $DMG"

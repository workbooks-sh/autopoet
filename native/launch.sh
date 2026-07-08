#!/bin/bash
# Autopoet.app launcher (CFBundleExecutable). Finder double-click lands here.
#
# It wires a self-contained desktop app:
#   * READ-ONLY bundle  → the app/home surface + the mix release + ML weights, all
#     inside Contents/Resources (works from /Applications, no write access needed).
#   * WRITABLE per-user home → ~/Library/Application Support/Autopoet holds the world
#     (the seeded nexus), the cloud token, session, ctl, logs, and a per-INSTALL
#     session secret generated once here (never shipped — a baked shared secret in a
#     public app would let anyone forge sessions).
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# This script now lives at Contents/Resources/launch.sh — exec'd by the COMPILED
# launcher at Contents/MacOS/Autopoet (native/launcher.c). The main executable
# must be a real Mach-O: with a script there, macOS resolved the app's root
# process to /bin/bash, which TCC categorically refuses to prompt — the mic
# permission dialog could never appear for any child process.
HERE="$(cd "$(dirname "$0")" && pwd)"          # Contents/Resources
RES="$HERE"                                     # Contents/Resources

SUP="$HOME/Library/Application Support/Autopoet"
mkdir -p "$SUP/nexus" "$SUP/tmp"

# per-install session secret (>=16 bytes; a deployed nexus release refuses an
# ephemeral key — wb-nz88). Generated once, chmod 600, never leaves this machine.
SECRET_FILE="$SUP/session.key"
if [ ! -s "$SECRET_FILE" ]; then
  /usr/bin/openssl rand -hex 32 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

# a fresh world starts from the empty deploy manifest only — no demo data.
if [ ! -f "$SUP/nexus/index.work" ]; then
  cp "$RES/seed/index.work" "$SUP/nexus/index.work"
fi

export AUTOPOET_HOME="$RES/app-home"     # read-only SURFACE root (app/home lives under here)
export AUTOPOET_DATA="$SUP"              # writable DATA home (token/session/ctl/power-compute)
export WB_DATA="$SUP/nexus"              # the world (SQLite + workspaces)
export AUTOPOET_MODELS="$RES/models"     # bundled ML weights (Kokoro/Moonshine/Affect)
export AUTOPOET_ESPEAK="$RES/espeak/bin/espeak-ng"   # bundled phonemizer (Kokoro)
export AUTOPOET_ESPEAK_DATA="$RES/espeak/share"      # dir CONTAINING espeak-ng-data
export AUTOPOET_FRAMELESS="${AUTOPOET_FRAMELESS:-1}"   # custom stoplight chrome
export WB_SESSION_SECRET="$(cat "$SECRET_FILE")"

# Per-install secrets (LLM keys / gateway front): a Dock/Finder launch starts from a
# BARE launchd environment — a key sitting in some terminal's shell env never reaches
# the app (it only *looked* like it did when the app was opened from that terminal).
# Nexus.Secrets' env lane reads these. chmod 600, owner-only, never in the bundle.
if [ -f "$SUP/secrets.env" ]; then
  set -a; . "$SUP/secrets.env"; set +a
fi
export RELEASE_TMP="$SUP/tmp"            # release scratch — NEVER the read-only bundle

# ── desktop hardening ────────────────────────────────────────────────────────
export WB_BIND="127.0.0.1"               # loopback only — never expose the app to the LAN
export WB_SERVE="0"                      # the app supervises its OWN Nexus.Server; no second listener
export RELEASE_DISTRIBUTION="none"       # no Erlang distribution/epmd — nothing to attach to

LOG="$SUP/autopoet.log"
echo "--- autopoet launch $(date) ---" >> "$LOG"
exec "$RES/rel/bin/autopoet" start >> "$LOG" 2>&1

#!/bin/sh
# Boot the autopoet desktop shell. Everything is isolated under this directory:
# the nexus data dir, the discovery file, the traces. Close the window (or
# ./autopoetctl kill) to stop it — nothing survives the window.
set -e
cd "$(dirname "$0")"
# respect a pre-set home/data dir (a second instance — e.g. the venture desk —
# runs from the same repo with its OWN isolated home)
export AUTOPOET_HOME="${AUTOPOET_HOME:-$PWD}"
export WB_DATA="${WB_DATA:-$PWD/data/nexus}"
# frameless: the custom HTML chrome + stoplight (drag bar, traffic-light buttons)
# instead of the native macOS title bar. Set AUTOPOET_FRAMELESS=0 to use native.
export AUTOPOET_FRAMELESS="${AUTOPOET_FRAMELESS:-1}"
mkdir -p "$WB_DATA"

# inject .env secrets (OPENROUTER_API_KEY / INCEPTION_API_KEY) — Nexus.Secrets resolves
# store-first with process-env fallback, so a dev .env is the injection point.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

exec mix run --no-halt

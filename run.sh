#!/bin/sh
# Boot the autopoet desktop shell. Everything is isolated under this directory:
# the nexus data dir, the discovery file, the traces. Close the window (or
# ./autopoetctl kill) to stop it — nothing survives the window.
set -e
cd "$(dirname "$0")"
export AUTOPOET_HOME="$PWD"
export WB_DATA="$PWD/data/nexus"
mkdir -p "$WB_DATA"
exec mix run --no-halt

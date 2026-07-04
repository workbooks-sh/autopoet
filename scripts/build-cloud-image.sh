#!/usr/bin/env bash
# Build + push the autopoet CLOUD image to registry.fly.io/autopoet:<tag>.
#
# The Dockerfile's `COPY workbooks/nexus` + `COPY autopoet/` need a build context that holds BOTH, so we
# stage a PRUNED copy (nexus is ~12GB of _build/deps/.nexus/data/models we must never ship). Docker isn't
# assumed local — the build runs on Fly's remote builder.
#
#   ./scripts/build-cloud-image.sh [tag]      (tag defaults to v1)
set -euo pipefail

cd "$(dirname "$0")/.."                 # autopoet/
APPS="$(cd .. && pwd)"                  # Apps/  (parent — holds autopoet/ + workbooks/)
TAG="${1:-v1}"
APP="autopoet"
STAGE="$(mktemp -d)/ctx"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "▸ staging pruned build context → $STAGE"
mkdir -p "$STAGE/workbooks/nexus" "$STAGE/autopoet"

rsync -a --delete \
  --exclude '_build' --exclude 'deps' --exclude '.nexus' --exclude 'data' \
  --exclude 'models' --exclude '.git' --exclude 'priv/native' --exclude 'tmp' \
  "$APPS/workbooks/nexus/" "$STAGE/workbooks/nexus/"

rsync -a --delete \
  --exclude '_build' --exclude 'deps' --exclude 'data' --exclude '.git' \
  --exclude 'Autopoet.app' --exclude 'scratchpad' --exclude 'tmp' \
  "$APPS/autopoet/" "$STAGE/autopoet/"

cp "$APPS/autopoet/Dockerfile" "$STAGE/Dockerfile"

echo "▸ context size: $(du -sh "$STAGE" | cut -f1)"
echo "▸ building + pushing registry.fly.io/$APP:$TAG on Fly's remote builder…"

cd "$STAGE"
fly deploy \
  --build-only --push --remote-only \
  --dockerfile "$STAGE/Dockerfile" \
  --image-label "$TAG" \
  -a "$APP"

echo "✓ pushed registry.fly.io/$APP:$TAG"

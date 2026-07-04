#!/usr/bin/env bash
# Build + push the autopoet CLOUD image to registry.fly.io/autopoet:<tag>.
#
# The Dockerfile needs a context holding autopoet/ + workbooks/nexus + workbooks/tiny-lasers (the path
# deps). We stage a PRUNED copy — the monorepo is 60+GB of tooling/artifacts we must never ship (compilers
# is 7GB, wasm-video 1.3GB, Rust target dirs, _build/deps/data/models). Docker isn't assumed local; the
# build runs on Fly's remote builder.
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
mkdir -p "$STAGE/workbooks/nexus" "$STAGE/workbooks/tiny-lasers" "$STAGE/autopoet"

# nexus: SOURCE only — drop the multi-GB tooling/artifacts (compilers, wasm-video, build dirs, Rust targets)
rsync -a --delete \
  --exclude '_build' --exclude 'deps' --exclude '.nexus' --exclude 'data' --exclude 'models' \
  --exclude '.git' --exclude 'tmp' --exclude 'target' --exclude 'node_modules' \
  --exclude 'compilers' --exclude 'compilers-dist' --exclude 'wasm-video' --exclude 'build' \
  --exclude 'test' --exclude '*.dump' \
  "$APPS/workbooks/nexus/" "$STAGE/workbooks/nexus/"

# tiny-lasers: source only
rsync -a --delete \
  --exclude '_build' --exclude 'deps' --exclude 'target' --exclude '.git' --exclude 'tmp' --exclude 'test' \
  "$APPS/workbooks/tiny-lasers/" "$STAGE/workbooks/tiny-lasers/"

# autopoet: source only (data/models excluded — the cloud agent doesn't ship desktop weights)
rsync -a --delete \
  --exclude '_build' --exclude 'deps' --exclude 'data' --exclude '.git' --exclude 'target' \
  --exclude 'Autopoet.app' --exclude 'scratchpad' --exclude 'tmp' \
  "$APPS/autopoet/" "$STAGE/autopoet/"

cp "$APPS/autopoet/Dockerfile" "$STAGE/Dockerfile"

# minimal fly.toml so `fly deploy --build-only` can load app config (it won't deploy — build+push only)
cat > "$STAGE/fly.toml" <<TOML
app = "$APP"
primary_region = "sjc"
TOML

echo "▸ context size: $(du -sh "$STAGE" | cut -f1)"
echo "▸ building + pushing registry.fly.io/$APP:$TAG on Fly's remote builder…"

cd "$STAGE"
fly deploy \
  --build-only --push --remote-only \
  --dockerfile "$STAGE/Dockerfile" \
  --image-label "$TAG" \
  -a "$APP"

echo "✓ pushed registry.fly.io/$APP:$TAG"

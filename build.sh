#!/bin/bash
# build.sh - Build Node.js with simple-napi statically linked in.
#
# Usage:
#   ./build.sh            # full build
#   ./build.sh --clean    # clean and rebuild

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_DIR="$ROOT_DIR/deps/node"
PATCHES_DIR="$ROOT_DIR/patches"
ADDON_DIR="$ROOT_DIR/simple-napi"
ADDON_LIB="$ADDON_DIR/build/Release/simple_napi_static.a"
OUTPUT_BIN="$ROOT_DIR/build/node"

NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ "${1:-}" == "--clean" ]]; then
  info "Cleaning..."
  rm -rf "$ROOT_DIR/build"
  (cd "$ADDON_DIR" && npx node-gyp clean 2>/dev/null || true)
  if [[ -d "$NODE_DIR" ]]; then
    (cd "$NODE_DIR" && make clean 2>/dev/null || true)
    git -C "$NODE_DIR" reset --hard HEAD 2>/dev/null || true
  fi
  info "Done."
  exit 0
fi

# ── 1. Ensure Node.js submodule ──────────────────────────────────────
info "Step 1: Node.js source"
if [[ ! -f "$NODE_DIR/configure" ]]; then
  git -C "$ROOT_DIR" submodule update --init --depth 1 deps/node
fi

# ── 2. Apply patches ────────────────────────────────────────────────
info "Step 2: Applying patches"
for patch in "$PATCHES_DIR"/*.patch; do
  [[ -f "$patch" ]] || continue
  if git -C "$NODE_DIR" log --oneline | grep -qF "$(sed -n 's/^Subject: \[PATCH\] //p' "$patch")"; then
    info "  Already applied: $(basename "$patch")"
  else
    info "  Applying: $(basename "$patch")"
    git -C "$NODE_DIR" am --3way "$patch"
  fi
done

# ── 3. Build simple-napi static library ──────────────────────────────
info "Step 3: Building simple-napi"
cd "$ADDON_DIR"
if [[ ! -d node_modules ]]; then
  npm install
fi
if [[ ! -f "$ADDON_LIB" ]]; then
  npx node-gyp rebuild
fi
info "  $(nm "$ADDON_LIB" | grep -c ' T ') exported symbols in $(basename "$ADDON_LIB")"

# ── 4. Configure Node.js ────────────────────────────────────────────
info "Step 4: Configuring Node.js"
cd "$NODE_DIR"

./configure \
  --link-napi-addon "simple_napi:$ADDON_LIB" \
  --without-npm

# ── 5. Build Node.js ────────────────────────────────────────────────
info "Step 5: Building Node.js (this takes a while)..."
make -j"$NPROC"

# ── 6. Copy binary ──────────────────────────────────────────────────
info "Step 6: Output binary"
mkdir -p "$ROOT_DIR/build"
cp "$NODE_DIR/out/Release/node" "$OUTPUT_BIN"
chmod +x "$OUTPUT_BIN"

# ── 7. Test ──────────────────────────────────────────────────────────
info "Step 7: Smoke test"

"$OUTPUT_BIN" -e "
const m = process._linkedBinding('simple_napi');
console.log('hello():', m.hello());
console.log('add(3, 4):', m.add(3, 4));
console.log('fibonacci(10):', m.fibonacci(10));
console.assert(m.hello() === 'Hello from N-API!');
console.assert(m.add(3, 4) === 7);
console.assert(m.fibonacci(10) === 55);
console.log('All tests passed!');
"

info ""
info "=== Done ==="
info "Binary: $OUTPUT_BIN ($("$OUTPUT_BIN" --version), $(du -h "$OUTPUT_BIN" | cut -f1))"
info ""
info "Usage:"
info "  $OUTPUT_BIN -e \"const m = process._linkedBinding('simple_napi'); console.log(m.hello())\""

#!/usr/bin/env bash
# install-graphify.sh — install graphify at the pinned version, hash-checked (INNOV-358).
#
# The one place the graphify pin lives: /brain:init, /brain:doctor R1 and the
# graphify-smoke workflow all install through here, so a bump is one edit.
# `uv tool install` ignores --hash in constraints and --with-requirements files
# (verified on uv 0.11.17: a wrong hash installs), so download the wheel, check
# its sha256 here, and hand uv the local file. Extra args pass through to uv
# (e.g. --reinstall). The verified wheel is kept in $BRAIN_HOME/wheels
# (default ~/.brain): uv records its path in the tool receipt, so a temp path
# would leave `uv tool upgrade` failing on a file that is gone.
# ponytail: only the graphifyy wheel is hash-pinned; uv resolves its ~29
# dependencies (numpy, tree-sitter-*) from the index unhashed. Hashing the
# whole closure needs per-platform wheel hashes and an install path other than
# `uv tool install`, which takes none.
set -eu

GRAPHIFY_VERSION=0.9.79
GRAPHIFY_SHA256=51969b5ab321e369120d2d87ca1f42a169002a82bb2dad1dd7c03ee3b8773c65

wheel="graphifyy-${GRAPHIFY_VERSION}-py3-none-any.whl"
url=${GRAPHIFY_WHEEL_URL:-https://files.pythonhosted.org/packages/py3/g/graphifyy/$wheel}
dest="${BRAIN_HOME:-$HOME/.brain}/wheels"

mkdir -p "$dest"
tmp=$(mktemp -d "$dest/.download.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL "$url" -o "$tmp/$wheel"; then
  echo "install-graphify: download failed: $url" >&2
  exit 1
fi

if command -v sha256sum > /dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$wheel" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/$wheel" | cut -d' ' -f1)
fi

if [ "$actual" != "$GRAPHIFY_SHA256" ]; then
  echo "install-graphify: sha256 mismatch for $wheel - refusing to install" >&2
  echo "  expected $GRAPHIFY_SHA256" >&2
  echo "  got      $actual" >&2
  echo "  from     $url" >&2
  exit 1
fi

mv -f "$tmp/$wheel" "$dest/$wheel"
uv tool install "$dest/$wheel" "$@"

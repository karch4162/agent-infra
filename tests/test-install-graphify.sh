#!/usr/bin/env bash
# test-install-graphify.sh — brain/bin/install-graphify.sh checks the wheel's
# sha256 before uv ever sees it (INNOV-358). uv is stubbed, so nothing installs.
set -u
unset BRAIN_ROOT CLAUDE_PROJECT_DIR
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
SCRIPT=$ROOT/brain/bin/install-graphify.sh

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_LOG"
EOF
chmod +x "$tmp/bin/uv"
export UV_LOG="$tmp/uv.log"
export BRAIN_HOME="$tmp/brain-home"

run() { PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" > "$tmp/out" 2>&1; }
# file:// URL curl can open; Windows curl needs the drive-letter path.
file_url() { p=$1; command -v cygpath > /dev/null 2>&1 && p=$(cygpath -m "$p"); echo "file:///${p#/}"; }

# Negative control: a wheel whose bytes do not match the pin is refused, and uv never runs.
printf 'not the real wheel\n' > "$tmp/fake.whl"
: > "$UV_LOG"
if GRAPHIFY_WHEEL_URL=$(file_url "$tmp/fake.whl") run; then
  bad "wrong hash must exit non-zero"
else
  ok "wrong hash exits non-zero"
fi
if grep -q 'sha256 mismatch' "$tmp/out"; then
  ok "wrong hash names the mismatch"
else
  bad "wrong hash message missing: $(cat "$tmp/out")"
fi
if [ -s "$UV_LOG" ]; then
  bad "uv ran despite a wrong hash: $(cat "$UV_LOG")"
else
  ok "uv not called on a wrong hash"
fi
if ls "$BRAIN_HOME/wheels/"*.whl > /dev/null 2>&1; then
  bad "a wheel with the wrong hash was kept in $BRAIN_HOME/wheels"
else
  ok "wrong-hash wheel not kept"
fi

# A failed download is refused too, not installed from whatever is there.
: > "$UV_LOG"
if GRAPHIFY_WHEEL_URL=$(file_url "$tmp/missing.whl") run || [ -s "$UV_LOG" ]; then
  bad "a failed download must exit non-zero without calling uv"
else
  ok "failed download exits non-zero without calling uv"
fi

# Positive control: the real wheel from PyPI matches the committed hash, and
# uv is handed the local wheel file plus any pass-through args. The wheel must
# outlive the script: uv records its path in the tool receipt, and
# `uv tool upgrade` fails on a path that is gone.
: > "$UV_LOG"
if ! curl -fsSI https://pypi.org/simple/graphifyy/ > /dev/null 2>&1; then
  echo "SKIP PyPI unreachable: real-wheel hash not checked"
elif run --reinstall; then
  args=$(cat "$UV_LOG")
  case "$args" in
    "tool install --python 3.12 "*graphifyy-*-py3-none-any.whl" --reinstall") ok "pinned hash matches PyPI; uv gets the local wheel on Python 3.12" ;;
    *) bad "unexpected uv args (want --python 3.12 by default, INNOV-460): '$args'" ;;
  esac
  whl=${args#tool install --python 3.12 }; whl=${whl% --reinstall}
  case "$whl" in
    "$BRAIN_HOME"/wheels/*) ;;
    *) bad "wheel not under \$BRAIN_HOME/wheels: $whl" ;;
  esac
  if [ -f "$whl" ]; then
    ok "installed wheel kept for the uv receipt"
  else
    bad "installed wheel $whl is gone after the script exits"
  fi
  # INNOV-460: GRAPHIFY_PYTHON overrides the default interpreter.
  : > "$UV_LOG"
  if GRAPHIFY_PYTHON=3.11 run; then
    case "$(cat "$UV_LOG")" in
      "tool install --python 3.11 "*graphifyy-*-py3-none-any.whl) ok "GRAPHIFY_PYTHON overrides the interpreter" ;;
      *) bad "GRAPHIFY_PYTHON ignored: '$(cat "$UV_LOG")'" ;;
    esac
  else
    bad "GRAPHIFY_PYTHON run failed: $(cat "$tmp/out")"
  fi
else
  bad "real wheel refused: $(cat "$tmp/out")"
fi

exit $fail

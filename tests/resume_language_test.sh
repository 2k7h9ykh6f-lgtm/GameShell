#!/usr/bin/env sh

# Regression test for honoring an explicit -L when CONTINUING a GameShell game.
#
# Scenarios:
#   S1  continue + -L en      -> language switched to English, old "it" dropped
#   S2  continue + -L ''       -> gettext disabled (GSH_NO_GETTEXT=1)
#   S3  continue (no -L)       -> config left untouched (old "it" preserved)
#   S4  continue + extra arg + -L en -> positional args warned, language switched
#
# The test is host-independent: instead of booting the whole game it asserts on
#   - the persisted $GSH_CONFIG/config.sh,
#   - what a resumed session would actually see (config.sh sourced in a clean
#     subshell, via session_language), and
#   - the notes printed on stderr.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/gsh_resume_test.XXXXXX") || {
  echo "Error: could not create sandbox" >&2
  exit 1
}

cleanup() {
  chmod -R u+w "$SANDBOX" 2>/dev/null
  # plain rm: we never want the GameShell "safe" rm here
  rm -rf "$SANDBOX"
}
trap cleanup EXIT INT TERM

CONFIG="$SANDBOX/.config/config.sh"
BASELINE="$SANDBOX/baseline_config.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

assert_grep() { # desc pattern file
  if grep -q -- "$2" "$3"; then ok "$1"; else ng "$1 (missing: $2)"; fi
}
assert_no_grep() { # desc pattern file
  if grep -q -- "$2" "$3"; then ng "$1 (unexpected: $2)"; else ok "$1"; fi
}
assert_contains() { # desc needle haystack
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) ng "$1 (missing: [$2] in [$3])" ;;
  esac
}
assert_unchanged() { # desc
  if cmp -s "$CONFIG" "$BASELINE"; then ok "$1"; else ng "$1 (config.sh changed)"; fi
}

# What language / gettext state a resumed session would actually load.
session_language() {
  (
    unset LANGUAGE GSH_NO_GETTEXT
    . "$CONFIG"
    printf 'PROBE LANG=[%s] NG=[%s]\n' "${LANGUAGE:-}" "${GSH_NO_GETTEXT:-}"
  )
}

run_resume() { # outfile errfile <start.sh args...>
  out=$1
  err=$2
  shift 2
  ( cd "$SANDBOX" && sh ./start.sh "$@" ) </dev/null >"$out" 2>"$err"
}

# --- copy the repo into the sandbox (insulated from the real working tree) ---
( cd "$REPO" && tar cf - \
    --exclude='./.git' \
    --exclude='./.config' \
    --exclude='./World' \
    . ) | ( cd "$SANDBOX" && tar xf - )

# --- build a one-mission base game, then make it look GNU-Italian ------------
( cd "$SANDBOX" && sh ./start.sh -R -B -d -q -L it -c 'true' basic/01_cd_tower ) \
  </dev/null >"$SANDBOX/build.out" 2>"$SANDBOX/build.err"

if [ ! -f "$CONFIG" ]; then
  echo "Error: build did not create $CONFIG" >&2
  echo "----- build.out -----" >&2; cat "$SANDBOX/build.out" >&2
  echo "----- build.err -----" >&2; cat "$SANDBOX/build.err" >&2
  exit 1
fi

# macOS `locale` does not emit a LANGUAGE line; inject one to simulate a
# savefile created on a GNU system with the game language set to Italian.
sed -e '/^LANGUAGE=/d' -e '/^export LANGUAGE=/d' "$CONFIG" > "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
echo "export LANGUAGE=it" >> "$CONFIG"
cp "$CONFIG" "$BASELINE"

# =============================================================================
echo "# S1: continue + -L en (switch language)"
cp "$BASELINE" "$CONFIG"
run_resume "$SANDBOX/s1.out" "$SANDBOX/s1.err" -C -B -d -q -L en -c 'true'
assert_grep    "S1 config has export LANGUAGE=en"   "^export LANGUAGE=en$"   "$CONFIG"
assert_no_grep "S1 config dropped old LANGUAGE=it"  "LANGUAGE=it"            "$CONFIG"
assert_contains "S1 session loads en" "PROBE LANG=[en] NG=[]" "$(session_language)"
assert_grep    "S1 stderr notes language set to en" "set to en"             "$SANDBOX/s1.err"
assert_no_grep "S1 stderr lacks old 'ignored' note" "language is ignored"   "$SANDBOX/s1.err"

echo "# S2: continue + -L '' (disable gettext)"
cp "$BASELINE" "$CONFIG"
run_resume "$SANDBOX/s2.out" "$SANDBOX/s2.err" -C -B -d -q -L '' -c 'true'
assert_grep    "S2 config has export GSH_NO_GETTEXT=1" "^export GSH_NO_GETTEXT=1$" "$CONFIG"
assert_no_grep "S2 config dropped old LANGUAGE=it"     "LANGUAGE=it"               "$CONFIG"
assert_contains "S2 session has gettext disabled" "NG=[1]" "$(session_language)"
assert_grep    "S2 stderr notes gettext disabled"     "gettext is now disabled"   "$SANDBOX/s2.err"

echo "# S3: continue, no -L (config untouched)"
cp "$BASELINE" "$CONFIG"
run_resume "$SANDBOX/s3.out" "$SANDBOX/s3.err" -C -B -d -q -c 'true'
assert_unchanged "S3 config.sh is byte-for-byte unchanged"
assert_contains  "S3 session still loads it" "PROBE LANG=[it] NG=[]" "$(session_language)"
assert_no_grep   "S3 stderr has no language note"   "now set to"        "$SANDBOX/s3.err"
assert_no_grep   "S3 stderr has no gettext note"    "gettext is now disabled" "$SANDBOX/s3.err"

echo "# S4: continue + extra positional arg + -L en"
cp "$BASELINE" "$CONFIG"
run_resume "$SANDBOX/s4.out" "$SANDBOX/s4.err" -C -B -d -q -L en -c 'true' some_extra_arg
assert_grep     "S4 config switched to en"          "^export LANGUAGE=en$" "$CONFIG"
assert_grep     "S4 stderr warns about extra args"  "command line arguments are ignored" "$SANDBOX/s4.err"
assert_grep     "S4 stderr notes language set to en" "set to en"           "$SANDBOX/s4.err"
assert_no_grep  "S4 stderr lacks old 'ignored' note" "language is ignored" "$SANDBOX/s4.err"

# =============================================================================
echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env sh

# Regression tests for "switching language when continuing an existing game".
#
# Background: when a saved game is resumed (start.sh -C / "continue"), an
# explicit -L option used to be ignored, so a savefile created in one language
# (e.g. a teacher's Italian savefile) could not be switched back to another
# language locally. start.sh now writes the explicit choice back into the
# restored configuration ($GSH_CONFIG/config.sh) so that `gsh goal`, mission
# texts and the next save use it.
#
# These tests drive the real start.sh in "continue" mode inside an isolated,
# throw-away GSH_ROOT and check the resulting config.sh. They don't depend on
# gettext/msgfmt being installed: they assert on what gets persisted, which is
# what later turns into the runtime language (config.sh is sourced by lib/gshrc
# before gsh.sh, child `gsh` processes inherit the env, and `gsh save` archives
# config.sh).
#
# Usage: tests/test_continue_language.sh   (exit status 0 == all tests passed)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
oops() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

# Isolated sandbox so we never touch the developer's real .config/World.
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gsh-lang-test.XXXXXX") || exit 1
trap 'rm -rf "$sandbox"' EXIT INT TERM

# Build a minimal, self-contained GSH_ROOT. We copy (not symlink) the read-only
# trees so that GSH_ROOT resolves to the sandbox and nothing leaks back into the
# repository. A dummy ".git" is added so the resumed shell skips `gsh protect`,
# exactly like running GameShell from a checkout.
cp -R "$REPO/scripts" "$REPO/lib" "$REPO/i18n" "$sandbox/" || exit 1
cp "$REPO/start.sh" "$sandbox/start.sh" || exit 1
chmod +x "$sandbox/start.sh"
mkdir "$sandbox/.git" "$sandbox/World" "$sandbox/.tmp" || exit 1

# Keep temp files produced during startup inside the sandbox.
export TMPDIR="$sandbox/.tmp"

config="$sandbox/.config/config.sh"

# Recreate a config that mimics a savefile produced in Italian. It mixes:
#   - a plain locale line (must be preserved untouched),
#   - GSH_MODE (must be preserved untouched),
#   - the persisted language choice we expect start.sh to rewrite.
reset_italian_savefile() {
  rm -rf "$sandbox/.config"
  mkdir "$sandbox/.config"
  cat > "$config" <<'EOF'
LANG=it_IT.UTF-8
export GSH_MODE=ANONYMOUS
export LANGUAGE=it
EOF
  echo "test-uid" > "$sandbox/.config/uid"
}

# Run start.sh in "continue" mode (-C) non-interactively. Extra options ($@)
# carry the -L choice (or nothing). We only care about the config rewrite, which
# happens early in init_gsh, so the exit status of the later shell phase is
# irrelevant here.
run_continue() {
  ( cd "$sandbox" && ./start.sh -C -q -B "$@" -c true ) </dev/null >/dev/null 2>&1 || true
}

dump_config() {
  echo "----- $config -----" >&2
  cat "$config" >&2 2>/dev/null || echo "(missing)" >&2
  echo "-------------------" >&2
}

###########################################################################
# Scenario 1: continue an old savefile and switch language with -L en
###########################################################################
reset_italian_savefile
run_continue -L en
if grep -q '^export LANGUAGE=en$' "$config" \
  && ! grep -q 'LANGUAGE=it' "$config" \
  && ! grep -q 'GSH_NO_GETTEXT=1' "$config" \
  && grep -q '^export GSH_MODE=ANONYMOUS$' "$config" \
  && grep -q '^LANG=it_IT.UTF-8$' "$config"
then
  pass "continue + '-L en' switches the language to English (other config kept)"
else
  oops "continue + '-L en' did not persist English correctly"
  dump_config
fi

###########################################################################
# Scenario 2: continue an old savefile and disable gettext with -L ''
###########################################################################
reset_italian_savefile
run_continue -L ''
if grep -q '^export GSH_NO_GETTEXT=1$' "$config" \
  && ! grep -q 'LANGUAGE=it' "$config" \
  && grep -q '^export GSH_MODE=ANONYMOUS$' "$config"
then
  pass "continue + '-L' (empty) disables gettext and drops the old language"
else
  oops "continue + '-L' (empty) did not persist GSH_NO_GETTEXT correctly"
  dump_config
fi

###########################################################################
# Scenario 3: continue without -L must keep the previous language untouched
###########################################################################
reset_italian_savefile
before=$(cat "$config")
run_continue
after=$(cat "$config")
if [ "$before" = "$after" ] \
  && grep -q '^export LANGUAGE=it$' "$config" \
  && ! grep -q 'LANGUAGE=en' "$config" \
  && ! grep -q 'GSH_NO_GETTEXT=1' "$config"
then
  pass "continue without '-L' keeps the previous (Italian) language unchanged"
else
  oops "continue without '-L' unexpectedly modified the configuration"
  dump_config
fi

###########################################################################
echo
if [ "$fail" -eq 0 ]
then
  echo "All continue-language tests passed."
else
  echo "Some continue-language tests FAILED." >&2
fi
exit "$fail"

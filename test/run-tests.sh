#!/usr/bin/env bash
# leakcheck self-test suite.
#
# Each test builds a throwaway git repo under a tmp $LC_ROOT, runs the
# leakcheck binary against it, and asserts on output + exit code. Pure
# bash + git; no jq, no python.
#
# Usage: ./test/run-tests.sh [pattern]
# An optional substring filters which tests run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_DIR/bin/leakcheck"

PASS=0
FAIL=0
FAILURES=()

ONLY="${1:-}"

# Each test is a function. lc_test <name> <body...>; body runs with cwd set to
# a fresh tmpdir initialized as a git repo.
lc_test() {
  local name="$1"; shift
  if [[ -n "$ONLY" && "$name" != *"$ONLY"* ]]; then return; fi

  local td
  td="$(mktemp -d -t leakcheck-test.XXXXXX)"
  pushd "$td" >/dev/null
  git init -q -b dev
  git config user.email t@t
  git config user.name t

  # Run the body in a subshell so a `return 1` aborts the test, not the
  # suite. Trap teardown.
  local status=0
  (
    set -e
    "$@"
  ) || status=$?

  popd >/dev/null
  rm -rf "$td"

  if [[ "$status" -eq 0 ]]; then
    PASS=$((PASS+1))
    printf '  pass  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
  fi
}

# Helpers used inside test bodies.
seed() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  git add "$path"
}

commit() { git -c commit.gpgsign=false commit -q -m "$1"; }

assert_exit() {
  local expected="$1"; shift
  local got=0
  "$@" >/tmp/lc-out 2>/tmp/lc-err || got=$?
  if [[ "$got" -ne "$expected" ]]; then
    echo "    expected exit $expected, got $got"
    echo "    stdout: $(cat /tmp/lc-out)"
    echo "    stderr: $(cat /tmp/lc-err)"
    return 1
  fi
}

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "    expected $file to contain: $needle"
    echo "    actual: $(cat "$file")"
    return 1
  fi
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -qF -- "$needle" "$file"; then
    echo "    expected $file NOT to contain: $needle"
    echo "    actual: $(cat "$file")"
    return 1
  fi
}

# ─── tests ────────────────────────────────────────────────────────────

t_clean_repo() {
  seed README.md "Hello world."
  commit init
  assert_exit 0 "$BIN"
  assert_contains "clean" /tmp/lc-out
}

t_catches_linux_home_path() {
  seed README.md "Built on /home/alice/dev/foo."
  commit init
  assert_exit 1 "$BIN"
  assert_contains "/home/alice/" /tmp/lc-out
}

t_catches_macos_home_path() {
  seed config.json '{"path": "/Users/bob/.config"}'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "/Users/bob/" /tmp/lc-out
}

t_catches_windows_home_path() {
  seed install.md 'See C:\Users\carol\AppData for the cache.'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "Users" /tmp/lc-out
}

t_ignores_untracked_files() {
  seed README.md "Clean."
  commit init
  # Create an untracked file with a leak.
  echo "/home/eve/secret" > untracked.txt
  assert_exit 0 "$BIN"
}

t_ignores_tilde_paths_by_default() {
  seed README.md "Memory lives under ~/.claude/projects."
  commit init
  assert_exit 0 "$BIN"
}

t_ignores_elided_dots_placeholder() {
  seed README.md 'Example path: "/home/.../foo.md" — elided username.'
  seed mac.md 'On macOS: /Users/.../Library/Application Support'
  seed win.md 'On Windows: C:\Users\...\AppData'
  commit init
  assert_exit 0 "$BIN"
}

t_catches_dotted_real_username() {
  seed README.md "Built on /home/alice.smith/code."
  commit init
  assert_exit 1 "$BIN"
  assert_contains "/home/alice.smith/" /tmp/lc-out
}

t_custom_pattern_via_rc() {
  seed README.md "Built on Poseidon (a hostname)."
  cat > .leakcheckrc <<'EOF'
pattern Poseidon
EOF
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  assert_contains "Poseidon" /tmp/lc-out
}

t_allowlist_suppresses_match() {
  seed README.md "Example placeholder: /home/USERNAME/path."
  cat > .leakcheckrc <<'EOF'
allow /home/USERNAME/
EOF
  git add .leakcheckrc
  commit init
  assert_exit 0 "$BIN"
}

t_allowlist_only_matches_full_line() {
  # An allow pattern must match the file:line:text — so users can pin
  # allows to specific files like "fixtures/.*:.*:".
  seed README.md "Real leak: /home/dave/code."
  seed fixtures/sample.md "Allowed placeholder: /home/dave/foo."
  cat > .leakcheckrc <<'EOF'
allow ^fixtures/
EOF
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  assert_contains "README.md" /tmp/lc-out
  assert_not_contains "fixtures/sample.md" /tmp/lc-out
}

t_skip_glob_excludes_files() {
  seed src/main.sh "echo hello"
  seed tests/fixtures/leak.md "/home/eve/oops"
  cat > .leakcheckrc <<'EOF'
skip tests/fixtures/*
EOF
  git add .leakcheckrc
  commit init
  assert_exit 0 "$BIN"
}

t_no_defaults_disables_built_ins() {
  # README contains what would normally be a default match. Defaults off,
  # one custom pattern that won't match -> clean scan, exit 0.
  seed README.md "/home/alice/foo"
  cat > .leakcheckrc <<'EOF'
no-defaults
pattern NEVER-MATCHES-ANYTHING-ABC123
EOF
  git add .leakcheckrc
  commit init
  assert_exit 0 "$BIN"
}

t_no_defaults_with_custom_pattern_still_matches() {
  seed README.md "MYHOST is the host."
  cat > .leakcheckrc <<'EOF'
no-defaults
pattern MYHOST
EOF
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  assert_contains "MYHOST" /tmp/lc-out
}

t_no_defaults_with_no_pattern_errors() {
  seed README.md "hello"
  cat > .leakcheckrc <<'EOF'
no-defaults
EOF
  git add .leakcheckrc
  commit init
  assert_exit 2 "$BIN"
}

t_invalid_directive_errors() {
  seed README.md "hello"
  cat > .leakcheckrc <<'EOF'
nonsense foo
EOF
  git add .leakcheckrc
  commit init
  assert_exit 2 "$BIN"
}

t_blank_and_comment_lines_in_config() {
  seed README.md "INTERNAL-XYZ"
  cat > .leakcheckrc <<'EOF'
# leak patterns
pattern INTERNAL-XYZ

# done
EOF
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  assert_contains "INTERNAL-XYZ" /tmp/lc-out
}

t_list_patterns_includes_defaults() {
  seed README.md "hello"
  commit init
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "/home/" /tmp/lc-out
}

t_list_patterns_with_custom() {
  seed README.md "hello"
  cat > .leakcheckrc <<'EOF'
pattern MYHOST
EOF
  git add .leakcheckrc
  commit init
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "MYHOST" /tmp/lc-out
  assert_contains "/home/" /tmp/lc-out
}

t_list_patterns_no_defaults() {
  seed README.md "hello"
  cat > .leakcheckrc <<'EOF'
no-defaults
pattern ONLY-THIS
EOF
  git add .leakcheckrc
  commit init
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "ONLY-THIS" /tmp/lc-out
  assert_not_contains "/home/" /tmp/lc-out
}

t_json_clean() {
  seed README.md "Hello."
  commit init
  assert_exit 0 "$BIN" --json
  assert_contains '"clean":true' /tmp/lc-out
  assert_contains '"count":0' /tmp/lc-out
  assert_contains '"hits":[]' /tmp/lc-out
}

t_json_with_hits() {
  seed README.md "/home/alice/foo"
  commit init
  assert_exit 1 "$BIN" --json
  assert_contains '"clean":false' /tmp/lc-out
  assert_contains '"count":1' /tmp/lc-out
  assert_contains '"file":"README.md"' /tmp/lc-out
  assert_contains '"line":1' /tmp/lc-out
}

t_json_escapes_quotes_and_backslash() {
  # A line with both quotes and a backslash, on top of a default-pattern
  # match. JSON document must remain parseable and recoverable.
  seed README.md 'See "/home/dave/code" \(also \"escaped\"\) for details.'
  commit init
  assert_exit 1 "$BIN" --json
  python3 <<'PY'
import json
doc = json.loads(open("/tmp/lc-out").read())
assert doc["count"] >= 1, doc
hit = doc["hits"][0]
assert hit["file"] == "README.md", hit
assert "dave" in hit["text"], hit
# Round-trip: the text field should contain a literal backslash and a
# literal double-quote (decoded from the JSON).
assert '"' in hit["text"], hit
assert '\\' in hit["text"], hit
PY
}

t_skips_binary_files() {
  # A real binary file with a leak-shaped byte sequence in it. grep -I
  # should make leakcheck skip it.
  printf '/home/eve/oops\x00\x01\x02\x03binary' > blob.bin
  git add blob.bin
  commit init
  assert_exit 0 "$BIN"
}

t_runs_outside_repo_errors() {
  # Repo init happened — but cd to a non-repo via --root and confirm error.
  seed README.md "hi"
  commit init
  local nogit
  nogit="$(mktemp -d)"
  assert_exit 2 "$BIN" --root "$nogit"
  rm -rf "$nogit"
}

t_multiple_patterns_compound() {
  seed README.md "/home/alice/foo and MYHOST live here"
  cat > .leakcheckrc <<'EOF'
pattern MYHOST
EOF
  git add .leakcheckrc
  commit init
  # Should hit 2 lines (both patterns matched line 1 of README.md — separate hits).
  assert_exit 1 "$BIN"
  local hits
  hits=$(grep -c "README.md" /tmp/lc-out)
  if [[ "$hits" -ne 2 ]]; then
    echo "    expected 2 README.md hits, got $hits"
    cat /tmp/lc-out
    return 1
  fi
}

t_unicode_in_content_does_not_crash() {
  seed README.md $'/home/zoë/code'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "home" /tmp/lc-out
}

t_filename_with_space() {
  mkdir -p sub
  printf '%s\n' "/home/alice/foo" > "sub/file with space.md"
  git add "sub/file with space.md"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "file with space" /tmp/lc-out
}

# Regression: a filename containing a literal colon is legal on Linux/macOS
# and used to mis-parse the `file:line:text` boundary, producing malformed
# JSON (`"line":colon.md`). The fix iterates per-file in pass 1 so the
# filename never appears in the grep output.
t_filename_with_colon_json_valid() {
  mkdir -p sub
  printf '%s\n' "/home/alice/foo" > "sub/has:colon.md"
  git add "sub/has:colon.md"
  commit init
  assert_exit 1 "$BIN" --json
  python3 -m json.tool </tmp/lc-out >/dev/null
  assert_contains '"file":"sub/has:colon.md"' /tmp/lc-out
  assert_contains '"line":1' /tmp/lc-out
}

# ─── runner ───────────────────────────────────────────────────────────

echo "leakcheck self-tests"
echo

lc_test "clean repo (no leaks, no config)"           t_clean_repo
lc_test "catches Linux home path"                    t_catches_linux_home_path
lc_test "catches macOS home path"                    t_catches_macos_home_path
lc_test "catches Windows home path"                  t_catches_windows_home_path
lc_test "ignores untracked files"                    t_ignores_untracked_files
lc_test "tilde paths not flagged by default"         t_ignores_tilde_paths_by_default
lc_test "elided-dots placeholder not flagged"        t_ignores_elided_dots_placeholder
lc_test "dotted real username still flagged"         t_catches_dotted_real_username
lc_test "custom pattern via .leakcheckrc"            t_custom_pattern_via_rc
lc_test "allowlist suppresses match"                 t_allowlist_suppresses_match
lc_test "allowlist scoped by full-line regex"        t_allowlist_only_matches_full_line
lc_test "skip glob excludes files"                   t_skip_glob_excludes_files
lc_test "no-defaults disables built-ins"             t_no_defaults_disables_built_ins
lc_test "no-defaults + custom pattern still matches" t_no_defaults_with_custom_pattern_still_matches
lc_test "no-defaults with no pattern errors"         t_no_defaults_with_no_pattern_errors
lc_test "invalid directive errors"                   t_invalid_directive_errors
lc_test "blank + comment lines in config tolerated"  t_blank_and_comment_lines_in_config
lc_test "--list-patterns shows defaults"             t_list_patterns_includes_defaults
lc_test "--list-patterns + custom pattern"           t_list_patterns_with_custom
lc_test "--list-patterns under no-defaults"          t_list_patterns_no_defaults
lc_test "--json shape on clean repo"                 t_json_clean
lc_test "--json shape with hits"                     t_json_with_hits
lc_test "--json escapes quotes + backslashes"        t_json_escapes_quotes_and_backslash
lc_test "skips binary files (grep -I)"               t_skips_binary_files
lc_test "--root pointing at non-repo errors"         t_runs_outside_repo_errors
lc_test "multiple patterns compound (N hits)"        t_multiple_patterns_compound
lc_test "unicode in content does not crash"          t_unicode_in_content_does_not_crash
lc_test "filename with space handled"                t_filename_with_space
lc_test "filename with colon yields valid JSON"      t_filename_with_colon_json_valid

echo
echo "  $PASS passed  ·  $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0

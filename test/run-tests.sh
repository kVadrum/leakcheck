#!/usr/bin/env bash
# leakcheck self-test suite.
#
# Each test builds a throwaway git repo under $TMPDIR, runs the leakcheck
# binary against it, and asserts on output + exit code. Needs bash >= 4.4,
# git and python3 (JSON round-trip checks) — python3 is a dependency of this
# suite only, never of bin/leakcheck. Output files are per-run, so two runs
# can share a box without clobbering each other's assertions.
#
# Usage: ./test/run-tests.sh [pattern]
# An optional substring filters which tests run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# LEAKCHECK_BIN runs the suite against another build (a counterfactual check).
BIN="${LEAKCHECK_BIN:-$REPO_DIR/bin/leakcheck}"

PASS=0
FAIL=0
FAILURES=()

ONLY="${1:-}"

LC_OUT="$(mktemp -t lc-out.XXXXXX)"
LC_ERR="$(mktemp -t lc-err.XXXXXX)"
trap 'rm -f "$LC_OUT" "$LC_ERR"' EXIT

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

  # Run the body in a subshell so a failed assert aborts the test, not the
  # suite. NOT `( ... ) || status=$?`: a subshell on the left of `||` runs
  # with errexit ignored, so until v0.3.0 only each test's LAST command was
  # enforced and every earlier assert was decoration.
  local status=0
  (
    set -e
    "$@"
  )
  status=$?

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

# Host hooks (a global core.hooksPath) must not judge fixture commits.
commit() { git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$1"; }

assert_exit() {
  local expected="$1"; shift
  local got=0
  "$@" >"$LC_OUT" 2>"$LC_ERR" || got=$?
  if [[ "$got" -ne "$expected" ]]; then
    echo "    expected exit $expected, got $got"
    echo "    stdout: $(cat "$LC_OUT")"
    echo "    stderr: $(cat "$LC_ERR")"
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
  assert_contains "clean" "$LC_OUT"
}

t_catches_linux_home_path() {
  seed README.md "Built on /home/alice/dev/foo."
  commit init
  assert_exit 1 "$BIN"
  assert_contains "/home/alice/" "$LC_OUT"
}

t_catches_macos_home_path() {
  seed config.json '{"path": "/Users/bob/.config"}'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "/Users/bob/" "$LC_OUT"
}

t_catches_windows_home_path() {
  seed install.md 'See C:\Users\carol\AppData for the cache.'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "Users" "$LC_OUT"
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
  assert_contains "/home/alice.smith/" "$LC_OUT"
}

t_custom_pattern_via_rc() {
  seed README.md "Built on examplehost (a hostname)."
  cat > .leakcheckrc <<'EOF'
pattern examplehost
EOF
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  assert_contains "examplehost" "$LC_OUT"
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
  assert_contains "README.md" "$LC_OUT"
  assert_not_contains "fixtures/sample.md" "$LC_OUT"
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
  assert_contains "MYHOST" "$LC_OUT"
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
  assert_contains "INTERNAL-XYZ" "$LC_OUT"
}

t_list_patterns_includes_defaults() {
  seed README.md "hello"
  commit init
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "/home/" "$LC_OUT"
}

t_list_patterns_with_custom() {
  seed README.md "hello"
  cat > .leakcheckrc <<'EOF'
pattern MYHOST
EOF
  git add .leakcheckrc
  commit init
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "MYHOST" "$LC_OUT"
  assert_contains "/home/" "$LC_OUT"
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
  assert_contains "ONLY-THIS" "$LC_OUT"
  assert_not_contains "/home/" "$LC_OUT"
}

t_json_clean() {
  seed README.md "Hello."
  commit init
  assert_exit 0 "$BIN" --json
  assert_contains '"clean":true' "$LC_OUT"
  assert_contains '"count":0' "$LC_OUT"
  assert_contains '"hits":[]' "$LC_OUT"
}

t_json_with_hits() {
  seed README.md "/home/alice/foo"
  commit init
  assert_exit 1 "$BIN" --json
  assert_contains '"clean":false' "$LC_OUT"
  assert_contains '"count":1' "$LC_OUT"
  assert_contains '"file":"README.md"' "$LC_OUT"
  assert_contains '"line":1' "$LC_OUT"
}

t_json_escapes_quotes_and_backslash() {
  # A line with both quotes and a backslash, on top of a default-pattern
  # match. JSON document must remain parseable and recoverable.
  seed README.md 'See "/home/dave/code" \(also \"escaped\"\) for details.'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1]).read())
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
  hits=$(grep -c "README.md" "$LC_OUT")
  if [[ "$hits" -ne 2 ]]; then
    echo "    expected 2 README.md hits, got $hits"
    cat "$LC_OUT"
    return 1
  fi
}

t_unicode_in_content_does_not_crash() {
  # Pins "does not crash", not a match on the non-ASCII name: the defaults'
  # [A-Za-z] is ASCII under git's ERE in every locale. v0.2.2 matched
  # /home/zoë/ only where GNU grep's ranges took in ë (en_US.UTF-8, not C).
  seed README.md $'/home/zoë/code\n/home/alice/code'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "README.md:2:" "$LC_OUT"
}

t_filename_with_space() {
  mkdir -p sub
  printf '%s\n' "/home/alice/foo" > "sub/file with space.md"
  git add "sub/file with space.md"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "file with space" "$LC_OUT"
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
  python3 -m json.tool <"$LC_OUT" >/dev/null
  assert_contains '"file":"sub/has:colon.md"' "$LC_OUT"
  assert_contains '"line":1' "$LC_OUT"
}

# ─── v0.3.0: a scan error or a shrunken scope never reads as clean ────

rc_file() { printf '%s\n' "$@" > .leakcheckrc; git add .leakcheckrc; }

t_invalid_pattern_regex_errors() {
  seed README.md "MYHOST"
  rc_file 'no-defaults' 'pattern MY(HOST'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "MY(HOST" "$LC_ERR"
  assert_not_contains "clean" "$LC_OUT"
}

t_invalid_pattern_regex_errors_on_empty_repo() {
  rc_file 'pattern MY(HOST'
  git rm -q --cached .leakcheckrc
  assert_exit 2 "$BIN"
}

t_invalid_allow_regex_errors_even_when_clean() {
  # Compiled up front: a broken rule fails on a clean repo, not only on the
  # day it first has a hit to judge.
  seed README.md "hello"
  rc_file 'allow a(b'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "a(b" "$LC_ERR"
}

t_empty_directives_error() {
  seed README.md "hello"
  commit init
  local d
  for d in pattern allow skip; do
    printf '%s\n' "$d" > .leakcheckrc
    assert_exit 2 "$BIN"
    assert_contains "empty $d directive" "$LC_ERR"
  done
}

t_crlf_config_still_matches() {
  seed README.md "MYHOST"
  printf 'pattern MYHOST\r\n' > .leakcheckrc
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
}

t_missing_config_errors() {
  seed README.md "MYHOST"
  commit init
  assert_exit 2 "$BIN" --config nope.rc
  assert_contains "config not found: nope.rc" "$LC_ERR"
  assert_exit 2 "$BIN" --list-patterns --config nope.rc
}

t_config_flag_needs_value() {
  seed README.md "hello"
  commit init
  assert_exit 2 "$BIN" --config
  assert_exit 2 "$BIN" --root
}

t_dangling_symlink_config_errors() {
  seed README.md "hello"
  commit init
  ln -s does-not-exist .leakcheckrc
  assert_exit 2 "$BIN"
}

t_absolute_config_outside_repo() {
  seed README.md "MYHOST lives here"
  commit init
  local cfg
  cfg="$(mktemp)"
  printf 'pattern MYHOST\n' > "$cfg"
  assert_exit 1 "$BIN" --config "$cfg"
  rm -f "$cfg"
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
}

t_absolute_config_inside_repo_is_self_skipped() {
  seed README.md "clean"
  seed conf/leak.rc "pattern MYHOST"
  commit init
  assert_exit 0 "$BIN" --config "$PWD/conf/leak.rc"
  # Positive control: the same pattern does fire on other files.
  seed other.md "MYHOST"
  assert_exit 1 "$BIN" --config "$PWD/conf/leak.rc"
  assert_contains "other.md:1:" "$LC_OUT"
  assert_not_contains "conf/leak.rc" "$LC_OUT"
}

t_relative_config_resolves_against_root() {
  seed README.md "MYHOST"
  printf 'pattern MYHOST\n' > cfg.rc
  commit init
  local here="$PWD"
  (cd / && assert_exit 1 "$BIN" --root "$here" --config cfg.rc)
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
}

t_relative_config_resolves_against_subdir_cwd() {
  seed README.md "MYHOST"
  seed sub/b.md "ok"
  printf 'pattern MYHOST\n' > cfg.rc
  commit init
  (cd sub && assert_exit 1 "$BIN" --config ../cfg.rc)
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
}

t_subdirectory_scans_whole_repo() {
  seed README.md "/home/alice/x"
  seed sub/b.md "ok"
  commit init
  (cd sub && assert_exit 1 "$BIN")
  assert_contains "README.md:1:" "$LC_OUT"
  assert_contains "scanned 2 tracked files" "$LC_ERR"
}

t_subdirectory_reads_root_config() {
  seed README.md "MYHOST"
  seed sub/b.md "ok"
  rc_file 'pattern MYHOST'
  commit init
  (cd sub && assert_exit 1 "$BIN")
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
}

t_skip_is_top_relative_from_subdirectory() {
  seed sub/fixtures/leak.md "/home/eve/oops"
  seed sub/a.md "ok"
  rc_file 'skip sub/fixtures/*'
  commit init
  (cd sub && assert_exit 0 "$BIN")
  # The skipped file and the config itself.
  assert_contains "2 skipped by config" "$LC_OUT"
}

t_staged_leak_with_clean_worktree() {
  seed a.md "clean"
  commit init
  printf '/home/alice/x\n' > a.md
  git add a.md
  printf 'clean\n' > a.md
  assert_exit 1 "$BIN" --json
  assert_contains '"source":"index"' "$LC_OUT"
}

t_unstaged_worktree_leak() {
  seed a.md "clean"
  commit init
  printf '/home/alice/x\n' > a.md
  assert_exit 1 "$BIN" --json
  assert_contains '"source":"worktree"' "$LC_OUT"
}

t_intent_to_add_file() {
  # `git add -N` puts an empty blob in the index: only the worktree pass
  # can see the content.
  seed a.md "clean"
  commit init
  printf '/home/alice/x\n' > new.md
  git add -N new.md
  assert_exit 1 "$BIN"
  assert_contains "new.md:1:" "$LC_OUT"
}

t_deleted_from_worktree() {
  seed a.md "/home/alice/x"
  commit init
  rm a.md
  assert_exit 1 "$BIN"
  assert_contains "a.md:1:" "$LC_OUT"
}

t_hit_in_both_reported_once() {
  seed a.md "/home/alice/x"
  commit init
  assert_exit 1 "$BIN" --json
  assert_contains '"count":1,' "$LC_OUT"
  assert_contains '"source":"both"' "$LC_OUT"
}

t_leak_in_filename() {
  seed "docs/notes-from-MYHOST.md" "hi"
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "docs/notes-from-MYHOST.md:0: [MYHOST] docs/notes-from-MYHOST.md" "$LC_OUT"
}

t_filename_hit_is_allowable() {
  seed "docs/notes-from-MYHOST.md" "hi"
  rc_file 'pattern MYHOST' 'allow ^docs/notes-from-MYHOST\.md:0:'
  commit init
  assert_exit 0 "$BIN" --json
  assert_contains '"count":1}' "$LC_OUT"
}

t_symlink_target_scanned() {
  ln -s /home/alice/proj/secret.txt link
  git add link
  commit init
  assert_exit 1 "$BIN"
  assert_contains "link:0: [" "$LC_OUT"
  assert_contains "-> /home/alice/proj/secret.txt" "$LC_OUT"
}

t_worktree_only_symlink_target() {
  ln -s clean-target link
  git add link
  commit init
  rm link
  ln -s /home/alice/x link
  assert_exit 1 "$BIN" --json
  assert_contains '"source":"worktree"' "$LC_OUT"
}

t_allow_counts_are_reported() {
  seed a.md "/home/alice/x"
  rc_file 'allow .'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 allowed" "$LC_OUT"
  assert_exit 0 "$BIN" --json
  assert_contains '"allowed":[{"rule":".","count":1}]' "$LC_OUT"
}

t_binary_is_counted() {
  printf '/home/eve/oops\x00\x01binary' > blob.bin
  git add blob.bin
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 binary skipped" "$LC_OUT"
}

t_strict_reports_binary() {
  printf '/home/eve/oops\x00\x01binary' > blob.bin
  git add blob.bin
  commit init
  assert_exit 1 "$BIN" --strict
  assert_contains "blob.bin:0: [unscanned:binary]" "$LC_OUT"
}

t_strict_on_fully_scanned_repo_is_clean() {
  seed README.md "hello"
  commit init
  assert_exit 0 "$BIN" --strict
}

t_submodule_counted_and_strict() {
  seed a.md "ok"
  git update-index --add --cacheinfo "160000,$(git hash-object -t tree /dev/null),vendor/lib"
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 submodules not scanned" "$LC_OUT"
  assert_exit 1 "$BIN" --strict
  assert_contains "vendor/lib:0: [unscanned:submodule]" "$LC_OUT"
}

t_utf16_is_counted_as_binary() {
  # UTF-16LE of "/home/alice/x\n": every other byte is NUL.
  printf '/\0h\0o\0m\0e\0/\0a\0l\0i\0c\0e\0/\0x\0\n\0' > u16.txt
  git add u16.txt
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 binary skipped" "$LC_OUT"
  assert_exit 1 "$BIN" --strict
  assert_contains "u16.txt:0: [unscanned:binary]" "$LC_OUT"
}

t_nul_past_sniff_window_is_scanned() {
  # git sniffs the first 8000 bytes for NUL; this file's first NUL sits past
  # them, so it is text to the scan — and the count must agree with that.
  { printf '/home/alice/x\n'; head -c 9000 /dev/zero | tr '\0' 'a'; printf '\n\0tail\n'; } > late.txt
  git add late.txt
  commit init
  assert_exit 1 "$BIN" --json
  assert_contains '"file":"late.txt","line":1,' "$LC_OUT"
  assert_contains '"binary":0,' "$LC_OUT"
}

t_gitattributes_binary_does_not_hide_text() {
  # `*.svg binary` is a common .gitattributes line; an Inkscape SVG is text and can
  # carry its author's home path.
  seed a.svg '<svg d="/home/alice/x"/>'
  seed .gitattributes '*.svg binary'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.svg:1:" "$LC_OUT"
}

t_grep_column_config_does_not_shift_parse() {
  git config grep.column true
  seed a.md "/home/alice/x"
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1]).read())
hit = doc["hits"][0]
assert hit["file"] == "a.md" and hit["line"] == 1, hit
assert hit["text"] == "/home/alice/x", hit
PY
}

t_unreadable_worktree_file_errors() {
  # git grep reports it on stderr and still exits 1; that must not read as
  # "no match".
  [[ "$(id -u)" -ne 0 ]] || return 0   # root reads everything
  seed a.md "ok"
  commit init
  chmod 000 a.md
  local got=0
  "$BIN" >"$LC_OUT" 2>"$LC_ERR" || got=$?
  chmod 644 a.md
  [[ "$got" -eq 2 ]] || { echo "    expected exit 2, got $got"; cat "$LC_ERR"; return 1; }
  assert_contains "scan error" "$LC_ERR"
}

t_newline_in_filename_json_valid() {
  local f=$'sub/two\nlines.md'
  mkdir -p sub
  printf '/home/alice/x\n' > "$f"
  git add -- "$f"
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1]).read())
assert any(h["file"] == "sub/two\nlines.md" and h["line"] == 1 for h in doc["hits"]), doc
PY
}

t_empty_repo_reports_zero() {
  assert_exit 0 "$BIN"
  assert_contains "0 matches across 0 tracked files" "$LC_OUT"
  assert_exit 0 "$BIN" --json
  assert_contains '"tracked":0,' "$LC_OUT"
}

t_hits_mode_scope_line_and_count_contract() {
  seed a.md "/home/alice/x"
  commit init
  assert_exit 1 "$BIN"
  # Callers parse this line anchored (^…$); it must stay byte-identical.
  /usr/bin/grep -Eqx 'leakcheck: 1 match\(es\)' "$LC_ERR" \
    || { echo "    count line missing or changed"; cat "$LC_ERR"; return 1; }
  assert_contains "leakcheck: scanned 1 tracked files (index + worktree;" "$LC_ERR"
}

t_history_not_scanned_is_stated() {
  seed a.md "/home/alice/x"
  commit one
  seed a.md "clean"
  commit two
  assert_exit 0 "$BIN"
  assert_contains "history not scanned" "$LC_OUT"
}

t_json_envelope_prefix_and_new_fields() {
  seed README.md "Hello."
  commit init
  assert_exit 0 "$BIN" --json
  assert_contains '"clean":true,"count":0,"hits":[],"target":"index+worktree",' "$LC_OUT"
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1]).read())
assert doc["tracked"] == 1 and doc["history_scanned"] is False, doc
assert doc["skipped"] == {"binary": 0, "submodule": 0, "config": 0}, doc
assert doc["symlinks"] == 0 and doc["allowed"] == [], doc
PY
}

t_help_lists_every_flag() {
  # The script header is --help: a flag missing there is undiscoverable.
  assert_exit 0 "$BIN" --help
  local f
  for f in --strict --json --list-patterns --config --root --version --help; do
    assert_contains "$f" "$LC_OUT"
  done
}

t_symlink_replaced_by_regular_file() {
  # git grep's worktree pass follows the index mode and skips the path;
  # `git commit -a` would stage the new regular file.
  ln -s clean-target link
  git add link
  commit init
  rm link
  printf '/home/alice/x\n' > link
  assert_exit 1 "$BIN" --json
  assert_contains '"file":"link","line":1,' "$LC_OUT"
  assert_contains '"source":"worktree"' "$LC_OUT"
}

t_gitlink_replaced_by_regular_file() {
  seed a.md "ok"
  git update-index --add --cacheinfo "160000,$(git hash-object -t tree /dev/null),sub"
  commit init
  printf '/home/alice/x\n' > sub
  assert_exit 1 "$BIN"
  assert_contains "sub:1:" "$LC_OUT"
}

t_type_changed_binary_is_counted() {
  ln -s clean-target link
  git add link
  commit init
  rm link
  printf 'bin\0ary' > link
  assert_exit 0 "$BIN"
  assert_contains "1 binary skipped" "$LC_OUT"
  assert_exit 1 "$BIN" --strict
  assert_contains "link:0: [unscanned:binary]" "$LC_OUT"
}

t_config_symlink_target_scanned() {
  # The config's CONTENT is skipped; its stored symlink target is published.
  local real
  real="$(mktemp -d)/MYHOST"
  mkdir -p "$real"
  printf 'pattern MYHOST\n' > "$real/private.rc"
  ln -s "$real/private.rc" .leakcheckrc
  seed a.md "ok"
  git add .leakcheckrc
  commit init
  assert_exit 1 "$BIN"
  rm -rf "$(dirname "$real")"
  assert_contains ".leakcheckrc:0: [MYHOST] -> " "$LC_OUT"
}

t_non_utf8_bytes_yield_valid_json() {
  # A legacy (Latin-1) filename and line: one stray byte used to make the
  # whole envelope unparseable.
  printf '/home/alice/x caf\xe9\n' > "$(printf 'caf\xe9.md')"
  git add -A
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], "rb").read().decode("utf-8"))
hit = doc["hits"][0]
assert hit["file"] == "caf�.md", hit
assert hit["text"] == "/home/alice/x caf�", hit
PY
}

t_valid_utf8_passes_through_json() {
  seed "notes-zoë.md" "/home/alice/x — déjà vu 日本"
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], "rb").read().decode("utf-8"))
hit = doc["hits"][0]
assert hit["file"] == "notes-zoë.md", hit
assert hit["text"] == "/home/alice/x — déjà vu 日本", hit
PY
}

t_newline_in_filename_text_is_one_line() {
  local f=$'sub/two\nlines.md'
  mkdir -p sub
  printf '/home/alice/x\n' > "$f"
  git add -- "$f"
  commit init
  assert_exit 1 "$BIN"
  assert_contains '"sub/two\nlines.md":1: [' "$LC_OUT"
  local n
  n=$(wc -l < "$LC_OUT")
  [[ "$n" -eq 1 ]] || { echo "    expected 1 line, got $n"; cat "$LC_OUT"; return 1; }
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
lc_test "invalid pattern ERE errors (exit 2)"         t_invalid_pattern_regex_errors
lc_test "invalid pattern ERE errors on empty index"   t_invalid_pattern_regex_errors_on_empty_repo
lc_test "invalid allow ERE errors even when clean"    t_invalid_allow_regex_errors_even_when_clean
lc_test "empty pattern/allow/skip directives error"   t_empty_directives_error
lc_test "CRLF config still matches"                   t_crlf_config_still_matches
lc_test "missing --config errors"                     t_missing_config_errors
lc_test "--config / --root need a value"              t_config_flag_needs_value
lc_test "dangling-symlink .leakcheckrc errors"        t_dangling_symlink_config_errors
lc_test "absolute --config outside the repo works"    t_absolute_config_outside_repo
lc_test "absolute --config inside repo self-skipped"  t_absolute_config_inside_repo_is_self_skipped
lc_test "relative --config resolves against --root"   t_relative_config_resolves_against_root
lc_test "relative --config resolves against subdir"   t_relative_config_resolves_against_subdir_cwd
lc_test "subdirectory run scans the whole repo"       t_subdirectory_scans_whole_repo
lc_test "subdirectory run reads the root config"      t_subdirectory_reads_root_config
lc_test "skip is top-relative from a subdirectory"    t_skip_is_top_relative_from_subdirectory
lc_test "staged leak, clean worktree: found"          t_staged_leak_with_clean_worktree
lc_test "unstaged worktree leak: found"               t_unstaged_worktree_leak
lc_test "intent-to-add file: found"                   t_intent_to_add_file
lc_test "tracked file deleted from worktree: found"   t_deleted_from_worktree
lc_test "index+worktree hit reported once"            t_hit_in_both_reported_once
lc_test "leak in a filename: line-0 hit"              t_leak_in_filename
lc_test "filename hit is allowable"                   t_filename_hit_is_allowable
lc_test "symlink target scanned"                      t_symlink_target_scanned
lc_test "worktree-only symlink target scanned"        t_worktree_only_symlink_target
lc_test "allow suppressions are counted"              t_allow_counts_are_reported
lc_test "binary files are counted"                    t_binary_is_counted
lc_test "--strict reports binary files"               t_strict_reports_binary
lc_test "--strict on a fully scanned repo is clean"   t_strict_on_fully_scanned_repo_is_clean
lc_test "submodule counted; --strict reports it"      t_submodule_counted_and_strict
lc_test "UTF-16 counted as binary"                    t_utf16_is_counted_as_binary
lc_test "NUL past git's sniff window: scanned"        t_nul_past_sniff_window_is_scanned
lc_test ".gitattributes binary does not hide text"    t_gitattributes_binary_does_not_hide_text
lc_test "grep.column=true does not shift the parse"   t_grep_column_config_does_not_shift_parse
lc_test "unreadable worktree file is a scan error"    t_unreadable_worktree_file_errors
lc_test "newline in filename yields valid JSON"       t_newline_in_filename_json_valid
lc_test "empty repo reports its zero"                 t_empty_repo_reports_zero
lc_test "hits mode: scope line + count contract"      t_hits_mode_scope_line_and_count_contract
lc_test "clean verdict says history not scanned"      t_history_not_scanned_is_stated
lc_test "--json prefix stable, new fields present"    t_json_envelope_prefix_and_new_fields
lc_test "--help lists every flag"                     t_help_lists_every_flag
lc_test "symlink replaced by a regular file: scanned" t_symlink_replaced_by_regular_file
lc_test "gitlink replaced by a regular file: scanned" t_gitlink_replaced_by_regular_file
lc_test "type-changed binary is counted"              t_type_changed_binary_is_counted
lc_test "config symlink target is scanned"            t_config_symlink_target_scanned
lc_test "non-UTF-8 bytes yield valid JSON"            t_non_utf8_bytes_yield_valid_json
lc_test "valid UTF-8 passes through JSON intact"      t_valid_utf8_passes_through_json
lc_test "newline in filename: one text-mode line"     t_newline_in_filename_text_is_one_line

echo
echo "  $PASS passed  ·  $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0

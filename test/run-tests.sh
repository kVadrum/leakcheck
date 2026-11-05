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
  # Both lines hit, in every locale: the ASCII line through the canonical
  # default, the non-ASCII one through its own (v0.4.0). v0.2.2 matched
  # /home/zoë/ only where GNU grep's ranges took in ë (en_US.UTF-8, not C).
  seed README.md $'/home/zoë/code\n/home/alice/code'
  commit init
  LC_ALL=C assert_exit 1 "$BIN"
  assert_contains "README.md:1:" "$LC_OUT"
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
  for f in --strict --history --history-range --json --list-patterns --config --root --version --help; do
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

# ─── v0.4.0: wider defaults, .leakcheckrc.local ───────────────────────

# Every default hits its own shape once — git grep reports one hit per
# (line, pattern), so two overlapping defaults would double-count.
t_defaults_each_shape_hits_exactly_once() {
  cat > shapes.txt <<'EOF'
/home/alice/x
/Users/alice/x
C:\Users\alice\x
{"p":"\/home\/alice\/x"}
{"w":"C:\\Users\\alice\\x"}
c:\users\alice\x
D:\Users\alice\x
C:\USERS\alice\x
/home/zoë/x
C:\Users\José\AppData
{"p":"\/home\/zoë\/x"}
EOF
  git add shapes.txt
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys, collections
doc = json.loads(open(sys.argv[1], "rb").read().decode("utf-8"))
lines = collections.Counter(h["line"] for h in doc["hits"])
assert sorted(lines) == list(range(1, 12)), sorted(lines)
assert set(lines.values()) == {1}, lines
PY
}

t_defaults_same_in_c_locale() {
  printf '%s\n' '/home/zoë/x' '{"p":"\/home\/alice\/x"}' 'c:\users\alice\x' > a.txt
  git add a.txt
  commit init
  LC_ALL=C assert_exit 1 "$BIN" --json
  assert_contains '"count":3,' "$LC_OUT"
}

t_default_placeholders_stay_clean() {
  # Guard (passes on v0.3.0 too, by design): the elided placeholders,
  # ASCII and typographic, stay clean in every shape the defaults gained.
  printf '%s\n' '/home/…/foo' 'C:\Users\…\AppData' '{"p":"\/home\/...\/x"}' '{"p":"\/home\/…\/x"}' \
    '{"w":"C:\\Users\\...\\x"}' 'c:\users\...\x' '/home/<user>/x' > a.txt
  git add a.txt
  commit init
  assert_exit 0 "$BIN"
  LC_ALL=C assert_exit 0 "$BIN"
}

t_no_trailing_slash_is_a_recipe_not_a_default() {
  # Guard (passes on v0.3.0 too, by design): pins the measured ruling that
  # this shape stays opt-in, and that the README recipe works when opted in.
  printf '%s\n' '"cwd": "/home/alice"' > a.json
  git add a.json
  commit init
  assert_exit 0 "$BIN"
  # The README recipe, opted into, does fire.
  printf '%s\n' 'pattern (^|[^A-Za-z0-9_./-])/(home|Users)/[A-Za-z0-9_][A-Za-z0-9_.-]*(["'"'"'`[:space:]]|$)' > .leakcheckrc
  assert_exit 1 "$BIN"
  assert_contains "a.json:1:" "$LC_OUT"
}

t_local_config_is_read() {
  seed README.md "MYHOST"
  commit init
  printf 'pattern MYHOST\n' > .leakcheckrc.local
  assert_exit 1 "$BIN"
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
}

t_local_config_adds_to_main_config() {
  seed README.md $'MYHOST\nINTERNAL-XYZ'
  rc_file 'pattern MYHOST'
  commit init
  printf 'pattern INTERNAL-XYZ\n' > .leakcheckrc.local
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "MYHOST" "$LC_OUT"
  assert_contains "INTERNAL-XYZ" "$LC_OUT"
  assert_exit 1 "$BIN"
  assert_contains "README.md:1: [MYHOST]" "$LC_OUT"
  assert_contains "README.md:2: [INTERNAL-XYZ]" "$LC_OUT"
}

t_explicit_config_ignores_local() {
  # Guard (passes on v0.3.0 too, which never read .local): --config stays
  # the whole config once .local exists.
  seed README.md "MYHOST"
  commit init
  printf 'pattern MYHOST\n' > .leakcheckrc.local
  printf 'pattern NEVER-MATCHES-ABC123\n' > other.rc
  assert_exit 0 "$BIN" --config other.rc
}

t_tracked_local_config_reports_itself() {
  # Committing the .local config publishes the inventory of tells; unlike
  # .leakcheckrc its content is not exempt, so its own lines report it.
  seed README.md "clean"
  seed .leakcheckrc.local "pattern MYHOST"
  commit init
  assert_exit 1 "$BIN"
  assert_contains ".leakcheckrc.local:1: [MYHOST] pattern MYHOST" "$LC_OUT"
}

t_tracked_local_config_found_without_self_match() {
  # A pattern need not match its own source line (`^SECRET-[0-9]+$` does
  # not), so a committed .local is a finding of its own, --config or not.
  seed README.md "clean"
  seed .leakcheckrc.local $'no-defaults\npattern ^SECRET-[0-9]+$'
  commit init
  assert_exit 1 "$BIN"
  assert_contains ".leakcheckrc.local:0: [config:local-tracked]" "$LC_OUT"
  printf 'pattern NEVER-MATCHES-ABC123\n' > other.rc
  assert_exit 1 "$BIN" --config other.rc
  assert_contains ".leakcheckrc.local:0: [config:local-tracked]" "$LC_OUT"
}

t_dangling_local_config_errors() {
  seed README.md "hello"
  commit init
  ln -s does-not-exist .leakcheckrc.local
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc.local" "$LC_ERR"
}

t_local_config_errors_name_their_file() {
  seed README.md "hello"
  commit init
  printf 'pattern ok\nbogus x\n' > .leakcheckrc.local
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc.local: unknown directive: bogus" "$LC_ERR"
}

# ─── v0.4.1: silent-clean escapes, unbound aborts, the bash floor ──────

t_escape_letter_is_refused() {
  # git's regex reads `\d` as a plain `d`: v0.4.0 ran this and said clean.
  seed README.md "SECRET-123"
  rc_file 'no-defaults' 'pattern SECRET-\d+'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "'\\d' is a plain 'd'" "$LC_ERR"
  assert_not_contains "clean" "$LC_OUT"
}

t_single_backslash_windows_pattern_is_refused() {
  # `C:\Users\dave` reads as C:Usersdave, so it never matches the path it
  # spells. Defaults off, so nothing else catches the line.
  seed notes.md 'C:\Users\dave\x'
  rc_file 'no-defaults' 'pattern C:\Users\dave'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "'\\U' is a plain 'U'" "$LC_ERR"
}

t_bracket_escape_is_refused() {
  # Inside brackets a backslash is literal: `[\w.-]` misses every letter.
  seed README.md "db.internal"
  rc_file 'no-defaults' 'pattern [\w.-]+\.internal'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "inside [...] a backslash is literal" "$LC_ERR"
}

t_allow_escape_is_refused() {
  # An allow rule holding `\d` suppresses nothing it means to; same refusal.
  seed docs/2.md "/home/alice/x"
  rc_file 'allow ^docs/\d'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "allow '^docs/\\d'" "$LC_ERR"
}

t_meaningful_escapes_still_accepted() {
  # Guard (passes on v0.4.0 by design): every escape and bracket shape that
  # means something stays legal, the README recipes included.
  seed README.md 'host.internal C:\Users\dave\x a word'
  rc_file 'no-defaults' \
    'pattern \.internal' 'pattern C:\\Users\\dave' 'pattern \bword\b' \
    'pattern \w+\s' 'pattern [[:digit:]]?host' 'pattern []a]' 'pattern [^]a]x' \
    'pattern [\\/]Users' 'pattern \<word\>' \
    "pattern (^|[^A-Za-z0-9_./-])/(home|Users)/[A-Za-z0-9_][A-Za-z0-9_.-]*([\"'\`[:space:]]|\$)" \
    'pattern -(home|Users)-[A-Za-z0-9_][A-Za-z0-9_.]*-'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "[\\.internal]" "$LC_OUT"
}

t_unbound_variable_abort_exits_2() {
  # bash exits 1 on a `set -u` abort WITHOUT running the ERR trap, and 1
  # means "matches found". Plant one in a copy, before the final `exit 0`:
  # a clean repo must then report an error, never matches.
  seed README.md "hello"
  commit init
  sed '$s/^exit 0$/: "$LEAKCHECK_UNBOUND_PROBE"; exit 0/' "$BIN" > mutated.sh
  grep -q 'LEAKCHECK_UNBOUND_PROBE' mutated.sh
  assert_exit 2 bash mutated.sh
  assert_contains "internal error" "$LC_ERR"
}

t_old_bash_is_refused() {
  # No bash < 4.4 here, so fake the version in a copy; the guard must stop
  # the run with exit 2 before anything is scanned. Measured for real on bash
  # 3.2: v0.4.0 exited 1 ("matches found") having printed nothing.
  seed README.md "/home/alice/x"
  commit init
  sed 's/"\${BASH_VERSINFO\[0\]:-0}"/"3"/' "$BIN" > mutated.sh
  grep -q '"3" -lt 4' mutated.sh
  assert_exit 2 bash mutated.sh
  assert_contains "needs bash 4.4 or newer" "$LC_ERR"
  assert_not_contains "/home/alice/" "$LC_OUT"
}

# ─── v0.5.0: --history ────────────────────────────────────────────────
# Each load-bearing flag in the history pass has a test here that fails
# when the flag is removed (checked by mutating a copy; SPEC.md § v0.5.0).

sha_of() { git rev-parse "${1:-HEAD}"; }

t_history_finds_scrubbed_leak() {
  seed f.txt $'a\nb\nc'
  commit one
  seed f.txt $'a\nSee /home/alice/code\nc'
  commit two
  local added; added=$(sha_of)
  seed f.txt $'a\nb\nc'
  commit three
  assert_exit 0 "$BIN"
  assert_contains "history not scanned" "$LC_OUT"
  assert_exit 1 "$BIN" --history
  assert_contains "$added:f.txt:2: [/home/" "$LC_OUT"
  assert_contains "history scanned: 3 commits" "$LC_ERR"
}

t_history_line_numbers_follow_hunks() {
  seed f.txt $'1\n2\n3\n4\n5\n6\n7\n8\n9'
  commit one
  # The leak is the SECOND line of a two-line hunk (+7,2), so the per-line
  # counter is what places it, not the hunk header.
  seed f.txt $'1\nTWO\n3\n4\n5\n6\nSEVEN\n/home/alice/x\n9\n10'
  commit two
  assert_exit 1 "$BIN" --history
  assert_contains "$(sha_of):f.txt:8: [" "$LC_OUT"
}

t_history_reports_once_at_earliest_commit() {
  # -U0 never re-adds an unchanged line, but -m does: the merge, diffed
  # against the side parent, adds the leak line again. One hit, the first.
  seed g.txt "base"
  commit root
  git branch side
  seed f.txt $'/home/alice/x\none'
  commit one
  local first; first=$(sha_of)
  seed f.txt $'/home/alice/x\ntwo'
  commit two
  git checkout -q side
  seed h.txt "side"
  commit side
  git checkout -q dev
  git -c core.hooksPath=/dev/null merge -q --no-edit side >/dev/null
  assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$first" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
hist = [h for h in doc["hits"] if h["source"] == "history"]
assert len(hist) == 1 and hist[0]["commit"] == sys.argv[2], hist
PY
}

t_history_side_branch_behind_ours_merge() {
  # A pathspec makes git log simplify history: an `-s ours` merge then hides
  # its whole side branch. The content pass's -m happens to stop that too
  # (measured); the .leakcheckrc.local pass has no -m, so it is the one that
  # needs --full-history — and the one this test would catch.
  seed README.md "hello"
  commit root
  git checkout -q -b side
  seed side.txt "/home/alice/side"
  printf 'pattern ^SECRET-[0-9]+$\n' > .leakcheckrc.local
  git add .leakcheckrc.local
  commit side
  local side; side=$(sha_of)
  git checkout -q dev
  git -c core.hooksPath=/dev/null merge -q -s ours --no-edit side
  git branch -q -D side
  assert_exit 1 "$BIN" --history
  assert_contains "$side:side.txt:1: [" "$LC_OUT"
  assert_contains "$side:.leakcheckrc.local:0: [config:local-in-history]" "$LC_OUT"
}

t_history_evil_merge_line() {
  # A line only the merge commit introduces is in neither parent's diff.
  seed a.txt "a"
  commit root
  git checkout -q -b side
  seed b.txt "b"
  commit side
  git checkout -q dev
  seed c.txt "c"
  commit main-side
  git -c core.hooksPath=/dev/null merge -q --no-commit side >/dev/null 2>&1
  seed evil.txt "/home/alice/evil"
  git -c core.hooksPath=/dev/null commit -q -m merge
  assert_exit 1 "$BIN" --history
  assert_contains "$(sha_of):evil.txt:1: [" "$LC_OUT"
}

t_history_root_commit_despite_showroot_false() {
  git config log.showRoot false
  seed f.txt "/home/alice/root"
  commit root
  local root; root=$(sha_of)
  seed f.txt "clean"
  commit clean
  assert_exit 1 "$BIN" --history
  assert_contains "$root:f.txt:1: [" "$LC_OUT"
}

t_history_added_line_shaped_like_a_header() {
  # An added "++ x" arrives in the diff as "+++ x", the shape of a header.
  seed f.txt "start"
  commit one
  seed f.txt $'start\n++ /home/alice/x'
  commit two
  seed f.txt "start"
  commit three
  assert_exit 1 "$BIN" --history
  assert_contains "f.txt:2: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] ++ /home/alice/x" "$LC_OUT"
}

t_history_names() {
  seed notes-from-MYHOST.md "hello"
  printf 'pattern MYHOST\n' > .leakcheckrc
  git add .leakcheckrc
  commit one
  local named; named=$(sha_of)
  git mv notes-from-MYHOST.md notes.md
  commit renamed
  assert_exit 0 "$BIN"
  assert_exit 1 "$BIN" --history
  assert_contains "$named:notes-from-MYHOST.md:0: [MYHOST] notes-from-MYHOST.md" "$LC_OUT"
}

t_history_quoted_path_is_exact() {
  local f=$'odd"name\tx.md'
  printf '/home/alice/x\n' > "$f"
  git add -- "$f"
  commit one
  git rm -q -- "$f"
  commit two
  assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
files = {h["file"] for h in doc["hits"] if h["source"] == "history"}
assert files == {'odd"name\tx.md'}, files
PY
}

t_history_metadata_once_per_text() {
  seed f.txt "one"
  git -c core.hooksPath=/dev/null -c user.email=alice@MYHOST.lan commit -q -m one
  local first; first=$(sha_of)
  seed f.txt "two"
  git -c core.hooksPath=/dev/null -c user.email=alice@MYHOST.lan commit -q -m $'two\n\nbuilt on MYHOST'
  local second; second=$(sha_of)
  rc_file 'no-defaults' 'pattern MYHOST'
  commit rc
  assert_exit 1 "$BIN" --history
  assert_contains "$first:(author):0: [MYHOST] t <alice@MYHOST.lan>" "$LC_OUT"
  assert_contains "$second:(message):3: [MYHOST] built on MYHOST" "$LC_OUT"
  [[ $(grep -c '(author)' "$LC_OUT") -eq 1 ]]
}

t_history_config_content_not_reported() {
  # Lines still in today's tracked config are exempt in history, and counted.
  rc_file 'pattern MYHOST'
  commit one
  rc_file 'pattern MYHOST' 'pattern OTHERHOST'
  commit two
  assert_exit 0 "$BIN" --history
  assert_contains "2 current-config lines exempt" "$LC_OUT"
}

t_history_old_config_line_is_reported() {
  # A hostname that sat in .leakcheckrc before it moved to .leakcheckrc.local
  # is still in every commit that held it. The first draft excluded the
  # config's history wholesale and missed it.
  rc_file 'pattern MYHOST'
  commit one
  local old; old=$(sha_of)
  rc_file 'pattern OTHERHOST'
  printf 'pattern MYHOST\n' > .leakcheckrc.local
  commit two
  assert_exit 1 "$BIN" --history
  assert_contains "$old:.leakcheckrc:1: [MYHOST] pattern MYHOST" "$LC_OUT"
  assert_contains "1 current-config lines exempt" "$LC_ERR"
}

t_history_removed_config_lines_reported() {
  # Guard for a ruling (passes on the first draft too): a removed config's
  # old lines are published content, so a real-looking path in one is
  # reported, not exempted (/cxr proposed exempting it; that is a false
  # negative for the migration case above).
  rc_file 'allow /home/alice/'
  commit one
  git rm -q .leakcheckrc
  commit two
  assert_exit 1 "$BIN" --history
  assert_contains ".leakcheckrc:1: [/home/" "$LC_OUT"
}

t_history_config_name_scanned() {
  rc_file 'pattern leakcheck'
  commit one
  assert_exit 1 "$BIN" --history
  assert_contains "$(sha_of):.leakcheckrc:0: [leakcheck] .leakcheckrc" "$LC_OUT"
}

t_history_graft_does_not_hide() {
  # A local graft making HEAD a root hid its real parent, exit 0, once the
  # deprecation hint was turned off (found by /cxr, reproduced).
  seed f.txt "/home/alice/x"
  commit leak
  local leak; leak=$(sha_of)
  seed f.txt "clean"
  commit clean
  git rev-parse HEAD > .git/info/grafts
  git config advice.graftFileDeprecated false
  assert_exit 1 "$BIN" --history
  assert_contains "$leak:f.txt:1: [" "$LC_OUT"
  assert_contains "history scanned: 2 commits" "$LC_ERR"
}

t_history_replace_ref_does_not_hide() {
  # A replace ref swapping HEAD for a parentless copy hides the real parent
  # from anything that honours replacements; the count must agree too.
  seed f.txt "/home/alice/x"
  commit leak
  local leak; leak=$(sha_of)
  seed f.txt "clean"
  commit clean
  local fake; fake=$(git commit-tree "$(git rev-parse 'HEAD^{tree}')" -m fake)
  git replace HEAD "$fake"
  assert_exit 1 "$BIN" --history
  assert_contains "$leak:f.txt:1: [" "$LC_OUT"
  assert_contains "history scanned: 3 commits" "$LC_ERR"
}

t_history_local_config_ever_committed() {
  seed README.md "hello"
  printf 'pattern ^SECRET-[0-9]+$\n' > .leakcheckrc.local
  git add .leakcheckrc.local
  commit oops
  local oops; oops=$(sha_of)
  git rm -q --cached .leakcheckrc.local
  commit fixed
  assert_exit 1 "$BIN" --history
  assert_contains "$oops:.leakcheckrc.local:0: [config:local-in-history]" "$LC_OUT"
}

t_history_shallow_clone_refused() {
  seed f.txt "one"
  commit one
  seed f.txt "two"
  commit two
  git clone -q --depth 1 "file://$PWD" shallow
  ( cd shallow && assert_exit 2 "$BIN" --history )
  assert_contains "shallow clone" "$LC_ERR"
}

t_history_binary_counted_and_strict() {
  printf '/home/alice/x\0bin' > blob.bin
  git add blob.bin
  commit one
  local bin; bin=$(sha_of)
  git rm -q blob.bin
  commit two
  assert_exit 0 "$BIN" --history
  assert_contains "1 binary files skipped" "$LC_OUT"
  assert_exit 1 "$BIN" --history --strict
  assert_contains "$bin:blob.bin:0: [unscanned:binary]" "$LC_OUT"
}

t_history_skip_applies() {
  seed tests/fixtures/leak.md "/home/alice/x"
  rc_file 'skip tests/fixtures/*'
  commit one
  git rm -q tests/fixtures/leak.md
  commit two
  assert_exit 0 "$BIN" --history
  assert_contains "history scanned: 2 commits, 0 binary files skipped, 1 skipped by config" "$LC_OUT"
}

t_history_allow_applies() {
  seed f.txt "/home/alice/x"
  rc_file 'allow ^f\.txt:1:/home/alice/x$'
  commit one
  seed f.txt "clean"
  commit two
  assert_exit 0 "$BIN" --history
  assert_contains "1 allowed" "$LC_OUT"
}

t_history_json_shape() {
  seed f.txt "/home/alice/x"
  commit one
  seed f.txt "clean"
  commit two
  assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$(sha_of HEAD~1)" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history_scanned"] is True, doc
assert doc["history"] == {"commits": 2, "binary": 0, "skipped": 0, "config_lines_exempt": 0, "range": None}, doc
(hit,) = doc["hits"]
assert hit["source"] == "history" and hit["commit"] == sys.argv[2], hit
assert list(hit)[-1] == "commit" and list(doc)[-1] == "history", doc
PY
}

t_history_default_json_unchanged() {
  # Guard (passes on v0.4.1 by design): without --history no hit carries a
  # commit and the envelope still ends at history_scanned:false.
  seed f.txt "/home/alice/x"
  commit one
  assert_exit 1 "$BIN" --json
  assert_not_contains '"commit"' "$LC_OUT"
  assert_contains '"history_scanned":false}' "$LC_OUT"
}

t_history_empty_repo() {
  assert_exit 0 "$BIN" --history
  assert_contains "history scanned: 0 commits" "$LC_OUT"
}

t_history_leak_still_present_is_reported_twice() {
  seed f.txt "/home/alice/x"
  commit one
  assert_exit 1 "$BIN" --history
  assert_contains "f.txt:1: [" "$LC_OUT"
  [[ $(grep -c 'f.txt:1: \[' "$LC_OUT") -eq 2 ]]
  grep -qE '^[0-9a-f]{40}:f\.txt:1: \[' "$LC_OUT"
}

# --history-range puts one revision range in place of --all in every pass.

t_history_range_scans_only_the_range() {
  seed f.txt "/home/alice/old"
  commit old
  seed f.txt "clean"
  commit scrub
  local base; base=$(sha_of)
  seed g.txt "/home/alice/new"
  commit new
  local added; added=$(sha_of)
  seed g.txt "clean"
  commit scrub-new
  # A branch the range does not name: --all alongside the range would reach
  # it, and with one branch the two walks are the same set.
  git checkout -q -b side "$base"
  seed h.txt "/home/alice/side"
  commit side
  git checkout -q -
  # Control: both are findable at all.
  assert_exit 1 "$BIN" --history
  assert_contains "/home/alice/old" "$LC_OUT"
  assert_contains "/home/alice/side" "$LC_OUT"
  assert_exit 1 "$BIN" --history-range "$base..HEAD"
  assert_contains "$added:g.txt:1: [/home/" "$LC_OUT"
  assert_not_contains "/home/alice/old" "$LC_OUT"
  assert_not_contains "/home/alice/side" "$LC_OUT"
  assert_contains "history scanned: 2 commits in range $base..HEAD only" "$LC_ERR"
}

t_history_range_applies_to_every_pass() {
  rc_file 'pattern MYHOST'
  seed old-MYHOST.md "x"
  commit "before the range, on MYHOST"
  git rm -q old-MYHOST.md
  commit "drop old"
  local base; base=$(sha_of)
  seed notes-from-MYHOST.md "x"
  commit "in the range, on MYHOST"
  local named; named=$(sha_of)
  git mv notes-from-MYHOST.md notes.md
  printf 'pattern ^SECRET-[0-9]+$\n' > .leakcheckrc.local
  git add .leakcheckrc.local
  commit rename
  local oops; oops=$(sha_of)
  git rm -q --cached .leakcheckrc.local
  commit untrack
  git checkout -q -b side "$base"
  seed side-MYHOST.md "x"
  commit "on a side branch, on MYHOST"
  git checkout -q -
  # Control: what lies outside the range is findable at all.
  assert_exit 1 "$BIN" --history
  assert_contains "old-MYHOST.md:0: [MYHOST]" "$LC_OUT"
  assert_contains "(message):1: [MYHOST] before the range" "$LC_OUT"
  assert_contains "side-MYHOST.md:0: [MYHOST]" "$LC_OUT"
  assert_contains "(message):1: [MYHOST] on a side branch" "$LC_OUT"
  assert_exit 1 "$BIN" --history-range "$base..HEAD"
  assert_contains "$named:notes-from-MYHOST.md:0: [MYHOST]" "$LC_OUT"
  assert_contains "$named:(message):1: [MYHOST] in the range, on MYHOST" "$LC_OUT"
  assert_contains "$oops:.leakcheckrc.local:0: [config:local-in-history]" "$LC_OUT"
  assert_not_contains "old-MYHOST" "$LC_OUT"
  assert_not_contains "before the range" "$LC_OUT"
  assert_not_contains "side" "$LC_OUT"
}

t_history_range_in_a_shallow_clone() {
  seed f.txt "one"
  commit one
  seed f.txt "two"
  commit two
  seed f.txt "/home/alice/three"
  commit three
  seed f.txt "four"
  commit four
  # Depth 3 holds two..four, and "two" is the boundary: its parent is absent.
  git clone -q --depth 3 "file://$PWD" shallow
  cd shallow
  # Based ON the boundary, the range never needs what lies behind it.
  assert_exit 1 "$BIN" --history-range HEAD~2..HEAD
  assert_contains ":f.txt:1: [/home/" "$LC_OUT"
  assert_contains "history scanned: 2 commits in range HEAD~2..HEAD only" "$LC_ERR"
  # Reaching the boundary, it would silently miss "one".
  assert_exit 2 "$BIN" --history-range HEAD
  assert_contains "shallow clone: HEAD reaches commit" "$LC_ERR"
  assert_exit 2 "$BIN" --history
  assert_contains "shallow clone" "$LC_ERR"
}

t_history_range_refusals() {
  seed f.txt "x"
  commit one
  # An option-shaped value would change what the walk means.
  assert_exit 2 "$BIN" --history-range --all
  assert_contains "not an option: --all" "$LC_ERR"
  assert_exit 2 "$BIN" --history-range HEAD --history-range HEAD
  assert_contains "given twice" "$LC_ERR"
  assert_exit 2 "$BIN" --history-range nosuch..HEAD
  assert_contains "bad revision 'nosuch..HEAD'" "$LC_ERR"
  assert_exit 2 "$BIN" --history-range
  assert_contains "needs a value" "$LC_ERR"
}

t_history_range_empty_is_stated() {
  seed f.txt "x"
  commit one
  assert_exit 0 "$BIN" --history-range HEAD..HEAD
  assert_contains "history scanned: 0 commits in range HEAD..HEAD only" "$LC_OUT"
}

t_history_range_json() {
  seed f.txt "/home/alice/x"
  commit one
  seed f.txt "clean"
  commit two
  assert_exit 0 "$BIN" --history-range HEAD~1..HEAD --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["clean"] is True, doc
assert doc["history"] == {"commits": 1, "binary": 0, "skipped": 0, "config_lines_exempt": 0, "range": "HEAD~1..HEAD"}, doc
assert list(doc["history"])[-1] == "range", doc
PY
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
lc_test "every default shape hits exactly once"       t_defaults_each_shape_hits_exactly_once
lc_test "new defaults behave the same in C locale"    t_defaults_same_in_c_locale
lc_test "placeholders stay clean in every new shape"  t_default_placeholders_stay_clean
lc_test "no-trailing-slash: recipe, not default"      t_no_trailing_slash_is_a_recipe_not_a_default
lc_test ".leakcheckrc.local is read"                  t_local_config_is_read
lc_test ".leakcheckrc.local adds to .leakcheckrc"     t_local_config_adds_to_main_config
lc_test "--config ignores .leakcheckrc.local"         t_explicit_config_ignores_local
lc_test "tracked .leakcheckrc.local reports itself"   t_tracked_local_config_reports_itself
lc_test "tracked .local found without a self-match"   t_tracked_local_config_found_without_self_match
lc_test "dangling .leakcheckrc.local errors"          t_dangling_local_config_errors
lc_test ".local config errors name their file"        t_local_config_errors_name_their_file
lc_test "escape \\d in a pattern is refused"           t_escape_letter_is_refused
lc_test "single-backslash Windows pattern refused"    t_single_backslash_windows_pattern_is_refused
lc_test "escape inside brackets is refused"           t_bracket_escape_is_refused
lc_test "escape in an allow rule is refused"          t_allow_escape_is_refused
lc_test "meaningful escapes still accepted"           t_meaningful_escapes_still_accepted
lc_test "unbound-variable abort exits 2, not 1"       t_unbound_variable_abort_exits_2
lc_test "bash older than 4.4 is refused"              t_old_bash_is_refused
lc_test "history: finds a scrubbed leak"              t_history_finds_scrubbed_leak
lc_test "history: line numbers follow hunks"          t_history_line_numbers_follow_hunks
lc_test "history: once, at the earliest commit"       t_history_reports_once_at_earliest_commit
lc_test "history: side branch behind -s ours merge"   t_history_side_branch_behind_ours_merge
lc_test "history: a line only the merge adds"         t_history_evil_merge_line
lc_test "history: root commit despite showRoot=false" t_history_root_commit_despite_showroot_false
lc_test "history: added line shaped like a header"    t_history_added_line_shaped_like_a_header
lc_test "history: names, including renamed-away"      t_history_names
lc_test "history: quoted path name is exact"          t_history_quoted_path_is_exact
lc_test "history: metadata, once per text"            t_history_metadata_once_per_text
lc_test "history: config content not reported"        t_history_config_content_not_reported
lc_test "history: old config line reported"           t_history_old_config_line_is_reported
lc_test "history: removed config lines reported"      t_history_removed_config_lines_reported
lc_test "history: config path name scanned"           t_history_config_name_scanned
lc_test "history: a graft does not hide parents"      t_history_graft_does_not_hide
lc_test "history: a replace ref does not hide"        t_history_replace_ref_does_not_hide
lc_test "history: .leakcheckrc.local ever committed"  t_history_local_config_ever_committed
lc_test "history: shallow clone refused"              t_history_shallow_clone_refused
lc_test "history: binary counted, --strict reports"   t_history_binary_counted_and_strict
lc_test "history: skip applies"                       t_history_skip_applies
lc_test "history: allow applies"                      t_history_allow_applies
lc_test "history: JSON shape"                         t_history_json_shape
lc_test "history: default JSON unchanged"             t_history_default_json_unchanged
lc_test "history: empty repo"                         t_history_empty_repo
lc_test "history: leak still present, reported twice" t_history_leak_still_present_is_reported_twice
lc_test "history range: scans only the range"         t_history_range_scans_only_the_range
lc_test "history range: applies to every pass"        t_history_range_applies_to_every_pass
lc_test "history range: in a shallow clone"           t_history_range_in_a_shallow_clone
lc_test "history range: refusals"                     t_history_range_refusals
lc_test "history range: an empty range is stated"     t_history_range_empty_is_stated
lc_test "history range: JSON names the range"         t_history_range_json

echo
echo "  $PASS passed  ·  $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0

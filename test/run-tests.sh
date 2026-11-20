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
# Stand-in credentials, one per built-in credential rule: test/credential_specs.py
# builds them at run time from a fixed seed (this file is public and scanned,
# so it holds no token). Each row: rule id, a line holding the stand-in, the
# exact match.
# CRED_PATHS: one row per path-rule stand-in, a file name (rule id, name);
# CRED_IDS: every rule id in --list-rules order, the content rules first.
CRED_TSV="$(mktemp -t lc-cred.XXXXXX)"
CRED_PATHS="$(mktemp -t lc-credp.XXXXXX)"
CRED_IDS="$(mktemp -t lc-credi.XXXXXX)"
trap 'rm -f "$LC_OUT" "$LC_ERR" "$CRED_TSV" "$CRED_PATHS" "$CRED_IDS"' EXIT
python3 -I "$SCRIPT_DIR/credential_specs.py" > "$CRED_TSV" || { echo "stand-in generator failed" >&2; exit 2; }
python3 -I "$SCRIPT_DIR/credential_specs.py" --paths > "$CRED_PATHS" || { echo "stand-in generator failed" >&2; exit 2; }
{ cut -f1 "$CRED_TSV"; cut -f1 "$CRED_PATHS" | uniq; } > "$CRED_IDS"

# cred <id>: that rule's stand-in. masked <match>: how leakcheck prints it.
cred() {
  local id line m
  while IFS=$'\t' read -r id line m; do
    if [[ "$id" == "$1" ]]; then printf '%s\n' "$m"; return 0; fi
  done < "$CRED_TSV"
  echo "no stand-in for $1" >&2
  return 1
}
masked() { printf '%s[redacted, %d chars]' "${1:0:4}" "${#1}"; }

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
no-credentials
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
  for f in --strict --history --history-range --json --format --baseline --write-baseline --dir --stdin --decode --archives --redact --rule --list-patterns --list-rules --config --root --version --help; do
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
# How this git diffs merges under --history, probed as leakcheck probes it:
# remerge from git 2.36 with an empty info/attributes, else separate (-m).
merge_mode() {
  local a d old=1; a=$(git rev-parse --git-path info/attributes)
  if [[ "$(git version)" =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]] &&
     (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 40) )); then old=0; fi
  d=$'\n'$(git config --name-only --get-regexp '^merge\..*\.driver$' || :)$'\n'
  if [[ "$d" == *$'\nmerge.text.driver\n'* || ( $old -eq 1 && "$d" != $'\n\n' ) ]]; then echo separate; return; fi
  if [[ ! -L "$a" && ! -s "$a" ]] && git log -0 --all --diff-merges=remerge >/dev/null 2>&1; then
    echo remerge
  else
    echo separate
  fi
}

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

t_history_remerge_conflict_resolution() {
  # gap 6 (v0.22.0): a merge is diffed against git's own re-merge of its
  # parents (git 2.36 and later), so a conflict's resolution is the merge's
  # own lines. git notes the conflict in the stream (`remerge CONFLICT`),
  # which the parser reads past; the JSON names how merges were diffed.
  seed a.txt $'one\ntwo'
  commit base
  git checkout -q -b side
  seed a.txt $'one\nTWO-side'
  commit side
  git checkout -q dev
  seed a.txt $'one\nTWO-dev'
  commit dev
  git -c core.hooksPath=/dev/null merge -q side >/dev/null 2>&1 || true
  seed a.txt $'one\nresolved, see /home/alice/x'
  commit merge
  local m; m=$(sha_of)
  seed a.txt "clean"
  commit scrub
  assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$m" "$(merge_mode)" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history"]["merge_diffs"] == sys.argv[3], doc["history"]
hits = [(h["commit"], h["file"], h["line"], h["text"]) for h in doc["hits"] if h["source"] == "history"]
assert hits == [(sys.argv[2], "a.txt", 2, "resolved, see /home/alice/x")], hits
PY
}

t_history_octopus_merge_line() {
  # gap 6 (v0.22.0), a guard: remerge skips a merge of three or more
  # parents, printing a warning where its diff would be, so octopus merges
  # are diffed against each parent in a pass of their own. A line only the
  # octopus adds is found at it.
  seed a.txt "a"
  commit root
  git checkout -q -b one
  seed one.txt "one"
  commit one
  git checkout -q dev
  git checkout -q -b two
  seed two.txt "two"
  commit two
  git checkout -q dev
  seed d.txt "d"
  commit d
  git -c core.hooksPath=/dev/null merge -q --no-commit one two >/dev/null 2>&1
  seed evil.txt "/home/alice/octopus"
  commit octopus
  local m; m=$(sha_of)
  [[ $(git log -1 --format=%P | wc -w) -eq 3 ]]
  git rm -q evil.txt
  commit scrub
  assert_exit 1 "$BIN" --history
  assert_contains "$m:evil.txt:1: [" "$LC_OUT"
}

t_history_merges_without_remerge() {
  # gap 6 (v0.22.0): a git before 2.36 has no remerge, so the merge pass
  # falls back to -m, which finds the same lines, slower, and the JSON says
  # `separate`. A git refusing the value stands in for an old one.
  local real fb="$PWD/.git/fakebin"
  real=$(command -v git)
  mkdir -p "$fb"
  printf '#!/bin/sh\nfor a; do [ "$a" = --diff-merges=remerge ] && { echo "fatal: unknown value for --diff-merges: remerge" >&2; exit 128; }; done\nexec %s "$@"\n' "$real" > "$fb/git"
  chmod +x "$fb/git"
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
  commit merge
  local m; m=$(sha_of)
  PATH="$fb:$PATH" assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$m" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history"]["merge_diffs"] == "separate", doc["history"]
assert any(h.get("commit") == sys.argv[2] and h["file"] == "evil.txt" for h in doc["hits"]), doc["hits"]
PY
}

t_history_remerge_and_merge_drivers() {
  # gap 6 (v0.22.0): a merge driver can write a line in neither parent, and
  # would write it again in the re-merge, hiding it. A user's merge.default
  # is pinned to git's own; a driver named in info/attributes, which no
  # setting blanks, sends the pass to -m (`separate`).
  local cfg="$PWD/.git/drv.cfg" m
  printf '[merge]\n\tdefault = inject\n[merge "inject"]\n\tdriver = printf '"'"'see /home/alice/driver\\\\n'"'"' >> %%A\n' > "$cfg"
  seed a.txt $'one\ntwo\nthree'
  commit base
  git checkout -q -b side
  seed a.txt $'ONE\ntwo\nthree'
  commit side
  git checkout -q dev
  seed a.txt $'one\ntwo\nTHREE'
  commit dev
  GIT_CONFIG_GLOBAL="$cfg" git -c core.hooksPath=/dev/null -c commit.gpgsign=false merge -q --no-edit side >/dev/null
  m=$(sha_of)
  [[ "$(tail -n 1 a.txt)" == "see /home/alice/driver" ]]
  seed a.txt "clean"
  commit scrub
  GIT_CONFIG_GLOBAL="$cfg" assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$m" "$(GIT_CONFIG_GLOBAL="$cfg" merge_mode)" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history"]["merge_diffs"] == sys.argv[3], doc["history"]
assert [(h["commit"], h["file"], h["line"]) for h in doc["hits"]] == [(sys.argv[2], "a.txt", 4)], doc["hits"]
PY
  # The driver named per path, in info/attributes, with the repo's config.
  printf 'a.txt merge=inject\n' > .git/info/attributes
  git config merge.inject.driver "printf 'see /home/alice/driver\\n' >> %A"
  assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$m" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history"]["merge_diffs"] == "separate", doc["history"]
assert [(h["commit"], h["file"], h["line"]) for h in doc["hits"]] == [(sys.argv[2], "a.txt", 4)], doc["hits"]
PY
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
  python3 - "$LC_OUT" "$(sha_of HEAD~1)" "$(merge_mode)" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history_scanned"] is True, doc
assert doc["history"] == {"commits": 2, "binary": 0, "skipped": 0, "config_lines_exempt": 0, "range": None, "refs": 1, "tags": 0, "tagged_unscanned": 0, "merge_diffs": sys.argv[3]}, doc
(hit,) = doc["hits"]
assert hit["source"] == "history" and hit["commit"] == sys.argv[2], hit
assert list(hit)[-1] == "commit" and list(doc)[-3:] == ["history", "credentials_scanned", "credentials"], doc
PY
}

t_history_default_json_unchanged() {
  # Without --history no hit carries a commit, and history_scanned:false is
  # followed only by what later versions appended (v0.10.0: credentials).
  seed f.txt "/home/alice/x"
  commit one
  assert_exit 1 "$BIN" --json
  assert_not_contains '"commit"' "$LC_OUT"
  assert_contains '"history_scanned":false,"credentials_scanned":true,"credentials":{' "$LC_OUT"
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
  python3 - "$LC_OUT" "$(merge_mode)" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["clean"] is True, doc
assert doc["history"] == {"commits": 1, "binary": 0, "skipped": 0, "config_lines_exempt": 0, "range": "HEAD~1..HEAD", "refs": 1, "tags": 0, "tagged_unscanned": 0, "merge_diffs": sys.argv[2]}, doc
assert list(doc["history"])[4] == "range", doc
PY
}

# Allow rules excuse what they match, not their whole line (v0.7.0).

t_allow_does_not_hide_another_patterns_hit() {
  # The README's own placeholder rule hid a MYHOST hit sharing its line.
  seed a.txt "paths look like /home/USERNAME/ and we deploy to MYHOST"
  rc_file 'pattern MYHOST' 'allow /home/USERNAME/'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [MYHOST]" "$LC_OUT"
  assert_not_contains "a.txt:1: [/home/" "$LC_OUT"
  assert_contains "1 allowed" "$LC_ERR"
}

t_allow_does_not_hide_a_second_match() {
  # One pattern, one hit per line: the allowed placeholder must not carry
  # the real path beside it.
  seed a.txt "/home/USERNAME/ and /home/alice/"
  rc_file 'allow /home/USERNAME/'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [/home/" "$LC_OUT"
  assert_contains "0 allowed" "$LC_ERR"
}

t_allow_overlap_excuses_a_match_it_is_part_of() {
  # Guard (passes on v0.6.0 by design): a rule naming part of a match —
  # the placeholder domain of a host name — still excuses that match.
  seed a.txt "see x.example.com"
  rc_file 'pattern [a-z]+\.example\.com' 'allow \.example\.com'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 allowed" "$LC_OUT"
}

t_allow_location_rule_allows_everything_there() {
  # Guard (passes on v0.6.0 by design): a rule matching the location alone
  # allows every pattern's hit there.
  seed fixtures/a.md "/home/alice/ on MYHOST"
  rc_file 'pattern MYHOST' 'allow ^fixtures/'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "2 allowed" "$LC_OUT"
}

t_allow_adjacent_match_behind_a_non_ascii_path() {
  # Matches that touch, behind a multibyte path: each is excused on its own
  # text, so no byte or character arithmetic can merge them.
  seed zoë.txt "/home/USERNAME/MYHOST"
  rc_file 'pattern MYHOST' 'allow /home/USERNAME/'
  commit init
  LC_ALL=C.UTF-8 assert_exit 1 "$BIN"
  assert_contains "[MYHOST]" "$LC_OUT"
  assert_contains "1 allowed" "$LC_ERR"
}

t_allow_in_a_name_with_a_newline() {
  # A record split over two lines still maps each match back to its hit.
  local name=$'xxxxxxxxxxxxxxxxxxxx\ny.txt'
  printf '%s\n' "/home/USERNAME/MYHOST" > "$name"
  git add -- "$name"
  rc_file 'pattern MYHOST' 'allow /home/USERNAME/'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "[MYHOST]" "$LC_OUT"
  assert_contains "1 allowed" "$LC_ERR"
}

t_allow_every_match_allowed_is_allowed() {
  # Guard (passes on v0.6.0 by design): two allowed matches on one line.
  # git 2.53's -o --column misplaces every match after a line's first, so
  # a position-based check failed exactly this (measured).
  seed ip.txt "x('10.0.0.1').toBe('10.0.0.1'); y('10.0.0.2')"
  rc_file 'pattern \b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' 'allow 10\.0\.0\.(1|2)\b'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 allowed" "$LC_OUT"
}

t_allow_partial_line_rule_excuses_nothing() {
  # A rule naming context around a match must name the whole line.
  seed a.txt "see /home/alice/"
  rc_file 'allow ^a\.txt:1:see'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "0 allowed" "$LC_ERR"
  rc_file 'allow ^a\.txt:1:see /home/alice/$'
  assert_exit 0 "$BIN"
  assert_contains "1 allowed" "$LC_OUT"
}

t_allow_whole_line_means_every_line() {
  # A name holding a newline is a record of several lines; matching one of
  # them entirely is not matching the line.
  printf 'x\n' > $'notes\nMYHOST.md'
  git add -- $'notes\nMYHOST.md'
  rc_file 'pattern MYHOST' 'allow ^MYHOST\.md$'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "[MYHOST]" "$LC_OUT"
}

t_allow_credit_goes_to_the_lowest_rule() {
  # Guard (passes on v0.6.0 by design): the first listed rule that took part
  # takes the count — across the matches of one hit, and ahead of a later
  # whole-line rule — and every rule's count is reported.
  seed a.txt "/home/USERNAME/ and /home/alice/"
  rc_file 'allow /home/USERNAME/' 'allow /home/alice/' 'allow ^a\.txt:1:.*$'
  commit init
  assert_exit 0 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert [a["count"] for a in doc["allowed"]] == [1, 0, 0], doc["allowed"]
PY
}

# Ref names and annotated tags (v0.8.0): published by a push, part of no commit.

t_history_ref_names() {
  seed f.txt "x"
  commit one
  git branch feature/MYHOST-fix
  rc_file 'pattern MYHOST'
  commit two
  assert_exit 0 "$BIN"
  assert_exit 1 "$BIN" --history
  assert_contains "$(sha_of feature/MYHOST-fix):(ref):0: [MYHOST] refs/heads/feature/MYHOST-fix" "$LC_OUT"
}

t_history_annotated_tag() {
  rc_file 'pattern MYHOST'
  seed f.txt "x"
  commit one
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=ops@MYHOST.example \
    git tag -a -m $'release\n\nbuilt on MYHOST' rel-MYHOST
  local tag; tag=$(git rev-parse rel-MYHOST)
  assert_exit 1 "$BIN" --history
  assert_contains "$tag:(ref):0: [MYHOST] refs/tags/rel-MYHOST" "$LC_OUT"
  assert_contains "$tag:(tag):0: [MYHOST] rel-MYHOST" "$LC_OUT"
  assert_contains "$tag:(tag message):3: [MYHOST] built on MYHOST" "$LC_OUT"
  # The ident without its timestamp, as (author) shows a commit's.
  grep -qxF "$tag:(tagger):0: [MYHOST] t <ops@MYHOST.example>" "$LC_OUT"
  assert_contains "1 annotated tags" "$LC_ERR"
}

t_history_nested_tag() {
  # A tag of a tag: the inner object is published by pushing the outer one,
  # though no ref names it.
  seed f.txt "x"
  commit one
  git tag -a -m "inner, on MYHOST" inner
  local inner; inner=$(git rev-parse inner)
  git tag -a -m "outer" outer inner 2>/dev/null
  git tag -d inner >/dev/null
  rc_file 'pattern MYHOST'
  commit two
  assert_exit 1 "$BIN" --history
  assert_contains "$inner:(tag message):1: [MYHOST] inner, on MYHOST" "$LC_OUT"
  assert_contains "2 annotated tags" "$LC_ERR"
}

t_history_tagged_blob_counted_and_strict() {
  seed f.txt "/home/alice/x"
  commit one
  git tag blobtag "$(git rev-parse HEAD:f.txt)"
  seed f.txt "clean"
  commit two
  assert_exit 1 "$BIN" --history
  assert_contains "1 tagged trees or blobs not scanned" "$LC_ERR"
  assert_exit 1 "$BIN" --history --strict
  assert_contains "(ref):0: [unscanned:tagged-blob] refs/tags/blobtag" "$LC_OUT"
}

t_history_refs_with_no_commits() {
  # No commit anywhere, but `git push --tags` still publishes a tag on a
  # blob, or an annotated tag on a tree, by name and message.
  rc_file 'pattern MYHOST'
  local blob tree
  blob=$(printf 'x\n' | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tf\n' "$blob" | git mktree)
  git tag deploy-MYHOST "$blob"
  git tag -a -m "built on MYHOST" rel "$tree"
  local tag; tag=$(git rev-parse rel)
  [[ $(git rev-list --all --count) -eq 0 ]] || { echo "    fixture has a commit"; return 1; }
  assert_exit 1 "$BIN" --history
  assert_contains "$blob:(ref):0: [MYHOST] refs/tags/deploy-MYHOST" "$LC_OUT"
  assert_contains "$tag:(tag message):1: [MYHOST] built on MYHOST" "$LC_OUT"
  assert_contains "history scanned: 0 commits" "$LC_ERR"
  assert_contains "2 refs, 1 annotated tags, 2 tagged trees or blobs not scanned" "$LC_ERR"
  assert_exit 1 "$BIN" --history --strict
  assert_contains "$tree:(ref):0: [unscanned:tagged-tree] refs/tags/rel" "$LC_OUT"
}

t_history_range_refs_in_range_only() {
  seed f.txt "x"
  commit one
  local base; base=$(sha_of)
  git branch old-MYHOST
  seed f.txt "y"
  commit two
  git branch new-MYHOST
  git tag -a -m "tagged in range, on MYHOST" t-new
  rc_file 'pattern MYHOST'
  commit three
  assert_exit 1 "$BIN" --history
  assert_contains "refs/heads/old-MYHOST" "$LC_OUT"
  assert_exit 1 "$BIN" --history-range "$base..HEAD"
  assert_contains "refs/heads/new-MYHOST" "$LC_OUT"
  assert_contains "(tag message):1: [MYHOST] tagged in range" "$LC_OUT"
  assert_not_contains "old-MYHOST" "$LC_OUT"
}

t_history_tag_holding_nul_bytes() {
  # Bash drops a NUL, which shifted the framing of every later tag object.
  seed f.txt "x"
  commit one
  local c t1 t2; c=$(sha_of)
  t1=$(printf 'object %s\ntype commit\ntag a\ntagger t <t@t> 0 +0000\n\nx\0\0MYHOST one\n' "$c" |
    git hash-object -t tag -w --stdin --literally)
  t2=$(printf 'object %s\ntype commit\ntag b\ntagger t <t@t> 0 +0000\n\nMYHOST two\n' "$c" |
    git hash-object -t tag -w --stdin --literally)
  git update-ref refs/tags/a "$t1"
  git update-ref refs/tags/b "$t2"
  rc_file 'pattern MYHOST'
  commit two
  assert_exit 1 "$BIN" --history
  assert_contains "$t1:(tag message):1: [MYHOST]" "$LC_OUT"
  assert_contains "$t2:(tag message):1: [MYHOST] MYHOST two" "$LC_OUT"
}

# A leading (?i) makes a pattern or an allow rule ignore case (v0.9.0).

t_ignorecase_pattern_in_the_tree() {
  rc_file 'pattern (?i)myhost'
  seed a.txt "deploy to MyHost"
  seed notes-from-MYHOST.md "x"
  ln -s /srv/MyHost/data link
  ln -s clean-target swapped
  git add link swapped
  commit init
  # A symlink replaced by a file: the type-change pass.
  rm swapped
  printf 'on myHOST too\n' > swapped
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [(?i)myhost] deploy to MyHost" "$LC_OUT"
  assert_contains "notes-from-MYHOST.md:0: [(?i)myhost]" "$LC_OUT"
  assert_contains "link:0: [(?i)myhost] -> /srv/MyHost/data" "$LC_OUT"
  assert_contains "swapped:1: [(?i)myhost] on myHOST too" "$LC_OUT"
}

t_ignorecase_pattern_in_history() {
  rc_file 'pattern (?i)myhost'
  commit rc
  seed f.txt "on MyHost"
  commit "deployed to MYHOST"
  local added; added=$(sha_of)
  git mv f.txt myhost-notes.txt
  commit rename
  git rm -q myhost-notes.txt
  commit scrub
  assert_exit 0 "$BIN"
  assert_exit 1 "$BIN" --history
  assert_contains "$added:f.txt:1: [(?i)myhost] on MyHost" "$LC_OUT"
  assert_contains "$added:(message):1: [(?i)myhost] deployed to MYHOST" "$LC_OUT"
  assert_contains ":myhost-notes.txt:0: [(?i)myhost]" "$LC_OUT"
}

t_ignorecase_allow() {
  seed a.txt "see X.EXAMPLE.COM"
  rc_file 'pattern (?i)[a-z]+\.example\.com' 'allow (?i)\.example\.com'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "1 allowed" "$LC_OUT"
  # And as a whole-line rule.
  rc_file 'pattern (?i)[a-z]+\.example\.com' 'allow (?i)^A\.TXT:1:SEE x\.example\.com$'
  assert_exit 0 "$BIN"
  assert_contains "1 allowed" "$LC_OUT"
}

t_ignorecase_alone_is_refused() {
  # `(?i)` with nothing after it matches every line, like an empty pattern.
  rc_file 'pattern (?i)'
  assert_exit 2 "$BIN"
  assert_contains "empty pattern directive after (?i)" "$LC_ERR"
  rc_file 'allow (?i)'
  assert_exit 2 "$BIN"
  assert_contains "empty allow directive after (?i)" "$LC_ERR"
}

t_ignorecase_only_at_the_start() {
  # Guard (exits 2 on v0.8.0 too, by design): anywhere but the start, (?i)
  # is the invalid ERE git refuses.
  seed a.txt "x"
  rc_file 'pattern my(?i)host'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "Invalid preceding regular expression" "$LC_ERR"
}

# ─── credential rules (v0.10.0) ───────────────────────────────────────
# Stand-ins come from cred (top of this file); none is ever written here.

t_credential_every_rule_finds_its_own_format() {
  local id line m
  while IFS=$'\t' read -r id line m; do printf '%s\n' "$line" > "$id.txt"; done < "$CRED_TSV"
  while IFS=$'\t' read -r id name; do mkdir -p "$(dirname "$name")"; : > "$name"; done < "$CRED_PATHS"
  git add .
  commit init
  assert_exit 1 "$BIN" --json
  cp "$LC_OUT" .git/cred.json
  # Each file is one hit, of its own rule only, printed masked — a path
  # rule's stand-in, an empty file, one hit on its name; a keyword rule's,
  # its keyword (a URL's scheme) and the value's length — and the count of
  # rules is the count of rules with stand-ins, so a rule added without one
  # fails here.
  python3 - .git/cred.json "$CRED_TSV" "$CRED_PATHS" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1]))
kv = {"aws-secret-access-key", "url-password", "generic-secret", "http-basic-auth",
      "http-bearer-token", "curl-user-password", "xml-key-value", "generic-key",
      "sidekiq-credentials", "service-secret"}
def shown(cid, m):
    if cid in markers:
        return m
    if cid not in kv:
        return "%s[redacted, %d chars]" % (m[:4], len(m))
    if cid in ("http-basic-auth", "http-bearer-token"):
        scheme, val = re.match(r".* (\w+) +(\S+)$", m).groups()
        return "%s[redacted, %d chars]" % (scheme, len(val))
    if cid == "curl-user-password":
        return "-u[redacted, %d chars]" % len(m.split(":", 1)[1])
    if cid == "sidekiq-credentials":
        return "%s[redacted, %d chars]" % (re.search("(?i)contribsys", m).group(0), len(m.rsplit(":", 1)[1]))
    if cid == "xml-key-value":
        k, val = re.match(r'<add key="([^"]*)" value="(.*)$', m).groups()
        return "%s[redacted, %d chars]" % (k, len(val))
    if "://" in m:
        return "%s://[redacted, %d chars]" % (m.split("://")[0], len(m[:-1].rsplit(":", 1)[1]))
    kw, val = re.match(r"([A-Za-z_]+)\s*[=:]\s*[\"']?(.*)$", m).groups()
    return "%s[redacted, %d chars]" % (kw, len(val))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
paths = [l.rstrip("\n").split("\t") for l in open(sys.argv[3])]
markers = {"private-key", "putty-private-key"}
by = {}
for h in doc["hits"]:
    by.setdefault(h["file"], []).append(h)
nrules = len(rows) + len({cid for cid, _ in paths})
# One weak value: the XML stand-in's key name, read by generic-key as
# `key="ClearTextPassword"` (v0.18.0).
assert doc["credentials_scanned"] is True and doc["credentials"] == {"rules": nrules, "placeholders": 0, "weak": 1}, doc["credentials"]
assert list(doc)[-2:] == ["credentials_scanned", "credentials"], list(doc)
for cid, line, m in rows:
    hs = by.pop(cid + ".txt", [])
    assert [(h["pattern"], h["text"]) for h in hs] == [("credential:" + cid, shown(cid, m))], (cid, hs)
for cid, name in paths:
    hs = by.pop(name, [])
    assert [(h["pattern"], h["line"], h["text"]) for h in hs] == [("credential:" + cid, 0, name)], (cid, hs)
assert not by, by
PY
  assert_exit 1 "$BIN"
  assert_contains "github-token.txt:1: [credential:github-token] $(masked "$(cred github-token)")" "$LC_OUT"
  while IFS=$'\t' read -r id line m; do
    case "$id" in private-key|putty-private-key) continue ;; esac
    assert_not_contains "$m" "$LC_OUT"
    assert_not_contains "$m" "$LC_ERR"
    assert_not_contains "$m" .git/cred.json
  done < "$CRED_TSV"
}

t_credential_in_every_tree_source() {
  # Index, worktree, a path name, a symlink target, a type change: each pass
  # runs the credential rules, each with its own rule here.
  local gh np st sl pu
  gh=$(cred github-token); np=$(cred npm-token); st=$(cred stripe-key); sl=$(cred slack-token)
  pu=$(cred pulumi-token)
  seed cur.txt "export TOKEN=$gh"
  # A token in a path is masked wherever a credential hit prints that path.
  seed "notes-$np.md" "pw=$pu"
  ln -s "/srv/$st/conf" link
  ln -s clean-target swapped
  git add link swapped
  commit init
  rm swapped
  printf 'hook=%s\n' "$sl" > swapped
  assert_exit 1 "$BIN" --json
  cp "$LC_OUT" .git/tree.json
  python3 - .git/tree.json "notes-$(masked "$np").md" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = {(h["file"], h["pattern"], h["source"]) for h in doc["hits"]}
assert ("cur.txt", "credential:github-token", "both") in got, got
assert ("link", "credential:stripe-key", "both") in got, got
assert ("swapped", "credential:slack-token", "worktree") in got, got
assert (sys.argv[2], "credential:npm-token", "index") in got, got
assert (sys.argv[2], "credential:pulumi-token", "both") in got, got
PY
  assert_exit 1 "$BIN"
  assert_contains "cur.txt:1: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_contains "link:0: [credential:stripe-key] $(masked "$st")" "$LC_OUT"
  assert_contains "swapped:1: [credential:slack-token] $(masked "$sl")" "$LC_OUT"
  assert_contains "notes-$(masked "$np").md:0: [credential:npm-token] $(masked "$np")" "$LC_OUT"
  assert_contains "notes-$(masked "$np").md:1: [credential:pulumi-token] $(masked "$pu")" "$LC_OUT"
  assert_contains "leakcheck: 5 credential(s) among these: revoke and reissue" "$LC_ERR"
  local t
  for t in "$gh" "$np" "$st" "$sl" "$pu"; do
    assert_not_contains "$t" "$LC_OUT"
    assert_not_contains "$t" "$LC_ERR"
    assert_not_contains "$t" .git/tree.json
  done
}

t_credential_in_every_history_source() {
  # Added lines, a path name, a commit message, a ref name, a tag message:
  # every history pass runs the credential rules.
  local aws hf an gk gq
  aws=$(cred aws-access-key-id); hf=$(cred huggingface-token); an=$(cred anthropic-key)
  gk=$(cred google-api-key); gq=$(cred groq-key)
  seed old.txt "aws_access_key_id = $aws"
  seed "dump-$hf.log" "x"
  commit "rotate $an"
  local first; first=$(sha_of)
  git rm -q old.txt "dump-$hf.log"
  commit scrub
  git branch "fix-$gk"
  git tag -a -m "release, key $gq" v1
  assert_exit 0 "$BIN"
  assert_exit 1 "$BIN" --history
  assert_contains "$first:old.txt:1: [credential:aws-access-key-id] $(masked "$aws")" "$LC_OUT"
  assert_contains "$first:dump-$(masked "$hf").log:0: [credential:huggingface-token] $(masked "$hf")" "$LC_OUT"
  assert_contains "$first:(message):1: [credential:anthropic-key] $(masked "$an")" "$LC_OUT"
  assert_contains "(ref):0: [credential:google-api-key] $(masked "$gk")" "$LC_OUT"
  assert_contains "(tag message):1: [credential:groq-key] $(masked "$gq")" "$LC_OUT"
  local t
  for t in "$aws" "$hf" "$an" "$gk" "$gq"; do
    assert_not_contains "$t" "$LC_OUT"
    assert_not_contains "$t" "$LC_ERR"
  done
}

t_credential_placeholders_are_counted_not_reported() {
  local x36 r
  x36=$(printf 'X%.0s' {1..36})
  r=$(cred github-token)
  # An X-filled token, exactly eight equal, AWS's documented key, an alphabet
  # run, exactly eight digits counting up, a lowercase "example": each is a
  # stand-in.
  printf '%s\n' "a=gh""p_$x36" "b=gh""p_${r:4:28}XXXXXXXX" "c=AK""IA""IOSFODNN7EXAMPLE" \
    "d=AK""IA""ABCDEFGHIJKLMNOP" "e=np""m_${r:4:28}12345678" "f=sk""_test_${r:4:20}example" > p.txt
  git add p.txt
  commit init
  assert_exit 0 "$BIN"
  assert_contains "credentials scanned, 6 placeholders not reported" "$LC_OUT"
  assert_exit 0 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["credentials"]["placeholders"] == 6, doc["credentials"]
PY
  # Seven in a row, equal or counting up, is not a placeholder. The GitHub
  # one is 41 long: at 40 its last six would have to be its checksum.
  printf '%s\n' "g=gh""p_${r:4:30}XXXXXXX" "h=np""m_${r:4:29}1234567" > q.txt
  git add q.txt
  commit seven
  assert_exit 1 "$BIN"
  assert_contains "q.txt:1: [credential:github-token]" "$LC_OUT"
  assert_contains "q.txt:2: [credential:npm-token]" "$LC_OUT"
}

t_credential_placeholder_excuses_only_itself() {
  # A real token beside a stand-in on one line is still reported, with both
  # matches shown masked.
  local x36 r
  x36=$(printf 'X%.0s' {1..36})
  r=$(cred github-token)
  printf '%s\n' "ghp_$x36 then $r" > a.txt
  git add a.txt
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:github-token] $(masked "ghp_$x36") $(masked "$r")" "$LC_OUT"
  assert_contains "0 placeholders not reported" "$LC_ERR"
}

t_credential_no_credentials_directive() {
  local gh; gh=$(cred github-token)
  seed a.txt "k=$gh /home/alice/x"
  rc_file 'no-credentials'
  commit init
  assert_exit 1 "$BIN"
  assert_not_contains "credential:" "$LC_OUT"
  assert_contains "; credentials not scanned" "$LC_ERR"
  assert_not_contains "credential(s) among these" "$LC_ERR"
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["credentials_scanned"] is False and "credentials" not in doc, doc
assert list(doc)[-1] == "credentials_scanned", list(doc)
PY
  assert_exit 0 "$BIN" --list-patterns
  [[ $(wc -l < "$LC_OUT") -eq 8 ]] || { echo "    expected the 8 home-path defaults only"; cat "$LC_OUT"; return 1; }
  # no-defaults turns off the home paths and leaves the credential rules.
  rc_file 'no-defaults'
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:github-token]" "$LC_OUT"
  assert_not_contains "/home/" "$LC_OUT"
}

t_credential_list_patterns_appends_the_rules() {
  seed a.txt "x"
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 0 "$BIN" --list-patterns
  local n; n=$(wc -l < "$CRED_IDS")
  # Defaults, then the config's patterns, then one ERE per credential rule,
  # the path rules last: what earlier versions printed stays a prefix.
  python3 - "$LC_OUT" "$n" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
n = int(sys.argv[2])
assert len(lines) == 8 + 1 + n, len(lines)
assert lines[8] == "MYHOST", lines[8]
assert not any(l.startswith("credential:") for l in lines), lines
PY
}

t_credential_label_cannot_be_a_pattern() {
  seed a.txt "x"
  rc_file 'pattern credential:github-token'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "is the name of a built-in credential rule" "$LC_ERR"
  # Guard: another pattern that merely starts so is an ordinary ERE.
  seed b.txt "credential:in-a-yaml-file"
  rc_file 'pattern credential:in-a'
  commit b
  assert_exit 1 "$BIN"
  assert_contains "b.txt:1: [credential:in-a] credential:in-a-yaml-file" "$LC_OUT"
}

t_credential_allow_rules_see_the_real_text() {
  local gh other; gh=$(cred github-token); other=$(cred npm-token)
  seed a.txt "k=$gh"
  # The allow line names the token, so the committed config holds it too:
  # that hit is excused by the same rule.
  rc_file "allow credential:github-token $gh"
  commit init
  assert_exit 0 "$BIN"
  assert_contains "2 allowed" "$LC_OUT"
  rc_file "allow credential:github-token ^a\\.txt:1:k=$gh\$"
  assert_exit 1 "$BIN"
  assert_contains "1 allowed" "$LC_ERR"
  assert_contains ".leakcheckrc:1: [credential:github-token]" "$LC_OUT"
  rc_file "allow credential:github-token $other"
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:github-token]" "$LC_OUT"
}

t_credential_in_the_committed_config() {
  # The config's content is exempt from the patterns it lists, never from the
  # credential rules: a key pasted there is published.
  local gh; gh=$(cred github-token)
  seed a.txt "x"
  rc_file "# deploy key $gh" 'pattern MYHOST'
  commit init
  local first; first=$(sha_of)
  assert_exit 1 "$BIN"
  assert_contains ".leakcheckrc:1: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_not_contains "[MYHOST]" "$LC_OUT"
  assert_exit 1 "$BIN" --history
  assert_contains "$first:.leakcheckrc:1: [credential:github-token]" "$LC_OUT"
  assert_contains "1 current-config lines exempt" "$LC_ERR"
}

t_credential_private_key_needs_a_key_after_its_header() {
  # A header counts where a key can follow it, in every layout a real one
  # takes, and prints alone; a header with no key behind it (a string
  # constant, a fixture's `xx`) is not a credential.
  local body p h g
  body=$(cred azure-storage-key); body=${body#AccountKey=}; body=${body:0:64}
  p="-----BEGIN ""PRIVATE KEY-----"; h="-----BEGIN RSA ""PRIVATE KEY-----"; g="-----BEGIN PGP ""PRIVATE KEY BLOCK-----"
  {
    printf '%s\n' "$h"                                   # 1 a PEM file
    printf '%s\r\n' "$h"                                 # 2 CRLF
    printf '{"k": "%s\\n%s\\n"}\n' "$p" "$body"          # 3 JSON
    printf '{"k": "%s\\r\\n%s"}\n' "$p" "$body"          # 4 JSON, CRLF
    printf '{"k": "%s\\\\n%s"}\n' "$p" "$body"           # 5 escaped twice
    printf '"%s\\n" +\n' "$h"                            # 6 one string per line
    printf "'%s\\\\\\\\n' +\n" "$h"                      # 7 single quotes, escaped twice
    printf 'KEY="%s %s"\n' "$h" "$body"                  # 8 flattened with spaces
    printf '%s%s\n' "$h" "$body"                         # 9 flattened
    printf '"%s\\nProc-Type: 4,ENCRYPTED\\n"\n' "$h"     # 10 encrypted
    printf '"%s\\n\\n%s"\n' "$g" "$body"                 # 11 PGP armor
    printf '"%s\\n%s"\n' "$p" "${body:0:20}\\/${body:22}"  # 12 JSON with \/
  } > keys.txt
  {
    printf "'%s'\n" "$p"
    printf "if (!pem.includes('%s')) {\n" "$p"
    printf "'%s\\\\nxx\\\\n-----END PRIVATE KEY-----'\n" "$p"
    printf "'%s\\\\nnot a key\\\\n-----END PRIVATE KEY-----'\n" "$p"
    printf '"%s\\n%s\\n"\n' "$h" "${body:0:21}"
    printf '# a %s header, in prose.\n' "$p"
  } > fakes.txt
  git add keys.txt fakes.txt
  commit init
  assert_exit 1 "$BIN"
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 12; do
    grep -q "^keys.txt:$n: \[credential:private-key\] -----BEGIN \(RSA \)\{0,1\}PRIVATE KEY-----$" "$LC_OUT" ||
      { echo "    keys.txt line $n not reported as a header alone"; cat "$LC_OUT"; return 1; }
  done
  assert_contains "keys.txt:11: [credential:private-key] $g" "$LC_OUT"
  assert_not_contains "fakes.txt" "$LC_OUT"
  assert_not_contains "${body:0:24}" "$LC_OUT"
  assert_contains "leakcheck: 12 match(es)" "$LC_ERR"
}

t_credential_other_hits_keep_their_text() {
  # Guard (v0.9.0 prints the same line): a home-path hit on a line that also
  # holds a credential prints that line, as every pattern's hit always has —
  # the hit line is append-only, and callers judge on its text.
  local gh; gh=$(cred github-token)
  seed a.txt "/home/alice/x k=$gh"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] /home/alice/x k=$gh" "$LC_OUT"
}

# v0.10.1: what QA of v0.4.1..v0.10.0 found.

t_credential_private_key_is_never_a_placeholder() {
  # A key body is base64 of a structured format: OpenSSH's unencrypted key
  # puts nine As in its first 64 characters, which read as a placeholder run
  # and set a real key aside, exit 0. A fixture's X-filled body is reported
  # too: the header with a body after it is what makes it a key.
  local h body x
  h="-----BEGIN OPENSSH ""PRIVATE KEY-----"
  body=$(python3 -c '
import base64, random, struct
r = random.Random(5)
def s(b): return struct.pack(">I", len(b)) + b
pub = s(b"ssh-ed25519") + s(r.randbytes(32))
blob = b"openssh-key-v1\0" + s(b"none") + s(b"none") + s(b"") + struct.pack(">I", 1) + s(pub) + s(r.randbytes(160))
print(base64.b64encode(blob).decode())')
  x=$(printf 'X%.0s' {1..64})
  {
    printf '{"k": "%s\\n%s\\n"}\n' "$h" "$body"
    printf 'KEY="%s %s"\n' "$h" "$body"
    printf 'KEY="%s %s"\n' "$h" "$x"
  } > keys.txt
  git add keys.txt
  commit init
  assert_exit 1 "$BIN"
  local n
  for n in 1 2 3; do
    assert_contains "keys.txt:$n: [credential:private-key] $h" "$LC_OUT"
  done
  assert_contains "0 placeholders not reported" "$LC_ERR"
  assert_not_contains "${body:0:24}" "$LC_OUT"
}

t_credential_zero_bytes_are_not_a_placeholder_run() {
  # Base64 of zero bytes is a run of As, and a token holding a zero-filled
  # field (a macaroon's 8-byte key id, here) has one in every real token.
  local fly
  fly=$(python3 -c '
import base64, random
r = random.Random(3)
b = bytes([0x94, 0x93, 0xc4, 0x08]) + (4242).to_bytes(8, "big") + bytes([0xc4, 0x10]) + r.randbytes(16) + bytes([0xc4, 0x60]) + r.randbytes(96)
print("f" "m2_" + base64.b64encode(b).decode())')
  [[ "$fly" == *AAAAAAAA* ]] || { echo "    stand-in has no run of As"; return 1; }
  seed a.txt "FLY_API_TOKEN=$fly"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:flyio-token] $(masked "$fly")" "$LC_OUT"
  assert_contains "0 placeholders not reported" "$LC_ERR"
}

t_credential_jwt_header_in_base64url() {
  # A JWT header segment is base64url: `-` and `_` are in its alphabet.
  local hdr payload sig
  hdr=$(python3 -c 'import base64; print(base64.urlsafe_b64encode(b"{\"alg\":\"HS256\",\"kid\":\"k?>~\"}").decode().rstrip("="))')
  [[ "$hdr" == *[-_]* ]] || { echo "    header has no - or _"; return 1; }
  payload="ey""JzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkFsaWNlIn0"
  sig="Qm9ndXNTaWduYXR1cmVGb3JUZXN0aW5nT25seQ"
  seed a.txt "auth=$hdr.$payload.$sig"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:jwt] $(masked "$hdr.$payload.$sig")" "$LC_OUT"
}

t_credential_huggingface_token_with_digits() {
  # Both Hugging Face prefixes, each body holding a digit.
  local hf org
  { read -r hf; read -r org; } < <(python3 -c '
import random, string
r = random.Random(11)
def body():
    while True:
        s = "".join(r.choice(string.ascii_letters + string.digits) for _ in range(34))
        if any(c.isdigit() for c in s):
            return s
print("h" "f_" + body())
print("api" "_org_" + body())')
  seed a.txt "HF_TOKEN=$hf"
  seed b.txt "HF_ORG_TOKEN=$org"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:huggingface-token] $(masked "$hf")" "$LC_OUT"
  assert_contains "b.txt:1: [credential:huggingface-token] $(masked "$org")" "$LC_OUT"
}

t_credential_in_a_name_is_masked_wherever_the_name_prints() {
  # A token in a path rides along in every hit's location in that file, and
  # in the text of a hit on the name itself; a token in a ref name, in an
  # --strict hit about that ref.
  local gh np
  gh=$(cred github-token)
  np=$(cred npm-token)
  seed "cache-$gh/a.txt" "see /home/alice/x"
  rc_file 'pattern cache-'
  commit init
  git tag "rel-$np" "$(git rev-parse HEAD:.leakcheckrc)"
  assert_exit 1 "$BIN" --history --strict
  assert_contains "cache-$(masked "$gh")/a.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] see /home/alice/x" "$LC_OUT"
  assert_contains "cache-$(masked "$gh")/a.txt:0: [cache-] cache-$(masked "$gh")/a.txt" "$LC_OUT"
  assert_contains "(ref):0: [unscanned:tagged-blob] refs/tags/rel-$(masked "$np") (points at a blob" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
  assert_not_contains "$np" "$LC_OUT"
  assert_exit 1 "$BIN" --history --strict --json
  assert_not_contains "$gh" "$LC_OUT"
  assert_not_contains "$np" "$LC_OUT"
}

t_credential_in_an_allow_rule_is_masked_in_json() {
  # The JSON report prints every allow rule; a credential in one is masked,
  # a stand-in is printed as written.
  local gh aws
  gh=$(cred github-token)
  aws="AK""IA""IOSFODNN7EXAMPLE"
  seed a.txt "k=$gh"
  seed b.txt "k=$aws"
  rc_file "allow credential:* $gh" "allow credential:aws-access-key-id $aws"
  commit init
  assert_exit 0 "$BIN" --json
  assert_not_contains "$gh" "$LC_OUT"
  # Each rule prints as written, its scope included.
  python3 -c '
import json, sys
a = [r["rule"] for r in json.load(open(sys.argv[1]))["allowed"]]
assert a == sys.argv[2:], a' \
    "$LC_OUT" "credential:* $(masked "$gh")" "credential:aws-access-key-id $aws"
  # Whatever the config runs: a rule disabled, or every rule off, still
  # names a key, and the key is still masked.
  rc_file 'disable credential:github-token' "allow credential:github-token $gh"
  assert_exit 0 "$BIN" --json
  assert_not_contains "$gh" "$LC_OUT"
  assert_contains "credential:github-token $(masked "$gh")" "$LC_OUT"
  rc_file 'no-credentials' "allow $gh"
  assert_exit 0 "$BIN" --json
  assert_not_contains "$gh" "$LC_OUT"
  assert_contains "$(masked "$gh")" "$LC_OUT"
}

# ─── v0.11.0: an allow rule's scope ───────────────────────────────────

t_allow_unscoped_never_excuses_a_credential() {
  # A location rule written for home paths hid a real key beside them:
  # clean, exit 0 (v0.10.4). It still excuses the home path.
  local gh; gh=$(cred github-token)
  seed docs/a.md "see /home/alice/notes"
  seed docs/b.md "token: $gh"
  rc_file 'allow ^docs/'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "docs/b.md:1: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_not_contains "docs/a.md" "$LC_OUT"
  assert_contains "1 allowed" "$LC_ERR"
  assert_contains "leakcheck: 1 of them matched an allow rule that names no credential rule" "$LC_ERR"
  # Nor does a whole-line rule, or one naming the token itself — whose two
  # lines put the token in the committed config twice more.
  rc_file "allow ^docs/b\\.md:1:token: $gh\$" "allow $gh"
  assert_exit 1 "$BIN"
  assert_contains "docs/b.md:1: [credential:github-token]" "$LC_OUT"
  assert_contains "3 of them matched an allow rule" "$LC_ERR"
  # A whole-line rule alone draws the hint too (the config's own copy of
  # the token is a second hit, which that rule does not name).
  rc_file "allow ^docs/b\\.md:1:token: $gh\$"
  assert_exit 1 "$BIN"
  assert_contains "leakcheck: 2 credential(s) among these" "$LC_ERR"
  assert_contains "1 of them matched an allow rule" "$LC_ERR"
  # A credential hit no unscoped rule matched gets no hint.
  rc_file 'allow ^nowhere/'
  assert_exit 1 "$BIN"
  assert_not_contains "matched an allow rule" "$LC_ERR"
}

t_allow_unscoped_and_a_placeholder() {
  # A stand-in under an unscoped rule is counted as a stand-in, not allowed,
  # and draws no hint: nothing is reported.
  seed docs/a.md "k=AK""IA""IOSFODNN7EXAMPLE"
  rc_file 'allow ^docs/'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "0 allowed" "$LC_OUT"
  assert_contains "credentials scanned, 1 placeholders not reported" "$LC_OUT"
}

t_allow_credential_scope_excuses_only_its_rule() {
  local gh np; gh=$(cred github-token); np=$(cred npm-token)
  seed fixtures/a.txt "k=$gh"
  seed fixtures/b.txt "k=$np"
  seed fixtures/c.txt "/home/alice/x"
  rc_file 'allow credential:github-token ^fixtures/'
  commit init
  assert_exit 1 "$BIN"
  assert_not_contains "fixtures/a.txt" "$LC_OUT"
  assert_contains "fixtures/b.txt:1: [credential:npm-token]" "$LC_OUT"
  # The hint is for a rule that names no credential rule; this one names one.
  assert_not_contains "matched an allow rule" "$LC_ERR"
  # A scoped rule never excuses a hit that is not a credential.
  assert_contains "fixtures/c.txt:1: [/home/" "$LC_OUT"
  assert_contains "1 allowed" "$LC_ERR"
  # credential:* takes every credential rule, and still no home path.
  rc_file 'allow credential:* ^fixtures/'
  assert_exit 1 "$BIN"
  assert_not_contains "credential:" "$LC_OUT"
  assert_contains "fixtures/c.txt:1: [/home/" "$LC_OUT"
  assert_contains "2 allowed" "$LC_ERR"
  # A scope, (?i) and the per-match form compose; JSON names the rule as
  # written.
  rc_file "allow credential:npm-token (?i)NPM_" 'allow ^fixtures/c\.txt:' 'allow credential:github-token ^fixtures/'
  assert_exit 0 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert [(r["rule"], r["count"]) for r in doc["allowed"]] == [
    ("credential:npm-token (?i)NPM_", 1), ("^fixtures/c\\.txt:", 1),
    ("credential:github-token ^fixtures/", 1)], doc["allowed"]
assert "disabled" not in doc["credentials"], doc["credentials"]
PY
}

t_allow_credential_scope_whole_line() {
  # A scoped rule naming a whole line excuses its own rule's hit on it and
  # nothing else there: not another credential rule's, not a home path.
  # A guard (passes on v0.11.2): it pins the whole-line path of the scope
  # check, which no other test reached (/qaa, v0.11.3).
  local gh np; gh=$(cred github-token); np=$(cred npm-token)
  seed a.txt "$gh $np /home/alice/x"
  rc_file 'allow credential:github-token ^a\.txt:1:.*$'
  commit init
  assert_exit 1 "$BIN"
  assert_not_contains "[credential:github-token]" "$LC_OUT"
  assert_contains "a.txt:1: [credential:npm-token]" "$LC_OUT"
  assert_contains "a.txt:1: [/home/" "$LC_OUT"
  assert_contains "1 allowed" "$LC_ERR"
}

t_allow_credential_scope_in_history() {
  # History hits are judged by the same scope.
  local gh; gh=$(cred github-token)
  seed fixtures/a.txt "k=$gh"
  commit one
  git rm -q fixtures/a.txt
  commit two
  rc_file 'allow ^fixtures/'
  commit rc
  assert_exit 1 "$BIN" --history
  assert_contains ":fixtures/a.txt:1: [credential:github-token]" "$LC_OUT"
  rc_file 'allow credential:github-token ^fixtures/'
  commit rc2
  assert_exit 0 "$BIN" --history
  assert_contains "1 allowed" "$LC_OUT"
}

t_allow_credential_scope_errors() {
  seed a.txt "x"
  commit init
  rc_file 'allow credential:no-such-rule x'
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: allow names no built-in credential rule" "$LC_ERR"
  rc_file 'allow credential:jwt'
  assert_exit 2 "$BIN"
  assert_contains "needs a regex after the rule; to turn the rule off, write: disable credential:jwt" "$LC_ERR"
  rc_file 'allow credential: x'
  assert_exit 2 "$BIN"
  assert_contains "allow credential: names no rule" "$LC_ERR"
  # The regex after the scope gets every check an allow rule gets.
  rc_file 'allow credential:jwt x*'
  assert_exit 2 "$BIN"
  assert_contains "excuse every hit" "$LC_ERR"
  rc_file 'allow credential:jwt \d'
  assert_exit 2 "$BIN"
  rc_file 'allow credential:jwt x '
  assert_exit 2 "$BIN"
  assert_contains "ends in whitespace" "$LC_ERR"
}

t_disable_one_credential_rule() {
  local gh np n; gh=$(cred github-token); np=$(cred npm-token)
  n=$(wc -l < "$CRED_IDS")
  seed a.txt "k=$gh"
  seed b.txt "k=$np"
  rc_file 'disable credential:github-token'
  commit init
  assert_exit 1 "$BIN"
  assert_not_contains "credential:github-token" "$LC_OUT"
  assert_contains "b.txt:1: [credential:npm-token]" "$LC_OUT"
  assert_contains "credentials scanned, 0 placeholders not reported, 1 credential rules disabled by config)" "$LC_ERR"
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$n" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
c = doc["credentials"]
assert c == {"rules": int(sys.argv[2]) - 1, "placeholders": 0,
             "disabled": ["credential:github-token"]}, c
assert list(c) == ["rules", "placeholders", "disabled"], list(c)
PY
  assert_exit 0 "$BIN" --list-patterns
  [[ $(wc -l < "$LC_OUT") -eq $(( 8 + n - 1 )) ]] || { echo "    expected one rule fewer"; return 1; }
  assert_exit 0 "$BIN" --list-rules
  assert_contains "credential:github-token"$'\t'"off" "$LC_OUT"
  assert_contains "credential:npm-token"$'\t'"on" "$LC_OUT"
  # Several on one line; an allow rule may scope a disabled rule.
  rc_file 'disable credential:github-token credential:npm-token' 'allow credential:github-token ^a\.txt:'
  assert_exit 0 "$BIN"
  assert_contains "2 credential rules disabled by config" "$LC_OUT"
  # Every rule turned off one by one is counted, not read as no-credentials;
  # with no-credentials too, it is no-credentials.
  sed 's/^/disable credential:/' "$CRED_IDS" > .leakcheckrc
  git add .leakcheckrc
  assert_exit 0 "$BIN"
  assert_contains "credentials not scanned, $n credential rules disabled by config)" "$LC_OUT"
  assert_exit 0 "$BIN" --json
  python3 - "$LC_OUT" "$CRED_IDS" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
ids = ["credential:" + ln.rstrip("\n") for ln in open(sys.argv[2])]
assert doc["credentials_scanned"] is False, doc
assert doc["credentials"] == {"rules": 0, "placeholders": 0, "disabled": ids}, doc["credentials"]
PY
  echo no-credentials >> .leakcheckrc
  git add .leakcheckrc
  assert_exit 0 "$BIN" --json
  assert_not_contains '"credentials":' "$LC_OUT"
  assert_exit 0 "$BIN"
  assert_not_contains "disabled by config" "$LC_OUT"
  # Refused: an unknown id, every rule, a bare id, nothing.
  rc_file 'disable credential:no-such-rule'
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: disable names no built-in credential rule" "$LC_ERR"
  rc_file 'disable credential:*'
  assert_exit 2 "$BIN"
  assert_contains "write no-credentials" "$LC_ERR"
  rc_file 'disable github-token'
  assert_exit 2 "$BIN"
  assert_contains "disable takes credential rule labels" "$LC_ERR"
  rc_file 'disable'
  assert_exit 2 "$BIN"
  assert_contains "empty disable directive" "$LC_ERR"
}

t_list_rules() {
  seed a.txt "x"
  commit init
  assert_exit 0 "$BIN" --list-rules
  # Every rule, in table order, each the id a stand-in was made for.
  sed 's/^/credential:/; s/$/\ton/' "$CRED_IDS" > .git/want
  diff -u .git/want "$LC_OUT"
  rc_file 'no-credentials'
  assert_exit 0 "$BIN" --list-rules
  # Every rule listed, each off: no rule on is also true of no output.
  sed 's/^/credential:/; s/$/\toff/' "$CRED_IDS" > .git/want
  diff -u .git/want "$LC_OUT"
  # A broken config fails here too.
  rc_file 'disable credential:nope'
  assert_exit 2 "$BIN" --list-rules
}

t_credential_json_escaped_slashes() {
  # Every `/` a rule matches may be written `\/`, as PHP's json_encode and
  # others write it: each rule whose match can hold one is pinned twice, as
  # written and escaped. The `/` sits early in a body, so the escaped text
  # leaves no run long enough for the unescaped rule to match a prefix of.
  local src ids id v
  src=$(cred 1password-token); src=${src:7}
  slashed() { printf '%s/%s' "${1:0:3}" "${1:4}"; }  # a `/` at index 3
  declare -A val=(
    [slack-webhook]="https://$(cred slack-webhook)"
    [discord-webhook]="https://$(cred discord-webhook)"
    [teams-webhook]="https://acme$(cred teams-webhook)"
    [1password-token]="ops""_eyJ$(slashed "${src:0:255}")"
    [azure-storage-key]="Account""Key=$(slashed "${src:0:86}")=="
    [webhook-signing-secret]="wh""sec_$(slashed "${src:0:30}")"
    [sentry-token]="sntr""ys_eyJ$(slashed "${src:0:60}")"
    [grafana-token]="gl""c_$(slashed "${src:0:40}")"
    [flyio-token]="fm""2_$(slashed "${src:0:120}")"
  )
  for id in "${!val[@]}"; do
    v=${val[$id]}
    [[ "$v" == */* ]] || { echo "    $id: no slash to escape"; return 1; }
    printf '%s\n' "k=$v" "{\"k\": \"${v//\//\\/}\"}" > "$id.txt"
    git add "$id.txt"
  done
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "${!val[@]}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = {(h["file"], h["line"], h["pattern"]) for h in doc["hits"]}
for rid in sys.argv[2:]:
    for line in (1, 2):
        assert (rid + ".txt", line, "credential:" + rid) in got, (rid, line, sorted(got))
assert len(doc["hits"]) == 2 * len(sys.argv[2:]), len(doc["hits"])
PY
}

t_credential_allow_rule_written_as_regex_is_masked() {
  # A rule is a regex, so a key in one may have its punctuation escaped
  # (`\.`, `\/`) or bracketed (`[.]`): still a key, masked in --json, the
  # rule shown as written with the key's own bytes masked. A backslash a
  # rule's own class accepts (the JWT's) only matches as written, which is
  # masked as written. A rule naming no key prints exactly as written.
  local sg sw j seg1 seg2 jx esw
  sg=$(cred sendgrid-key); sw=$(cred slack-webhook); j=$(cred jwt)
  seg1=${j%%.*}; seg2=${j#*.}; seg2=${seg2%%.*}
  jx="$seg1.ey${seg2:3:15}\\-."
  esw=${sw//./\\.}; esw=${esw//\//\\/}
  seed c.txt "k=$sg"
  rc_file "allow credential:sendgrid-key ${sg//./\\.}" \
          "allow credential:sendgrid-key ${sg//./[.]}" \
          "allow credential:slack-webhook https:\\/\\/$esw" \
          "allow credential:jwt $jx" \
          'allow ^c\.txt:'
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${sg:3:22}" "$LC_OUT"
  assert_not_contains "${sw: -24}" "$LC_OUT"
  assert_not_contains "${seg2:3:15}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
want = [("credential:sendgrid-key " + sys.argv[2], 1), ("credential:sendgrid-key " + sys.argv[3], 0),
        ("credential:slack-webhook https:\\/\\/" + sys.argv[4], 0), ("credential:jwt " + sys.argv[5], 0),
        ("^c\\.txt:", 0)]
assert a == want, a' \
    "$LC_OUT" "$(masked "${sg//./\\.}")" "$(masked "${sg//./[.]}")" "$(masked "$esw")" "$(masked "$jx")"
}

t_credential_allow_rule_key_split_by_groups_is_masked() {
  # Groups split a key in a rule, `SG\.(<body>)\.(<body>)`: the literal form
  # drops parentheses, so it is still found, and the mask covers the bytes it
  # came from — the rule prints as written up to the key's last byte
  # (/cxr, v0.11.4: the parentheses stayed in, and the bodies printed).
  local sg b1 b2 g
  sg=$(cred sendgrid-key); b1=${sg#SG.}; b1=${b1%%.*}; b2=${sg##*.}
  g="SG\\.($b1)\\.($b2"
  seed c.txt "k=$sg"
  rc_file "allow credential:sendgrid-key $g)"
  commit init
  assert_exit 0 "$BIN" --json
  assert_not_contains "${b1:4:12}" "$LC_OUT"
  assert_not_contains "${b2:4:30}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
assert a == [("credential:sendgrid-key " + sys.argv[2] + ")", 1)], a' "$LC_OUT" "$(masked "$g")"
}

t_credential_allow_rule_keys_found_two_ways_are_both_masked() {
  # One rule, two keys: one only its literal form shows (escaped dots), one
  # only its as-written form shows (a backslash the JWT's class accepts).
  # v0.11.4 printed the literal form, where the second key was no longer
  # there to mask, so it printed whole (/cxr, v0.11.4).
  local sg j seg1 seg2 jx esg
  sg=$(cred sendgrid-key); j=$(cred jwt)
  seg1=${j%%.*}; seg2=${j#*.}; seg2=${seg2%%.*}
  jx="$seg1.ey${seg2:3:15}\\-."
  esg=${sg//./\\.}
  seed c.txt "k=$sg"
  rc_file "allow credential:* $esg $jx"
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${sg:3:22}" "$LC_OUT"
  assert_not_contains "${seg2:3:15}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
assert a == [("credential:* " + sys.argv[2] + " " + sys.argv[3], 0)], a' \
    "$LC_OUT" "$(masked "$esg")" "$(masked "$jx")"
}

t_credential_allow_rule_key_inside_a_key_is_masked() {
  # A key only the literal form shows can hold one the as-written form shows
  # — a Twilio key inside an escaped SendGrid body. Both scans mark bytes of
  # the one rule, so neither mask breaks the other's match: masking the
  # as-written key first, then reading the literal form, printed the
  # SendGrid body. v0.11.4 masked both too; it fails here only on the form
  # it showed, the literal one.
  local sg tw b1 b2 esg2
  sg=$(cred sendgrid-key); tw=$(cred twilio-api-key)
  b1=${sg#SG.}; b1=${b1%%.*}; b2=${sg##*.}
  esg2="SG\\.$b1\\.$tw${b2:0:9}"
  seed c.txt "k=0"
  rc_file "allow credential:* $esg2"
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${b1:4:12}" "$LC_OUT"
  assert_not_contains "${tw:4:20}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
assert a == [("credential:* " + sys.argv[2], 0)], a' "$LC_OUT" "$(masked "$esg2")"
}

t_credential_allow_rule_private_key_is_masked_to_its_end() {
  # A key pasted whole into an allow rule, header and body on one line: the
  # header rule reads at most 64 characters past the header, and the rest of
  # the body printed after them; eight blanks after the header read as a
  # placeholder and none of it was masked (/qaa, v0.11.5).
  local pk body
  pk=$(cred private-key)
  body=$(python3 -c 'import random, string; r = random.Random(5); print("".join(r.choice(string.ascii_letters + string.digits + "+/") for _ in range(1200)))')
  seed c.txt "k=0"
  rc_file "allow credential:private-key $pk\\\\n$body" \
          "allow credential:private-key $pk        $body"
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${body:100:40}" "$LC_OUT"
  assert_not_contains "${body:1100:40}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
assert a == [("credential:private-key " + sys.argv[2], 0), ("credential:private-key " + sys.argv[3], 0)], a' \
    "$LC_OUT" "$(masked "$pk\\\\n$body")" "$(masked "$pk        $body")"
}

t_credential_allow_rule_back_to_back_keys_are_masked() {
  # Two keys back to back in one rule: with every rule in one -o grep, git
  # resumed after the first key's match, which ran into the second, so the
  # second's rule never matched and its tail printed (/qaa, v0.11.5).
  local ps gh
  ps=$(cred planetscale-token); gh=$(cred github-token)
  seed c.txt "k=0"
  rc_file "allow credential:* $ps$gh"
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${gh: -16}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
assert a == [("credential:* " + sys.argv[2], 0)], a' "$LC_OUT" "$(masked "$ps$gh")"
}

t_credential_disabled_rule_still_masks_names() {
  # `disable` and `no-credentials` choose which hits to look for, never which
  # keys may print: a disabled rule's key in a path printed whole in every
  # hit on that file (/qaa, v0.11.5).
  local gh
  gh=$(cred github-token)
  seed "d$gh/a.txt" "see /home/alice/x"
  rc_file 'disable credential:github-token'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "d$(masked "$gh")/a.txt:1: [" "$LC_OUT"
  assert_not_contains "${gh:4:30}" "$LC_OUT"
  assert_exit 1 "$BIN" --json
  assert_not_contains "${gh:4:30}" "$LC_OUT"
  rc_file 'no-credentials'
  assert_exit 1 "$BIN"
  assert_contains "d$(masked "$gh")/a.txt:1: [" "$LC_OUT"
  assert_not_contains "${gh:4:30}" "$LC_OUT"
}

t_credential_overlapping_keys_in_a_name_are_masked() {
  # Two rules over one name's bytes, the longer disabled: replacing the
  # shorter match first left the longer nothing to match, and its last eight
  # characters printed in every hit on the file (Codex, v0.11.6). A legacy
  # openai-key is `sk-` and 40 characters; its first 32, if hex, are a
  # deepseek-key.
  # The directory is `d-`, not `d`: since v0.11.11 a deepseek-key may not
  # follow a lowercase letter, and the overlap is the point.
  local ds tok
  ds=$(cred deepseek-key); tok="$ds${ds:3:8}"
  seed "d-$tok/a.txt" "see /home/alice/x"
  rc_file 'disable credential:openai-key'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "d-$(masked "$tok")/a.txt:1: [" "$LC_OUT"
  assert_not_contains "${tok: -8}" "$LC_OUT"
  assert_exit 1 "$BIN" --json
  assert_not_contains "${tok: -8}" "$LC_OUT"
}

t_credential_deepseek_key_has_a_left_edge() {
  # `sk-` + 32 hex inside a name — desk-, task-, flask-, ask- — is no key
  # (the corpus harness's three look-alikes, v0.11.1 to v0.11.10). A key
  # after punctuation, at a line's start or after a JSON escape still hits,
  # and prints from its `sk-`: the edge character is not part of the key.
  local ds hex
  ds=$(cred deepseek-key); hex=${ds:3}
  seed a.txt "$(printf 'desk-%s\ntask-%s\nflask-%s\nAsk ask-%s' "$hex" "$hex" "$hex" "$hex")"
  rc_file 'no-defaults'
  commit init
  assert_exit 0 "$BIN"
  seed b.txt "$(printf 'KEY=%s\n%s\n"x\\n%s"' "$ds" "$ds" "$ds")"
  commit b
  assert_exit 1 "$BIN"
  local n
  for n in 1 2 3; do
    assert_contains "b.txt:$n: [credential:deepseek-key] $(masked "$ds")" "$LC_OUT"
  done
  assert_contains "leakcheck: 3 match(es)" "$LC_ERR"
  # An `=` or `/` a writer escaped — JSON's `\u` and four hex digits, `\x`
  # and two, a URL's `%` and two — ends in a lowercase letter, and the edge
  # refused the key after it, exit 0 (v0.11.11 to v0.16.0).
  printf '"u":"k\\u%s%s"\nk=\\x3d%s\nq?k=a%%3d%s\nr%%2f%s\n' 003d "$ds" "$ds" "$ds" "$ds" > c.txt
  git add c.txt
  commit c
  assert_exit 1 "$BIN"
  for n in 1 2 3 4; do
    assert_contains "c.txt:$n: [credential:deepseek-key] $(masked "$ds")" "$LC_OUT"
  done
  assert_contains "leakcheck: 7 match(es)" "$LC_ERR"
}

t_credential_webhook_urls_stop_at_their_segments() {
  # A webhook rule's body ran across `/`, so what followed the secret joined
  # the match: `<url>/XXXXXXXX` was set aside as a stand-in, exit 0 (v0.11.3
  # §7); and a Teams URL's `V2…` segment holds `_`, which ended the match, so
  # the rest of it printed where an allow rule names the URL. Each rule now
  # matches its issuer's segments and stops; GovSlack, Discord's versioned
  # path and the old Outlook host are found too.
  local sw ds tw gh v2 esw
  sw=$(cred slack-webhook); ds=$(cred discord-webhook); tw=$(cred teams-webhook); gh=$(cred github-token)
  v2="V2${gh:4:20}_${gh:24:12}"
  esw=${sw//\//\\/}
  seed a.txt "$(printf 'A=https://%s/XXXXXXXX\nB="https:\\/\\/%s\\/XXXXXXXX"\nC=https://%s\nD=https://%s\nE=https://acme%s/%s\nF=https://outlook.office.com/webhook/%s\nG=https://outlook.office365.com/webhook/%s' \
    "$sw" "$esw" "${sw/.slack./.slack-gov.}" "${ds/api\/webhooks/api/v10/webhooks}" "$tw" "$v2" "${tw#*webhookb2/}" "${tw#*webhookb2/}")"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:slack-webhook] $(masked "$sw")" "$LC_OUT"
  assert_contains "a.txt:2: [credential:slack-webhook] $(masked "$esw")" "$LC_OUT"
  assert_contains "a.txt:3: [credential:slack-webhook] $(masked "${sw/.slack./.slack-gov.}")" "$LC_OUT"
  assert_contains "a.txt:4: [credential:discord-webhook] $(masked "${ds/api\/webhooks/api/v10/webhooks}")" "$LC_OUT"
  assert_contains "a.txt:5: [credential:teams-webhook] $(masked "$tw/$v2")" "$LC_OUT"
  assert_contains "a.txt:6: [credential:teams-webhook] $(masked "outlook.office.com/webhook/${tw#*webhookb2/}")" "$LC_OUT"
  assert_contains "a.txt:7: [credential:teams-webhook] $(masked "outlook.office365.com/webhook/${tw#*webhookb2/}")" "$LC_OUT"
  assert_contains "leakcheck: 7 match(es)" "$LC_ERR"
  assert_contains "0 placeholders not reported" "$LC_ERR"
  rc_file "allow credential:teams-webhook ${tw//./\\.}/$v2"
  assert_exit 1 "$BIN" --json
  assert_not_contains "${gh:24:12}" "$LC_OUT"
  assert_not_contains "${gh:4:20}" "$LC_OUT"
}

t_credential_issuer_variants() {
  # Every format the issuers document that the rules missed until v0.12.0
  # (re-sourced from the issuers, stage B′): each line holds one, and must
  # hit its own rule exactly once, printed masked at its full length — an
  # open maximum masks a longer key whole. A stateless GitHub installation
  # token, `ghs_<app id>_<JWT>`, is found by `jwt` from its `ey`.
  local vt="$PWD/.git/variants.tsv"
  python3 -I "$SCRIPT_DIR/credential_specs.py" --variants > "$vt"
  local -a ids=() ms=()
  local id line m n=0
  : > v.txt
  while IFS=$'\t' read -r id line m; do
    printf '%s\n' "$line" >> v.txt
    ids+=("$id"); ms+=("$m")
  done < "$vt"
  git add v.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN"
  for n in "${!ids[@]}"; do
    m=${ms[n]}
    if [[ "${ids[n]}" == jwt ]]; then m="ey${m#*_ey}"; fi
    assert_contains "v.txt:$((n + 1)): [credential:${ids[n]}] $(masked "$m")" "$LC_OUT"
  done
  assert_contains "leakcheck: ${#ids[@]} match(es)" "$LC_ERR"
  for m in "${ms[@]}"; do assert_not_contains "${m:6:24}" "$LC_OUT"; done
}

t_credential_zero_bytes_are_no_aws_or_facebook_key() {
  # Base64 of mostly-zero binary (a font, a protobuf) is long runs of `A`, so
  # `ACCA`, `ABIA` and `EAA` + more `A`s read as an AWS key id or a Facebook
  # token (corpus harness, v0.12.0). In those two rules a match that is at
  # least half (AWS) or an eighth (Facebook) `A`, or holds a run of eight, is
  # a stand-in; the real-shaped stand-ins of both still hit.
  local aws fb
  aws=$(cred aws-access-key-id); fb=$(cred facebook-token)
  # Lines 1 and 3 hold no run of eight, so only the share catches them;
  # line 4 is random but for one run of eight, which only the run catches.
  # Line 3's run follows a space: since v0.29.0 EAA after a base64
  # character is no candidate at all (facebook-token's left edge).
  local q7
  q7=$(printf 'AAAAAAAQ%.0s' {1..13})
  seed z.txt "$(printf '%s\n' \
    "src: url(data:font/ttf;base64,AAEAAAAKA""CCA""AAAAAQAAAAAAAGAAAAAAAAQAAAAAAAAAAAAZ8AAA);" \
    "blob: AAAQ""ABIA""AAAAAAAUAAAAAAAAAAAAAAAAA" \
    "pb: ""EAAM$q7" \
    "one run: EA""AC${fb:4:110}AAAAAAAA${fb:4:110}")"
  rc_file 'no-defaults'
  commit init
  assert_exit 0 "$BIN"
  assert_contains "credentials scanned, 4 placeholders not reported" "$LC_OUT"
  seed k.txt "$(printf 'A=%s\nF=%s' "$aws" "$fb")"
  commit k
  assert_exit 1 "$BIN"
  assert_contains "k.txt:1: [credential:aws-access-key-id]" "$LC_OUT"
  assert_contains "k.txt:2: [credential:facebook-token]" "$LC_OUT"
  assert_contains "leakcheck: 2 match(es)" "$LC_ERR"
}

t_credential_pgp_secret_and_ssh2_headers() {
  # PGP 2's `SECRET KEY BLOCK`, which GnuPG still reads, and the ssh.com
  # header PuTTYgen exports (four dashes, spaces inside) are private keys
  # too. A hit prints the header alone: the SSH2 one, as a match running on
  # into the body, printed that body's first 64 characters until its own
  # branch in the display.
  local body
  body=$(cred github-token); body="${body:4:32}${body:4:32}"
  seed k.txt "$(printf '%s\n' \
    "-----BEGIN PGP SEC""RET KEY BLOCK-----" \
    "---- BEGIN SSH2 ENCRYPTED PRIV""ATE KEY ---- $body")"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "k.txt:1: [credential:private-key] -----BEGIN PGP SEC""RET KEY BLOCK-----" "$LC_OUT"
  assert_contains "k.txt:2: [credential:private-key] ---- BEGIN SSH2 ENCRYPTED PRIV""ATE KEY ----" "$LC_OUT"
  assert_not_contains "${body:0:24}" "$LC_OUT"
  assert_contains "leakcheck: 2 match(es)" "$LC_ERR"
}

t_credential_github_checksum() {
  # A classic GitHub token's last six are the base62 CRC-32 of the 30 before
  # them (GitHub; the byte-level scheme confirmed on a real token). One that
  # fails is a stand-in, counted; the same body under another prefix passes
  # (the prefix is not in the sum); a longer run, or an npm_ token, gets no
  # checksum and is reported; a failing token is masked all the same.
  local gh last bad np
  gh=$(cred github-token); np=$(cred npm-token)
  last=${gh: -1}; if [[ "$last" == 0 ]]; then last=1; else last=0; fi
  bad="${gh:0:39}$last"
  printf '%s\n' "A=$gh" "B=$bad" "C=${bad}Z" "D=gh""o_${gh:4}" "E=gh""u_${bad:4}" "F=$np" > c.txt
  git add c.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "c.txt:1: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_contains "c.txt:3: [credential:github-token] $(masked "${bad}Z")" "$LC_OUT"
  assert_contains "c.txt:4: [credential:github-token]" "$LC_OUT"
  assert_contains "c.txt:6: [credential:npm-token]" "$LC_OUT"
  assert_not_contains "c.txt:2:" "$LC_OUT"
  assert_not_contains "c.txt:5:" "$LC_OUT"
  assert_contains "leakcheck: 4 match(es)" "$LC_ERR"
  assert_contains "credentials scanned, 2 placeholders not reported" "$LC_ERR"
  rc_file 'no-defaults' "allow credential:github-token $bad"
  assert_exit 1 "$BIN" --json
  assert_not_contains "${bad:4:30}" "$LC_OUT"
}

t_credential_pkcs12_file() {
  # A PKCS #12 bundle is binary, so its name is the only tell: pkcs12-file
  # runs over tracked path names, any case, anchored at the end — never over
  # content, a symlink target, or a name it then masks; its hit's text is
  # the name, masked only for a key in it; never a stand-in.
  local gh first; gh=$(cred github-token)
  mkdir -p certs keys
  printf '\x30\x82\x00\x01' > certs/client.p12
  : > Server.PFX
  : > example.p12
  : > "keys/$gh.p12"
  printf '%s\n' "at /home/alice/x" > bundle.pfx
  printf '%s\n' "see certs/client.p12" "key.pfx" > notes.txt
  : > doc.p12.md
  : > p12.txt
  ln -s certs/client.p12 link
  ln -s other.pfx dangling
  git add .
  commit init
  first=$(sha_of)
  assert_exit 1 "$BIN"
  assert_contains "certs/client.p12:0: [credential:pkcs12-file] certs/client.p12" "$LC_OUT"
  assert_contains "Server.PFX:0: [credential:pkcs12-file] Server.PFX" "$LC_OUT"
  assert_contains "example.p12:0: [credential:pkcs12-file] example.p12" "$LC_OUT"
  assert_contains "bundle.pfx:0: [credential:pkcs12-file] bundle.pfx" "$LC_OUT"
  assert_contains "bundle.pfx:1: [" "$LC_OUT"
  assert_contains "keys/$(masked "$gh").p12:0: [credential:pkcs12-file] keys/$(masked "$gh").p12" "$LC_OUT"
  assert_contains "keys/$(masked "$gh").p12:0: [credential:github-token]" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
  assert_not_contains "notes.txt" "$LC_OUT"
  assert_not_contains "doc.p12.md" "$LC_OUT"
  assert_not_contains "p12.txt" "$LC_OUT"
  assert_not_contains "link" "$LC_OUT"
  assert_not_contains "dangling" "$LC_OUT"
  assert_contains "leakcheck: 7 match(es)" "$LC_ERR"
  assert_contains "1 binary skipped" "$LC_ERR"
  assert_contains "0 placeholders not reported" "$LC_ERR"
  # Scoped like any credential rule: its own allow scope excuses it, an
  # unscoped rule never does and says so; disable turns it off, counted.
  rc_file 'allow credential:pkcs12-file ^certs/' 'allow ^Server\.PFX:'
  assert_exit 1 "$BIN"
  assert_not_contains "certs/client.p12:0:" "$LC_OUT"
  assert_contains "Server.PFX:0: [credential:pkcs12-file]" "$LC_OUT"
  assert_contains "1 of them matched an allow rule that names no credential rule" "$LC_ERR"
  rc_file 'disable credential:pkcs12-file'
  assert_exit 1 "$BIN"
  assert_not_contains "[credential:pkcs12-file]" "$LC_OUT"
  assert_contains "keys/$(masked "$gh").p12:0: [credential:github-token]" "$LC_OUT"
  assert_contains "1 credential rules disabled by config" "$LC_ERR"
  # Every content rule off, the path rule on: credentials are still scanned,
  # and a key in a bundle's name still masked.
  cut -f1 "$CRED_TSV" | sed 's/^/disable credential:/' > .leakcheckrc
  git add .leakcheckrc
  assert_exit 1 "$BIN"
  assert_contains "keys/$(masked "$gh").p12:0: [credential:pkcs12-file] keys/$(masked "$gh").p12" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
  assert_contains "credentials scanned, 0 placeholders not reported, $(wc -l < "$CRED_TSV") credential rules disabled by config" "$LC_ERR"
  # History: a removed bundle is still published by the commit that added it.
  rc_file 'no-defaults'
  git rm -q -r certs keys bundle.pfx example.p12 Server.PFX
  commit gone
  assert_exit 0 "$BIN"
  assert_exit 1 "$BIN" --history
  assert_contains "$first:Server.PFX:0: [credential:pkcs12-file] Server.PFX" "$LC_OUT"
  assert_contains "$first:certs/client.p12:0: [credential:pkcs12-file] certs/client.p12" "$LC_OUT"
  assert_not_contains "notes.txt" "$LC_OUT"
}

t_credential_pkcs12_file_ends_a_whole_name() {
  # A name holding a newline spans several lines of the names pass, and the
  # rule's `$` matched each line's end: `looks.p12`, a newline and `but.txt`
  # read as a bundle (Codex, the /qaa of v0.16.1). A match counts only on a
  # name's last line, in the tree and in history; a name that ends in `.p12`
  # after a newline is still one.
  printf 'x' > "$(printf 'looks.p12\nbut.txt')"
  printf 'x' > "$(printf 'a\nb.p12')"
  git add .
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["file"], h["pattern"]) for h in doc["hits"])
assert got == [("a\nb.p12", "credential:pkcs12-file")], got
PY
  git rm -q -r .
  commit gone
  assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["file"], h["pattern"], h["source"]) for h in doc["hits"])
assert got == [("a\nb.p12", "credential:pkcs12-file", "history")], got
PY
}

t_credential_tail_after_a_slash_in_a_body() {
  # Six rules take `/` as a body character, so text after a key joins its
  # match: a key followed by `/XXXXXXXX` read as a stand-in and was set
  # aside, exit 0. Each is judged up to its first `/`: a key with a tail is
  # reported, after `/`, `\/` and a second `/`. Guards: a stand-in shaped
  # before any `/` is still set aside, and a webhook, whose `/` ends a
  # segment, is still judged whole, its secret segment the stand-in.
  local vt="$PWD/.git/slash.tsv" id m sw
  python3 -I "$SCRIPT_DIR/credential_specs.py" --slash > "$vt"
  sw=$(cred slack-webhook)
  : > s.txt
  while IFS=$'\t' read -r id m; do
    printf '%s\n' "k=$m/XXXXXXXX" "k=$m\\/XXXXXXXX" "k=$m/XXXXXXXX/x" >> s.txt
  done < "$vt"
  printf '%s\n' "k=wh""sec_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" "k=${sw%/*}/XXXXXXXXXXXXXXXXXXXXXXXX" >> s.txt
  git add s.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$vt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
assert len(rows) == 6, rows
want = sorted((3 * k + j + 1, "credential:" + cid) for k, (cid, m) in enumerate(rows) for j in range(3))
got = sorted((h["line"], h["pattern"]) for h in doc["hits"])
assert got == want, (got, want)
assert doc["credentials"]["placeholders"] == 2, doc["credentials"]
PY
}

t_credential_glued_tail_is_no_stand_in() {
  # v0.12.0 opened eight fixed lengths at their end (`{36}` to `{36,}`), so
  # letters and digits glued after a key joined the match: a key followed by
  # `12345678` read as a stand-in, set aside, exit 0, and printed whole in an
  # error (to v0.16.0). Those rules' stand-in test also judges the shortest
  # start of the match the rule matches, so each key with that tail is
  # reported, once. Guard: a key X-filled from its start is still a stand-in
  # with the tail.
  local id line m gh
  gh=$(cred github-token)
  : > g.txt
  while IFS=$'\t' read -r id line m; do
    case "$id" in
      github-token|npm-token|groq-key|perplexity-key|xai-key|atlassian-token|heroku-key|terraform-cloud-token)
        printf '%s\n' "${line%%"$m"*}${m}12345678${line#*"$m"}" >> g.txt ;;
    esac
  done < "$CRED_TSV"
  printf '%s\n' "k=gh""p_$(printf 'X%.0s' {1..36})12345678" >> g.txt
  git add g.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$(wc -l < g.txt)" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
got = sorted(h["line"] for h in doc["hits"])
assert n == 9 and got == list(range(1, n)), (got, n)
assert doc["credentials"]["placeholders"] == 1, doc["credentials"]
PY
  assert_exit 2 "$BIN" "--x=${gh}12345678"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
}

t_long_line_hit_is_quick() {
  # A hit on a very long line took minutes: counting a record's lines and
  # splitting it into subject lines grew with the square of its length in
  # bash (a 200 KB line, one hit, one allow rule: 19 s; 1.2 MB: minutes in
  # any locale). A 1.2 MB line holding a home path and a key, under an allow
  # rule, so every per-hit pass runs; reported within the bound.
  local k
  k=$(cred anthropic-key)
  python3 -I - "$k" <<'PY'
import base64, random, sys
random.seed(7)
b = base64.b64encode(random.randbytes(900000)).decode()
open("big.svg", "w").write('<svg><image href="data:image/png;base64,' + b[:600000]
                           + " /home/alice/x k=" + sys.argv[1] + " " + b[600000:] + '"/></svg>\n')
PY
  git add big.svg
  rc_file 'allow ^docs/'
  commit init
  assert_exit 1 timeout 30 "$BIN" --json
  python3 - "$LC_OUT" "$(masked "$k")" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert [(h["file"], h["line"]) for h in doc["hits"]] == [("big.svg", 1)] * 2, len(doc["hits"])
cred = [h for h in doc["hits"] if h["pattern"] == "credential:anthropic-key"]
home = [h for h in doc["hits"] if not h["pattern"].startswith("credential:")]
assert len(cred) == 1 and len(home) == 1, [h["pattern"] for h in doc["hits"]]
assert cred[0]["text"] == sys.argv[2], cred[0]["text"][:80]
assert "/home/alice/x" in home[0]["text"]
PY
}

t_long_credential_match_is_quick() {
  # The stand-in check walked a match one character at a time, and each
  # `${m:i:1}` measures the whole match: 200 KB took 17 s, 400 KB 66 s. A
  # 400 KB match, not a stand-in, is reported within the bound.
  python3 -I - <<'PY'
import random
random.seed(11)
abc = "abcdefghijkmnpqrstuvwxyzBCDEFGHJKLMNPQRSTUVWXYZ23456789"
open("long.txt", "w").write("t=" + "EA" + "AM" + "".join(random.choice(abc) for _ in range(400000)) + "\n")
PY
  git add long.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 timeout 30 "$BIN"
  assert_contains "long.txt:1: [credential:facebook-token] EAAM[redacted, 400004 chars]" "$LC_OUT"
}

t_kv_rules_find_unprefixed_secrets() {
  # Stage C: a secret with no prefix of its own is found by a keyword, an
  # assignment and a value random enough, in each syntax that writes one,
  # and prints as its keyword (a URL's scheme) and the value's length,
  # never a byte of the value; a key with a placeholder-shaped tail after a
  # `/` is still a key (CRED_SLASH), its stopword test cut there too.
  local vt="$PWD/.git/kv.tsv" v
  python3 -I - "$vt" <<'PY'
import random, sys
r = random.Random(41)
an = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"
def val(n):
    return "".join(r.choice(an) for _ in range(n - 2)) + str(r.randint(2, 9)) + "q"
rows = [
    ("generic-secret", "API_KEY=%s", "API_KEY", 32),
    ("generic-secret", 'export DB_PASSWORD="%s"', "PASSWORD", 20),
    ("generic-secret", '  "client_secret": "%s",', "secret", 40),
    ("generic-secret", '{"id":1,"token":"%s"}', "token", 24),
    ("generic-secret", "password: %s", "password", 16),
    ("generic-secret", "token = '%s'", "token", 28),
    ("generic-secret", "run --api-key=%s now", "api-key", 30),
    ("aws-secret-access-key", "aws_secret_access_key = %s", "aws_secret_access_key", 40),
    ("url-password", "DATABASE_URL=postgres://app:%s@db:5432/app", "postgres://", 18),
    ("url-password", "redis://:%s@cache:6379", "redis://", 16),
    ("url-password", '"url": "mysql:\\/\\/root:%s@db"', "mysql://", 14),
    ("generic-secret", "secret_key = '%s/XXXXXXXX'", "secret", 22),
]
with open(sys.argv[1], "w") as f:
    for cid, fmt, kw, n in rows:
        v = val(n) if cid != "aws-secret-access-key" else "".join(r.choice(an + "0123456789+/") for _ in range(n))
        tail = 9 if "/XXXXXXXX" in fmt else 0
        f.write("\t".join((cid, fmt % v, v, "%s[redacted, %d chars]" % (kw, n + tail))) + "\n")
PY
  cut -f2 "$vt" > k.txt
  git add k.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$vt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
want = sorted((n + 1, "credential:" + cid, shown) for n, (cid, _, _, shown) in enumerate(rows))
assert got == want, (got, want)
assert doc["credentials"]["placeholders"] == 0 and "weak" not in doc["credentials"], doc["credentials"]
PY
  assert_exit 1 "$BIN"
  assert_contains "k.txt:3: [credential:generic-secret] secret[redacted, 40 chars]" "$LC_OUT"
  while IFS=$'\t' read -r _ _ v _; do
    assert_not_contains "$v" "$LC_OUT"
    assert_not_contains "$v" "$LC_ERR"
  done < "$vt"
}

t_kv_weak_values_are_counted() {
  # A keyword rule's value that is no secret — a stopword, a placeholder's
  # shape, too little entropy, a dotted name, an environment variable's name,
  # no digit — is set aside and counted apart from the placeholders, each of
  # the first six lines weak for that one reason alone; a
  # colon with no blank after it is no assignment, so this tool's own
  # `credential:<id>` and `token:<value>` are not read at all.
  printf '%s\n' \
    'password = "changeme1234567q"' \
    "api_key = \"aB3dE6gH9j$(printf 'Z%.0s' {1..8})kM2nPq5rS7tU\"" \
    'api_key = "abcdabcdabcdabcd1"' \
    'secret = conf9.bkpz.vqlmw' \
    'API_KEY=MY_SVC_QWZ_K9_PRD' \
    'token = "kQwPrTyUiOnAsDfGh"' \
    'tokenizer = AutoTokenizer.from_pretrained(name)' \
    'url = "postgres://user:password1q@localhost"' \
    'redis://:pa55word@localhost' \
    "aws_secret_access_key = $(printf 'A%.0s' {1..40})" \
    'max_tokens: 4096' \
    'see credential:Xk3j9fLq2mZp7wR4 here' \
    'token:Xk3j9fLq2mZp7wR4' > w.txt
  git add w.txt
  rc_file 'no-defaults' 'disable credential:github-token'
  commit init
  assert_exit 0 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["credentials"]
assert c["placeholders"] == 0 and c["weak"] == 10, c
assert list(c) == ["rules", "placeholders", "disabled", "weak"], list(c)
PY
  assert_exit 0 "$BIN"
  assert_contains "credentials scanned, 0 placeholders not reported, 1 credential rules disabled by config, 10 weak keyword values not reported)" "$LC_OUT"
}

t_kv_rules_yield_to_a_fixed_format_rule() {
  # A key a fixed-format rule matched is that rule's: the keyword rules do
  # not report it again, and the generic rule yields to the other keyword
  # rules too. Only to a rule that ran: with github-token disabled, the
  # keyword rules report those lines themselves.
  local gh aws
  gh=$(cred github-token)
  aws=$(python3 -I -c 'import random; r = random.Random(43); print("".join(r.choice("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789+/") for _ in range(40)))')
  printf '%s\n' "GITHUB_TOKEN=$gh" "aws_secret_access_key = $aws" "https://bot:$gh@github.com/o/r" > y.txt
  git add y.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["line"], h["pattern"]) for h in doc["hits"])
assert got == [(1, "credential:github-token"), (2, "credential:aws-secret-access-key"), (3, "credential:github-token")], got
PY
  rc_file 'no-defaults' 'disable credential:github-token'
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
assert got == [(1, "credential:generic-secret", "TOKEN[redacted, 40 chars]"),
               (2, "credential:aws-secret-access-key", "aws_secret_access_key[redacted, 40 chars]"),
               (3, "credential:url-password", "https://[redacted, 40 chars]")], got
PY
  assert_not_contains "${gh:4:30}" "$LC_OUT"
}

t_kv_rules_yield_to_a_key_they_run_into() {
  # A keyword rule's value is capped at 100 and may start before a fixed
  # rule's key: in `ab12_<JWT>` it neither holds the key whole nor is held
  # by it, and was reported beside the key (corpus harness, v0.16.1; v0.16.0
  # set such a value aside as a dotted name instead). Holding the key's
  # first 16 bytes, it overlaps the key and is the key's rule's.
  local j
  j=$(cred jwt)
  printf '%s\n' "SECRET=ab12_$j" > o.txt
  git add o.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = [(h["line"], h["pattern"]) for h in doc["hits"]]
assert got == [(1, "credential:jwt")], got
assert "weak" not in doc["credentials"] and doc["credentials"]["placeholders"] == 0, doc["credentials"]
PY
}

t_kv_rules_yield_by_position_not_text() {
  # A partial overlap is judged by position. A client secret opening like an
  # allowed JWT on its line shares the JWT's first 16 bytes but none of its
  # place, and v0.16.1, comparing text, dropped it, exit 0 (Codex, the /qaa
  # of v0.16.1). Every place a match sits must touch the key: a second
  # `SECRET=` holding the JWT's start alone also sits where the first does,
  # and is still reported for the place it does not touch one.
  local j r
  j=$(cred jwt)
  r=$(python3 -I -c 'import random; r = random.Random(61); a = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"; print("".join(r.choice(a) for _ in range(29)) + "7")')
  printf '%s\n' "{\"id_token\":\"$j\",\"client_secret\":\"${j:0:16}$r\"}" "SECRET=ab12_$j;SECRET=ab12_${j:0:60}" > p.txt
  git add p.txt
  rc_file 'no-defaults' 'allow credential:jwt ^p\.txt:1:'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$(( 16 + ${#r} ))" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["line"], h["pattern"]) for h in doc["hits"])
assert got == [(1, "credential:generic-secret"), (2, "credential:generic-secret"), (2, "credential:jwt")], got
one = [h["text"] for h in doc["hits"] if h["line"] == 1]
assert one == ["secret[redacted, %s chars]" % sys.argv[2]], one
assert [a["count"] for a in doc["allowed"]] == [1], doc["allowed"]
PY
}

t_kv_overlaps_on_a_crowded_line_are_quick() {
  # A value that runs into a key yields to it wherever the match sits, and
  # v0.16.2 searched the line for every candidate key at every match: 50
  # `SECRET=ab12_<JWT>` on a line took 15 s, 100 over 30 (Codex, /cxr
  # 148aa93). Three hundred of one JWT on a line, and two hundred
  # distinct ones, are judged within the bound, and every value still
  # yields to its key.
  local j
  j=$(cred jwt)
  python3 -I - "$j" <<'PY'
import random, sys
j = sys.argv[1]; h, p, s = j.split(".")
r = random.Random(17); a = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
same = " ".join(["SECRET=ab12_" + j] * 300)
dist = " ".join("SECRET=ab12_%s.%s%s.%s" % (h, p[:-8], "".join(r.choice(a) for _ in range(8)), s) for _ in range(200))
open("crowd.txt", "w").write(same + "\n" + dist + "\n")
PY
  git add crowd.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 timeout 30 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["line"], h["pattern"]) for h in doc["hits"])
assert got == [(1, "credential:jwt"), (2, "credential:jwt")], got
PY
}

t_kv_overlap_edges_are_judged_at_their_place() {
  # Guard: v0.16.2's judgement, which v0.16.3 rebuilt for speed; each line
  # pins a part that no other test reached, and passes on v0.16.2 by design.
  # 1. A value touching a key by fewer than 16 bytes is no partial overlap,
  #    though it opens like a key elsewhere on the line: still reported.
  # 2. A value a key holds yields wherever it sits (holding is a text test).
  # 3. A value that opens inside a key and runs past it yields to that key:
  #    a URL password holding `SECRET=`, the generic value running past `@`.
  local g j r p
  g=$(cred github-token); j=$(cred jwt)
  r=$(python3 -I -c 'import random; r = random.Random(23); a = "abcdfghijkmnpqrstuvwxz23456789"; print("".join(r.choice(a) for _ in range(73)))')
  p=$(python3 -I -c 'import random; r = random.Random(29); a = "ABCDFGHJKLMNPQRSTUVWXZabcdfghijkmnpqrstuvwxz23456789"; print("".join(r.choice(a) for _ in range(20)))')
  printf '%s\n' "$g SECRET=${g:0:16}!$r$j" "$j token=\"${j:40:80}\"" "postgres://user:xSECRET=$p@db7/q9" > e.txt
  git add e.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted((h["line"], h["pattern"]) for h in doc["hits"])
assert got == [(1, "credential:generic-secret"), (1, "credential:github-token"), (1, "credential:jwt"), (2, "credential:jwt")], got
PY
}

t_caller_shell_settings_do_not_reach_the_scan() {
  # A compatibility level of 4.2 or lower read a quoted `=~` needle as a
  # regex: a near-copy of an allowed JWT (a `.` changed) was taken for it,
  # and the real secret behind `SECRET=` yielded, exit 0 (Codex, /cxr
  # 00b04d9); the JSON escaping broke too (v0.16.2 as well), and
  # `nocasematch` from BASH_ENV dropped the same secret. Each way in, the
  # secret is reported.
  local j f e
  j=$(cred jwt); f=${j/./X}
  printf '%s\n' "$j SECRET=$f" > s.txt
  git add s.txt
  rc_file 'no-defaults' 'allow credential:jwt ^s\.txt:1:'
  commit init
  printf 'shopt -s nocasematch\n' > .git/nocase.sh
  for e in BASH_COMPAT=3.1 BASH_COMPAT=4.2 BASHOPTS=compat31 "BASH_ENV=$PWD/.git/nocase.sh"; do
    assert_exit 1 env "$e" "$BIN" --json
    python3 - "$LC_OUT" "$e" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
got = sorted(h["pattern"] for h in doc["hits"])
assert got == ["credential:generic-secret"], (sys.argv[2], got)
PY
  done
}

t_kv_values_are_masked_where_they_print() {
  # An allow rule naming a keyword rule's value prints it masked, keyword
  # included (a masked run shows its first four bytes, which for a value
  # would be the value's), and a value in the committed config is a hit
  # there, as any key is; an error quoting one is masked too. A key a
  # fixed-format rule matched inside it keeps that rule's mask.
  local v="Xk3j9fLq2mZp7wR4tY6u" gh
  gh=$(cred github-token)
  printf '%s\n' "token = '$v'" > m.txt
  git add m.txt
  rc_file 'no-defaults' "allow credential:generic-secret ^m\\.txt:1:token = '$v'\$"
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${v:2:14}" "$LC_OUT"
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
hits = [(h["file"], h["line"], h["pattern"], h["text"]) for h in doc["hits"]]
assert hits == [(".leakcheckrc", 2, "credential:generic-secret", "token[redacted, 20 chars]")], hits
a = [(x["rule"], x["count"]) for x in doc["allowed"]]
assert a == [(r"credential:generic-secret ^m\.txt:1:toke[redacted, 29 chars]'$", 1)], a
PY
  assert_exit 2 "$BIN" "--password=$v"
  assert_contains "leakcheck: unknown flag: --pass[redacted, 29 chars]" "$LC_ERR"
  assert_not_contains "${v:2:14}" "$LC_ERR"
  assert_exit 2 "$BIN" "--token=$gh"
  assert_contains "leakcheck: unknown flag: --token=$(masked "$gh")" "$LC_ERR"
  # A name holding `example` is no stand-in's value: masked as a whole
  # match, the value printed (v0.16.0).
  assert_exit 2 "$BIN" "--password_example=$v"
  assert_not_contains "${v:2:14}" "$LC_ERR"
  # A value that runs into a key yields to it at the hit, but here only when
  # one holds the other: v0.16.1 yielded to a partial overlap and printed
  # the value's bytes before the key.
  assert_exit 2 "$BIN" "--secret=ab12_$(cred jwt)"
  assert_not_contains "ab12_" "$LC_ERR"
}

t_kv_url_password_takes_rfc3986_sub_delims() {
  # RFC 3986's userinfo takes the sub-delims `$&'(),;` unescaped, in the user
  # and the password, and `:` past the first; a password holding one was no
  # match at all, exit 0 (v0.16.0; the colon, Codex, the /qaa of v0.16.1).
  # Guard: a port and a path are no password, `@` in a query or not.
  local v c
  v=$(python3 -I -c 'import random; r = random.Random(47); a = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"; p = lambda n: "".join(r.choice(a) for _ in range(n)); print(p(6) + "$&'"'"'(" + p(6) + "),;" + p(2) + "7")')
  c=$(python3 -I -c 'import random; r = random.Random(67); a = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"; p = lambda n: "".join(r.choice(a) for _ in range(n)); print(p(9) + ":" + p(8) + "7")')
  printf '%s\n' "DATABASE_URL=postgres://app:$v@db:5432/app" "amqp://o'brien,ops:$v@mq" "redis://app:$c@cache" "http://host:8080/x?u=a@b" > u.txt
  git add u.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "${#v}" "${#c}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
n, nc = int(sys.argv[2]), int(sys.argv[3])
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
assert got == [(1, "credential:url-password", "postgres://[redacted, %d chars]" % n),
               (2, "credential:url-password", "amqp://[redacted, %d chars]" % n),
               (3, "credential:url-password", "redis://[redacted, %d chars]" % nc)], got
PY
  assert_not_contains "${v:0:6}" "$LC_OUT"
  assert_not_contains "${c:0:6}" "$LC_OUT"
}

t_kv_dotted_token_is_no_name() {
  # A dotted name is weak (settings.SECRET_KEY; the weak-values test is its
  # guard), but a part of 16 or more mixing upper case, lower case and
  # digits that splits into no words is a token's — a Vault `s.` token, a
  # Discord bot token — and such a value was set aside as a name, exit 0
  # (v0.16.0). Guard: a camel-case part with digits is still a name's.
  local a b
  a=$(python3 -I -c 'import random; r = random.Random(53); x = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"; p = lambda n: "".join(r.choice(x) for _ in range(n)); print("s." + p(22) + "7q")')
  b=$(python3 -I -c 'import random; r = random.Random(59); x = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"; p = lambda n: "".join(r.choice(x) for _ in range(n)); print(p(23) + "5." + p(5) + "8." + p(26) + "3")')
  printf '%s\n' "export VAULT_TOKEN=$a" "bot_token = '$b'" '"privateKey": privData.base64EncodedString()' > d.txt
  git add d.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "${#a}" "${#b}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
na, nb = int(sys.argv[2]), int(sys.argv[3])
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
assert got == [(1, "credential:generic-secret", "TOKEN[redacted, %d chars]" % na),
               (2, "credential:generic-secret", "token[redacted, %d chars]" % nb)], got
assert doc["credentials"]["weak"] == 1, doc["credentials"]
PY
}

t_kv_http_auth_rules() {
  # Stage C, HTTP authentication (v0.17.0): an Authorization header's Basic
  # credentials (judged by the password they encode, or by the user when the
  # password is empty), its Bearer or `token` credential, curl's
  # `-u user:password`, and an XML setting `<add key="…Password" value="…">`
  # — each in the syntaxes that write it, printed as its scheme, flag or key
  # name and the value's length. Weak values are counted, and a template's
  # value (`$TOKEN`, `"deploy:$DEPLOY_PASSWORD"`, `<token>`) and `docker run
  # -u 1000:1000` are no match at all.
  local vt="$PWD/.git/kv.tsv" v
  python3 -I - "$vt" <<'PY'
import base64, random, sys
r = random.Random(61)
an = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"
AZ = "Authori" "zation"
def val(n):
    return "".join(r.choice(an) for _ in range(n - 2)) + str(r.randint(2, 9)) + "q"
def basic(u, p):
    return base64.b64encode((u + ":" + p).encode()).decode()
rows = []
for fmt, user, n in ((AZ + ": Basic %s", "svc", 14),
                     ('curl -H "' + AZ + ': Basic %s" https://api.invalid/', "svc", 10),
                     ("proxy_set_header " + AZ + ' "Basic %s";', None, 20)):
    p = val(n)
    b = basic(p, "") if user is None else basic(user, p)
    rows.append(("http-basic-auth", fmt % b, b, "Basic[redacted, %d chars]" % len(b)))
for fmt, scheme, n in (('  "' + AZ + '": "Bearer %s",', "Bearer", 30),
                       ('req.Header.Set("' + AZ + '", "Bearer %s")', "Bearer", 24),
                       ("headers = {'" + AZ + "': 'token %s'}", "token", 38),
                       ("'Proxy-" + AZ + "' => 'bearer %s'", "bearer", 20)):
    v = val(n)
    rows.append(("http-bearer-token", fmt % v, v, "%s[redacted, %d chars]" % (scheme, n)))
for fmt, flag, n in (("curl -u admin:%s https://api.invalid/", "-u", 12),
                     ('curl -s --user "deploy:%s" https://x.invalid/', "--user", 16),
                     ("curl -fsS -uci:%s https://x.invalid/", "-u", 9)):
    v = val(n)
    rows.append(("curl-user-password", fmt % v, v, "%s[redacted, %d chars]" % (flag, n)))
for fmt, key, n in (('<add key="ClearText' 'Password" value="%s" />', "ClearTextPassword", 18),
                    ("<add key='DbPassword' value='%s'/>", "DbPassword", 14)):
    v = val(n)
    rows.append(("xml-key-value", fmt % v, v, "%s[redacted, %d chars]" % (key, n)))
weak = [
    AZ + ": Basic " + basic("user", "password"),
    AZ + ": Basic " + basic("Aladdin", "open sesame"),
    AZ + ": Bearer YOUR_ACCESS_TOKEN_HERE",
    "curl -u admin:changeme123 https://x.invalid",
    '<add key="ClearText' 'Password" value="%NUGET_PASSWORD%" />',
]
none = [AZ + ": Bearer $TOKEN", 'curl -u "deploy:$DEPLOY_PASSWORD" https://x.invalid',
        "docker run -u 1000:1000 img", AZ + ": Bearer <token>"]
with open(sys.argv[1], "w") as f:
    for row in rows:
        f.write("\t".join(row) + "\n")
with open(sys.argv[1] + ".weak", "w") as f:
    f.write("\n".join(weak + none) + "\n")
PY
  { cut -f2 "$vt"; cat "$vt.weak"; } > h.txt
  git add h.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$vt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
want = sorted((n + 1, "credential:" + cid, shown) for n, (cid, _, _, shown) in enumerate(rows))
assert got == want, (got, want)
# Five weak values, and the two XML lines' key names, which generic-key
# reads as `key="…"` (v0.18.0).
assert doc["credentials"]["weak"] == 7, doc["credentials"]
PY
  assert_exit 1 "$BIN"
  while IFS=$'\t' read -r _ _ v _; do
    assert_not_contains "$v" "$LC_OUT"
    assert_not_contains "$v" "$LC_ERR"
  done < "$vt"
}

t_kv_generic_key_names() {
  # gap 1 (v0.18.0): generic-key finds a secret under the weaker names —
  # `key`, `auth`, `access`, `creds`, `api` — judged like generic-secret,
  # and a value of two or more parts that are each a word, a number or a
  # letter and a number (a slug, a path, a cache key, a file name) is weak.
  # It yields to generic-secret (`API_KEY=` is reported once, as that rule)
  # and to a fixed-format rule. Guard: generic-secret still reports the
  # word-made password generic-key sets aside.
  local vt="$PWD/.git/kv.tsv"
  python3 -I - "$vt" <<'PY'
import base64, random, sys
r = random.Random(67)
an = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"
def val(n):
    return "".join(r.choice(an) for _ in range(n - 2)) + str(r.randint(2, 9)) + "q"
rows = []
for fmt, kw, n in (("SIGNING_KEY=%s", "KEY", 32), ('  "key": "%s",', "key", 24), ("auth = '%s'", "auth", 20),
                   ('ACCESS="%s"', "ACCESS", 28), ("creds: %s", "creds", 18), ("api: %s", "api", 30)):
    v = val(n)
    rows.append(("generic-key", fmt % v, "%s[redacted, %d chars]" % (kw, n), v))
b = base64.b64encode(bytes(r.getrandbits(8) for _ in range(32))).decode()
rows.append(("generic-key", "    MFA_ENCRYPTION_KEY=%s \\" % b, "KEY[redacted, %d chars]" % len(b), b))
v = val(26)
rows.append(("generic-secret", "API_KEY=%s" % v, "API_KEY[redacted, 26 chars]", v))
rows.append(("generic-secret", 'password = "Winter-2024-db"', "password[redacted, 14 chars]", "Winter-2024-db"))
rows.append(("generic-key", "KEY=Kestrel7Harbor9Lantern", "KEY[redacted, 22 chars]", "Kestrel7Harbor9Lantern"))
weak = ["key: cache-v1-node-modules-x86_64", "SSH_KEY=~/.ssh/id_ed25519", "- Authority: `02-module-architecture.md` (core)",
        '  "identity_key": "rumba42abc-26-tasks",', "\tr2Key: 'tenants/t1/media/photo',", 'KEY = "Winter-2024-db"',
        "SSH_AUTH_SOCK=/run/user/1000/gnupg/S.gpg-agent.ssh"]
with open(sys.argv[1], "w") as f:
    for row in rows:
        f.write("\t".join(row) + "\n")
with open(sys.argv[1] + ".weak", "w") as f:
    f.write("\n".join(weak) + "\n")
PY
  { cut -f2 "$vt"; cat "$vt.weak"; } > g.txt
  git add g.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$vt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
want = sorted((n + 1, "credential:" + cid, shown) for n, (cid, _, shown, _) in enumerate(rows))
assert got == want, (got, want)
assert doc["credentials"]["weak"] == 7, doc["credentials"]
PY
  assert_exit 1 "$BIN"
  while IFS=$'\t' read -r _ _ _ v; do
    assert_not_contains "$v" "$LC_OUT"
  done < "$vt"
}

t_credential_issuer_sourced_v019() {
  # gap 4 (v0.19.0). Sidekiq's gem-server credentials in its environment
  # variable and its bundle config (`user:password`, the password judged at
  # 2 bits a character, the issuer's own `username:password` weak); its URL
  # form stays url-password's alone. An Airtable token under a secret's name
  # (`pat<id>.<64 hex>`) was a dotted name to v0.18.0, set aside whenever
  # its id held no digit; a part of 32 or more hex digits is a token's.
  local vt="$PWD/.git/g4.tsv"
  python3 -I - "$vt" <<'PY'
import random, sys
r = random.Random(71)
hx = lambda n: "".join(r.choice("0123456789abcdef") for _ in range(n))
a, b, c, d = hx(7) + "c", hx(6) + "b4", hx(7) + "e", hx(6) + "f9"
# 13 letters: since v0.29.0 airtable-token takes the 14-letter form, and
# this line pins kv_weak's judgement of a dotted token, not that rule.
air = "pat" + "".join(r.choice("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz") for _ in range(13)) + ".a" + hx(63)
rows = [
    ("sidekiq-credentials", "BUNDLE_GEMS__CONTRIB" "SYS__COM=%s:%s" % (a, b), "CONTRIBSYS[redacted, 8 chars]", b),
    ("sidekiq-credentials", "bundle config --local enterprise.contrib" "sys.com %s:%s" % (c, d), "contribsys[redacted, 8 chars]", d),
    ("url-password", "source \"https://%s:%s@gems.contrib" "sys.com/\"" % (c, d), "https://[redacted, 8 chars]", d),
    ("generic-secret", "AIRTABLE_TOKEN=" + air, "TOKEN[redacted, %d chars]" % len(air), air),
]
with open(sys.argv[1], "w") as f:
    for row in rows:
        f.write("\t".join(row) + "\n")
PY
  { cut -f2 "$vt"; echo 'bundle config gems.contrib''sys.com username:password'; } > s.txt
  git add s.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$vt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
want = sorted((n + 1, "credential:" + cid, shown) for n, (cid, _, shown, _) in enumerate(rows))
assert got == want, (got, want)
assert doc["credentials"]["weak"] == 1, doc["credentials"]
PY
  while IFS=$'\t' read -r _ _ _ v; do assert_not_contains "$v" "$LC_OUT"; done < "$vt"
}

t_credential_issuer_sourced_near_misses_are_clean() {
  # Guard (passes on v0.18.0, which has none of these rules): the v0.19.0
  # prefixes and shapes stop short of their lengths and separators — a
  # prefix with a short run, a digest that is no OpenShift token, `pat.`
  # with short parts, a Flutterwave body with no `-X`, an id joined by `|`
  # to a name, a Grafana prefix with little after it, `LTAI` inside base64,
  # and (huggingface-token's edge, v0.19.0) `hf_` inside base64url.
  printf '%s\n' \
    'shippo_test_key = load()' 'sm_pat_short' 'tk-us-east-1' 'duffel_test_mode' \
    'image: app@sha256:4f2a9c1e7b3d5f6a8c0e2b4d6f8a0c2e' 'x = sha256~short' \
    'pat.match(text).group(1)' 'pattern.compile.matches.all' \
    'FLWSECK-3f2a9c1e7b3d5f6a8c0e2b4d6f8a0c2e' 'p8e-short' 'ico-small' 'pnu_test' \
    'LTAI12345678' '| 1700000000000 | release-candidate |' '20261119123456|nightly' \
    'eyJrIjoiYWJj' 'bedrock-api-key-test' \
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkLTAIk3a4RtFQKBAAAAAElFTkSuQmCC' \
    "u=Qx7-dQIh""f_$(printf 'Kw%.0s' {1..17})" > n.txt
  git add n.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 0 "$BIN"
}

t_kv_service_names() {
  # gap 2 (v0.20.0): service-secret finds a secret under a service's name
  # alone (`HEROKU=`, `"datadog":`), at 3 bits a character, so a 32-hex key
  # generic-secret's 3.5 bits sets aside a fifth of the time is found. It
  # yields to every other rule; a name holding an identifier's word
  # (`_ACCOUNT_ID`, `_SHA`, `PriceId`, `_TENANT`, `_APP`) makes the value
  # weak, as do word parts (`orderEvents-v2-handler`); and the service's
  # name must start a name: `xheroku` is no match. The `pagerduty` value is
  # hex drawn until it falls between 3 and 3.5 bits a character.
  local vt="$PWD/.git/svc.tsv"
  python3 -I - "$vt" <<'PY'
import collections, math, random, sys, uuid
r = random.Random(73)
def H(s):
    c = collections.Counter(s)
    return -sum(k / len(s) * math.log2(k / len(s)) for k in c.values())
an = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"
hx = lambda n: "".join(r.choice("0123456789abcdef") for _ in range(n - 2)) + "7c"
def val(n):
    return "".join(r.choice(an) for _ in range(n - 2)) + str(r.randint(2, 9)) + "q"
u = str(uuid.UUID(int=r.getrandbits(128), version=4))
rows = [("service-secret", "HEROKU=" + u, "HEROKU[redacted, 36 chars]", u)]
v = hx(32); rows.append(("service-secret", '  "datadog": "%s",' % v, "datadog[redacted, 32 chars]", v))
v = val(28); rows.append(("service-secret", "mailgun_signing = '%s'" % v, "mailgun[redacted, 28 chars]", v))
v = val(34); rows.append(("service-secret", "export TWILIO_PRIMARY=%s" % v, "TWILIO[redacted, 34 chars]", v))
v = val(26); rows.append(("generic-secret", "DATADOG_API_KEY=%s" % v, "API_KEY[redacted, 26 chars]", v))
v = val(30); rows.append(("generic-key", "SENTRY_KEY=%s" % v, "KEY[redacted, 30 chars]", v))
v = next(w for w in (hx(32) for _ in range(5000)) if 3.05 < H(w) < 3.4)
rows.append(("service-secret", '  "pagerduty": "%s",' % v, "pagerduty[redacted, 32 chars]", v))
weak = ["CLOUDFLARE_ACCOUNT_ID=" + hx(32), "GITHUB_SHA=" + hx(40), "stripePriceId: 'price_" + val(24) + "'",
        "HEROKU_APP=shop-api-prod-2024", "AZURE_TENANT=" + str(uuid.UUID(int=r.getrandbits(128), version=4)),
        "SENDGRID_WEBHOOK=orderEvents-v2-handler"]
none = ["xheroku = '" + val(30) + "'"]
with open(sys.argv[1], "w") as f:
    for row in rows:
        f.write("\t".join(row) + "\n")
with open(sys.argv[1] + ".weak", "w") as f:
    f.write("\n".join(weak + none) + "\n")
PY
  { cut -f2 "$vt"; cat "$vt.weak"; } > svc.txt
  git add svc.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" "$vt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
got = sorted((h["line"], h["pattern"], h["text"]) for h in doc["hits"])
want = sorted((n + 1, "credential:" + cid, shown) for n, (cid, _, shown, _) in enumerate(rows))
assert got == want, (got, want)
assert doc["credentials"]["weak"] == 6, doc["credentials"]
PY
  while IFS=$'\t' read -r _ _ _ v; do assert_not_contains "$v" "$LC_OUT"; done < "$vt"
}

t_label_pattern_prints_its_name() {
  # Stage D (v0.21.0): `label <name> <regex>` is a pattern whose hits, JSON
  # and --list-patterns line print the name, never the regex — the
  # inventory a CI log should not carry. Refused: no name, a name that is no
  # word, no regex, a name given twice, a name that is another pattern's
  # text, an escape git reads as a letter, a regex that matches the empty
  # string or ends in whitespace — a label's regex is checked as a pattern's.
  seed a.txt "host is MYHOST.example here"
  commit init
  rc_file 'label internal-host MYHOST\.example'
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [internal-host] host is MYHOST.example here" "$LC_OUT"
  assert_exit 1 "$BIN" --json
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert [h["pattern"] for h in d["hits"]] == ["internal-host"], d["hits"]' "$LC_OUT"
  assert_exit 0 "$BIN" --list-patterns
  assert_contains "internal-host" "$LC_OUT"
  assert_not_contains "MYHOST" "$LC_OUT"
  rc_file 'label'
  assert_exit 2 "$BIN"
  rc_file 'label 9host MYHOST'
  assert_exit 2 "$BIN"
  assert_contains "label names a pattern by a word" "$LC_ERR"
  rc_file 'label internal-host'
  assert_exit 2 "$BIN"
  assert_contains "needs a regex after its name" "$LC_ERR"
  rc_file 'label h MYHOST' 'label h OTHER'
  assert_exit 2 "$BIN"
  assert_contains "label h is named twice" "$LC_ERR"
  rc_file 'pattern hostx' 'label hostx MYHOST'
  assert_exit 2 "$BIN"
  assert_contains "label hostx is also a pattern's text" "$LC_ERR"
  rc_file 'label h SECRET-\d+'
  assert_exit 2 "$BIN"
  rc_file 'label h MYHOST|'
  assert_exit 2 "$BIN"
  assert_contains "matches the empty string" "$LC_ERR"
  rc_file 'label h MYHOST '
  assert_exit 2 "$BIN"
  assert_contains "ends in whitespace" "$LC_ERR"
}

t_config_from_environment() {
  # Stage D (v0.21.0): LEAKCHECK_RC holds config lines, read after every
  # config file, its errors quoted as LEAKCHECK_RC:<line>; LEAKCHECK_CONFIG
  # names a config as --config does, and --config wins; a named config that
  # is missing is an error, as --config's is.
  seed a.txt "host is MYHOST.example here"
  commit init
  LEAKCHECK_RC='pattern MYHOST' assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [MYHOST] host is MYHOST.example here" "$LC_OUT"
  LEAKCHECK_RC=$'no-defaults\npattern SECRET-\\d' assert_exit 2 "$BIN"
  assert_contains "LEAKCHECK_RC:2:" "$LC_ERR"
  printf 'pattern MYHOST\n' > .git/env.rc
  printf 'pattern NOT-HERE\n' > .git/other.rc
  LEAKCHECK_CONFIG="$PWD/.git/env.rc" assert_exit 1 "$BIN"
  assert_contains "[MYHOST]" "$LC_OUT"
  LEAKCHECK_CONFIG="$PWD/.git/env.rc" assert_exit 0 "$BIN" --config "$PWD/.git/other.rc"
  LEAKCHECK_CONFIG="$PWD/.git/missing.rc" assert_exit 2 "$BIN"
  assert_contains "config not found" "$LC_ERR"
}

t_redact_hides_every_hit_text() {
  # Stage D (v0.21.0): --redact prints no hit's text — its length instead —
  # and hides a tell found in a name wherever a path prints, an allow rule's
  # text in the JSON, and an unlabelled config pattern's regex, which prints
  # as its line in --list-patterns (`pattern:9`, after the eight defaults);
  # a credential hit prints as it always does.
  local gh
  gh=$(cred github-token)
  seed a.txt "host is MYHOST.example here"
  seed "MYHOST.example/b.txt" "x"
  seed c.txt "token: $gh"
  seed d.txt "MYHOST.example is excused here"
  rc_file 'pattern MYHOST' 'allow ^d\.txt:1:MYHOST'
  commit init
  assert_exit 1 "$BIN" --redact
  assert_not_contains "MYHOST" "$LC_OUT"
  assert_not_contains "MYHOST" "$LC_ERR"
  assert_contains "a.txt:1: [pattern:9] [redacted, 27 chars]" "$LC_OUT"
  assert_contains "[redacted, 6 chars].example/b.txt:0: [pattern:9] [redacted, 20 chars]" "$LC_OUT"
  assert_contains "c.txt:1: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_exit 1 "$BIN" --redact --json
  assert_not_contains "MYHOST" "$LC_OUT"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["allowed"] == [{"rule": "[redacted, 16 chars]", "count": 1}], d["allowed"]' "$LC_OUT"
  # With no allow rule and no credential hit, --redact alone gathers the
  # tells a name holds.
  git rm -q c.txt d.txt
  rc_file 'pattern MYHOST'
  commit alone
  assert_exit 1 "$BIN" --redact
  assert_not_contains "MYHOST" "$LC_OUT"
  assert_contains "[redacted, 6 chars].example/b.txt:0: [pattern:9] [redacted, 20 chars]" "$LC_OUT"
}

t_rule_runs_only_named_rules() {
  # Stage D (v0.21.0): --rule runs only the named rules, each a credential
  # rule this config runs or a config label; the defaults and every other
  # pattern are off, the scope line counts the rules that ran, and the JSON
  # lists them last. A name that is neither is refused.
  local gh st
  gh=$(cred github-token); st=$(cred stripe-key)
  seed a.txt "token: $gh"
  seed b.txt "key: $st"
  seed c.txt "see /home/alice/notes and MYHOST"
  rc_file 'label h MYHOST'
  commit init
  assert_exit 1 "$BIN" --rule credential:github-token
  assert_contains "a.txt:1: [credential:github-token]" "$LC_OUT"
  assert_not_contains "b.txt" "$LC_OUT"
  assert_not_contains "c.txt" "$LC_OUT"
  assert_contains "; only 1 rules run (--rule)" "$LC_ERR"
  assert_exit 1 "$BIN" --rule h --rule credential:stripe-key --json
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sorted(h["file"] for h in d["hits"]) == ["b.txt", "c.txt"] and d["rules_run"] == ["h", "credential:stripe-key"] and list(d)[-1] == "rules_run", d' "$LC_OUT"
  assert_exit 0 "$BIN" --list-rules --rule credential:github-token
  assert_contains "credential:github-token	on" "$LC_OUT"
  assert_contains "credential:stripe-key	off" "$LC_OUT"
  assert_exit 2 "$BIN" --rule credential:no-such-rule
  assert_contains "names no credential rule this config runs and no label" "$LC_ERR"
  assert_exit 2 "$BIN" --rule '/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/'
}

t_integrations_run_leakcheck() {
  # Stage F (v0.23.0): the pre-commit manifest runs bin/leakcheck over the
  # whole repository (no file names, every commit, whatever it touches), and
  # the GitHub Action runs its own checkout's bin/leakcheck in the caller's
  # workspace, the input's words as arguments and a glob character literal.
  local m="$REPO_DIR/.pre-commit-hooks.yaml" a="$REPO_DIR/action.yml" ap="$PWD/.git/action"
  python3 - "$m" <<'PY'
import sys
hook = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.lstrip().startswith("#")]
for want in ("- id: leakcheck", "entry: bin/leakcheck", "language: script", "pass_filenames: false", "always_run: true"):
    assert want in hook, (want, hook)
PY
  [[ -x "$REPO_DIR/bin/leakcheck" ]]
  # The action's step, as GitHub runs `shell: bash`.
  python3 - "$a" > .git/run.sh <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
i = lines.index("      run: |")
out = []
for l in lines[i + 1:]:
    if l.startswith("        ") or not l.strip():
        out.append(l[8:])
    else:
        break
print("\n".join(out).strip())
PY
  [[ "$(<"$a")" == *'LEAKCHECK_ARGS: ${{ inputs.args }}'* ]]
  mkdir -p "$ap/bin"
  ln -s "$BIN" "$ap/bin/leakcheck"
  seed a.txt "see /home/alice/x"
  commit init
  GITHUB_ACTION_PATH="$ap" LEAKCHECK_ARGS="--json --strict" \
    assert_exit 1 bash --noprofile --norc -eo pipefail .git/run.sh
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["count"] == 1, d' "$LC_OUT"
  # Every line of an `args: |` block (v0.29.3: read -a took the first).
  GITHUB_ACTION_PATH="$ap" LEAKCHECK_ARGS=$'--strict\n--json' \
    assert_exit 1 bash --noprofile --norc -eo pipefail .git/run.sh
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["count"] == 1, d' "$LC_OUT"
  GITHUB_ACTION_PATH="$ap" LEAKCHECK_ARGS="*" \
    assert_exit 2 bash --noprofile --norc -eo pipefail .git/run.sh
  assert_contains "unexpected arg: *" "$LC_ERR"
  seed a.txt "clean"
  commit clean
  GITHUB_ACTION_PATH="$ap" LEAKCHECK_ARGS="" \
    assert_exit 0 bash --noprofile --norc -eo pipefail .git/run.sh
}

t_format_sarif() {
  # Stage F (v0.24.0): --format sarif is SARIF 2.1.0 — a rule per pattern
  # that hit, a result per hit (as many as --json counts), a name hit with no
  # region and its path percent-encoded, a credential masked, a commit's
  # message a logical location carrying the commit; --redact holds.
  local gh
  gh=$(cred github-token)
  seed a.txt "see /home/alice/notes"
  seed "my notes/MYHOST.txt" "x"
  seed c.txt "token: $gh"
  rc_file 'pattern MYHOST'
  commit "built on MYHOST"
  assert_exit 1 "$BIN" --format sarif
  cp "$LC_OUT" .git/sarif.json
  assert_exit 1 "$BIN" --json
  python3 - .git/sarif.json "$LC_OUT" "$gh" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); j = json.load(open(sys.argv[2]))
assert s["version"] == "2.1.0" and len(s["runs"]) == 1, s
run = s["runs"][0]
rules = [r["id"] for r in run["tool"]["driver"]["rules"]]
assert sorted(rules) == sorted({h["pattern"] for h in j["hits"]}), rules
res = run["results"]
assert len(res) == j["count"] == 3, res
by = {r["ruleId"]: r for r in res}
assert all(rules[r["ruleIndex"]] == r["ruleId"] for r in res), res
name = by["MYHOST"]["locations"][0]["physicalLocation"]
assert name == {"artifactLocation": {"uri": "my%20notes/MYHOST.txt"}}, name
home = [r for r in res if r["ruleId"].startswith("/home/")][0]["locations"][0]["physicalLocation"]
assert home == {"artifactLocation": {"uri": "a.txt"}, "region": {"startLine": 1}}, home
assert sys.argv[3] not in json.dumps(s), "key printed"
assert "[credential:github-token] ghp_[redacted, 40 chars]" in by["credential:github-token"]["message"]["text"], by
PY
  assert_exit 1 "$BIN" --format sarif --redact
  assert_not_contains "MYHOST" "$LC_OUT"
  assert_exit 1 "$BIN" --format sarif --history
  python3 - "$LC_OUT" "$(sha_of)" <<'PY'
import json, sys
res = json.load(open(sys.argv[1]))["runs"][0]["results"]
msg = [r for r in res if r["locations"][0].get("logicalLocations")]
assert [(r["locations"], r["properties"]) for r in msg] == [([{"logicalLocations": [{"fullyQualifiedName": "(message)"}]}], {"source": "history", "commit": sys.argv[2]})], msg
PY
}

t_format_csv() {
  # Stage F (v0.24.0): --format csv is a header and a row per hit, RFC 4180
  # quoted (a comma, a quote, a newline in a name survive); a field a
  # spreadsheet would run as a formula is led by '. A clean scan is the
  # header alone, exit 0.
  seed a.txt '=HYPERLINK("http://MYHOST/x", "a, b")'
  seed "$(printf 'odd\nMYHOST.txt')" "x"
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 1 "$BIN" --format csv
  python3 - "$LC_OUT" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], newline="")))
assert rows[0] == ["file", "line", "pattern", "text", "source", "commit"], rows
body = sorted(rows[1:])
assert body == sorted([
    ["a.txt", "1", "MYHOST", "'=HYPERLINK(\"http://MYHOST/x\", \"a, b\")", "both", ""],
    ["odd\nMYHOST.txt", "0", "MYHOST", "odd\nMYHOST.txt", "index", ""],
]), body
PY
  git rm -q a.txt "$(printf 'odd\nMYHOST.txt')"
  commit clean
  assert_exit 0 "$BIN" --format csv
  [[ "$(cat "$LC_OUT")" == "file,line,pattern,text,source,commit" ]]
  assert_contains "leakcheck: clean" "$LC_ERR"
}

t_format_junit() {
  # Stage F (v0.24.0): --format junit is a failed test case per hit, every
  # character XML-escaped (`<`, `&`, quotes); a clean scan is one passing
  # case, `scan`, never an empty suite.
  seed a.txt "<a title=\"x\">MYHOST & co's</a>"
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 1 "$BIN" --format junit
  python3 - "$LC_OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.tag == "testsuites" and root.get("failures") == "1" and root.get("tests") == "1", root.attrib
(case,) = root.iter("testcase")
f = case.find("failure")
assert case.get("name") == "a.txt:1" and f.get("type") == "MYHOST", (case.attrib, f.attrib)
assert f.text == "a.txt:1: [MYHOST] <a title=\"x\">MYHOST & co's</a>", f.text
PY
  seed a.txt "clean"
  commit clean
  assert_exit 0 "$BIN" --format junit
  python3 - "$LC_OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.get("failures") == "0" and [c.get("name") for c in root.iter("testcase")] == ["scan"], ET.tostring(root)
PY
}

t_format_flag() {
  # Stage F (v0.24.0): --format json is --json, byte for byte, and --format
  # text the default; an unknown format, two formats, or --json with
  # another format is exit 2.
  seed a.txt "see /home/alice/x"
  commit init
  assert_exit 1 "$BIN" --json
  cp "$LC_OUT" .git/a.json
  assert_exit 1 "$BIN" --format json
  cmp -s "$LC_OUT" .git/a.json
  assert_exit 1 "$BIN"
  cp "$LC_OUT" .git/a.txt
  assert_exit 1 "$BIN" --format text
  cmp -s "$LC_OUT" .git/a.txt
  assert_exit 2 "$BIN" --format yaml
  assert_contains "unknown format: yaml" "$LC_ERR"
  assert_exit 2 "$BIN" --json --format csv
  assert_contains "--json and --format csv disagree" "$LC_ERR"
  assert_exit 2 "$BIN" --format csv --format sarif
  assert_exit 1 "$BIN" --json --format json
}

t_baseline_reports_only_new_findings() {
  # Stage F (v0.25.0): --write-baseline writes a hash per finding — path,
  # pattern, raw text, and its ordinal among identical findings, never the
  # commit, so a rebase changes nothing —
  # and --baseline reports only findings it does not hold, counted. A line
  # that moves is the same finding; a copy is new, and so is a different key
  # where an accepted one sat, though both print the same masked text. The
  # file holds no path, text or key.
  local st st2 b="$PWD/.git/base"
  st=$(cred stripe-key)
  if [[ "${st: -1}" == Q ]]; then st2="${st%?}R"; else st2="${st%?}Q"; fi
  seed a.txt "see /home/alice/notes"
  seed b.txt "key: $st"
  seed c.txt "on MYHOST"
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 1 "$BIN" --write-baseline "$b"
  assert_contains "leakcheck: 3 match(es)" "$LC_ERR"
  python3 - "$b" "$st" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
assert lines[0] == "# leakcheck baseline v1", lines
body = [l for l in lines if l and not l.startswith("#")]
assert len(body) == 3 and all(re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?:1", l) for l in body), body
text = open(sys.argv[1]).read()
for tell in ("alice", "MYHOST", "a.txt", sys.argv[2]):
    assert tell not in text, tell
PY
  assert_exit 0 "$BIN" --baseline "$b"
  assert_contains "; 3 in baseline)" "$LC_OUT"
  assert_exit 0 "$BIN" --baseline "$b" --json
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["count"] == 0 and d["baseline"] == 3 and list(d)[-1] == "baseline", d' "$LC_OUT"
  # Moved: the same finding.
  printf 'top\nsee /home/alice/notes\n' > a.txt
  git add a.txt
  assert_exit 0 "$BIN" --baseline "$b"
  # Copied: the second copy is new.
  printf 'top\nsee /home/alice/notes\nsee /home/alice/notes\n' > a.txt
  git add a.txt
  assert_exit 1 "$BIN" --baseline "$b"
  assert_contains "a.txt:3: [" "$LC_OUT"
  assert_not_contains "a.txt:2: [" "$LC_OUT"
  assert_contains "; 3 in baseline)" "$LC_ERR"
  # The accepted key is no credential this run reports.
  assert_not_contains "credential(s) among these" "$LC_ERR"
  # A different key where the accepted one sat: new, and still a credential.
  printf 'top\nsee /home/alice/notes\n' > a.txt
  git add a.txt
  seed b.txt "key: $st2"
  assert_exit 1 "$BIN" --baseline "$b"
  assert_contains "b.txt:1: [credential:stripe-key]" "$LC_OUT"
  assert_contains "leakcheck: 1 credential(s) among these" "$LC_ERR"
  # One file as both: read, then rewritten.
  assert_exit 1 "$BIN" --baseline "$b" --write-baseline "$b"
  assert_exit 0 "$BIN" --baseline "$b"
  # History: the same findings after a commit is rewritten (the second key
  # entered at `two`, which the amend replaces).
  commit two
  assert_exit 1 "$BIN" --history --write-baseline "$b"
  assert_exit 0 "$BIN" --history --baseline "$b"
  git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --amend -m two-amended
  assert_exit 0 "$BIN" --history --baseline "$b"
}

t_baseline_errors() {
  # Stage F (v0.25.0): a baseline that is missing, empty, not a leakcheck
  # baseline, or holds a line that is no fingerprint is exit 2 — reading
  # none would report every finding it was meant to hold, and reading a
  # wrong file could hold any.
  seed a.txt "see /home/alice/notes"
  commit init
  assert_exit 2 "$BIN" --baseline .git/missing
  assert_contains "baseline not found" "$LC_ERR"
  : > .git/empty
  assert_exit 2 "$BIN" --baseline .git/empty
  printf 'pattern MYHOST\n' > .git/other
  assert_exit 2 "$BIN" --baseline .git/other
  assert_contains "not a leakcheck baseline" "$LC_ERR"
  printf '# leakcheck baseline v1\nnot-a-hash\n' > .git/bad
  assert_exit 2 "$BIN" --baseline .git/bad
  assert_contains "line 2 is not a finding's fingerprint" "$LC_ERR"
  assert_exit 2 "$BIN" --write-baseline .git/no/such/dir/base
}

t_kv_code_identifiers_are_weak() {
  # v0.25.1: a value under `key` that is code, not a literal — a camel-case
  # function or variable name (`createPrivateKey(`, `privatePkcs8`), or a
  # TypeScript non-null read (`signer!.privatePkcs8`), or a function called
  # (`urlBase64ToUint8Array(`, v0.25.2) — is weak, as
  # word parts are: the fleet sweep took four such names in a test file for
  # keys. A random value still is a key, a lowercase one with digits
  # included: its runs read as words, but it has no camel case.
  seed a.ts "    const key = createPrivateKey({ key: signer!.privatePkcs8, format: 'der', type: 'pkcs8' });
    const priv = createPrivateKey({ key: privatePkcs8, format: 'der', type: 'pkcs8' });
    applicationServerKey: urlBase64ToUint8Array(vapidKey)"
  seed b.txt $'key: "Zq7Lm2Xv9Rt4Wp8Ks3Nb"\nkey: qzv7kxmb3trlw9pd'
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted((h["file"], h["line"], h["pattern"]) for h in d["hits"]) == [("b.txt", 1, "credential:generic-key"), ("b.txt", 2, "credential:generic-key")], d["hits"]
# Three hits weak: line 1 holds two matches (the call and the read), line 2
# one, line 3 a function's name (`To` is no word for KV_WORD_RE: v0.25.2).
assert d["credentials"]["weak"] == 3, d["credentials"]
PY
}

t_dir_scans_every_file() {
  # Stage E (v0.26.0): --dir scans every file under a directory that is no
  # repository — an ignored one, a symlink's target, a name, with the
  # directory's own .leakcheckrc — and writes nothing into it; a repository
  # inside it is counted, not scanned; the caller's repository and index are
  # not this scan's. --history is refused.
  local d="$PWD/.git/plain"
  seed outer.txt "see /home/alice/outer"
  commit init
  mkdir -p "$d/sub"
  printf 'see /home/alice/a\n' > "$d/a.txt"
  printf '*.log\n' > "$d/.gitignore"
  printf 'ignored /home/alice/i\n' > "$d/ign.log"
  ln -s /home/alice/target "$d/link"
  printf 'x\n' > "$d/sub/notes-MYHOST.txt"
  printf 'pattern MYHOST\n' > "$d/.leakcheckrc"
  git init -q "$d/nested"
  printf 'nested /home/alice/n\n' > "$d/nested/n.txt"
  GIT_INDEX_FILE="$PWD/.git/index" assert_exit 1 "$BIN" --dir "$d"
  assert_contains "a.txt:1: [" "$LC_OUT"
  assert_contains "ign.log:1: [" "$LC_OUT"
  assert_contains "link:0: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] -> /home/alice/target" "$LC_OUT"
  assert_contains "sub/notes-MYHOST.txt:0: [MYHOST] sub/notes-MYHOST.txt" "$LC_OUT"
  assert_not_contains "outer.txt" "$LC_OUT"
  assert_not_contains "nested" "$LC_OUT"
  assert_contains "leakcheck: scanned 6 files (every file under the directory, ignored ones included; 0 binary skipped, 1 submodules not scanned, 1 skipped by config" "$LC_ERR"
  [[ ! -e "$d/.git" ]]
  assert_exit 1 "$BIN" --dir "$d" --json
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["target"] == "dir" and d["count"] == 4, d' "$LC_OUT"
  # The caller's own repository still scans as before.
  assert_exit 1 "$BIN"
  assert_contains "outer.txt:1: [" "$LC_OUT"
  assert_exit 2 "$BIN" --dir "$d" --history
  assert_contains "--history needs a git repository" "$LC_ERR"
  assert_exit 2 "$BIN" --dir "$PWD/.git/missing"
  assert_contains "not a directory" "$LC_ERR"
  rm -rf "$d"
}

t_stdin_scans_input() {
  # Stage E (v0.26.0): --stdin scans standard input as one file, `stdin`,
  # bytes as they are (a NUL makes it binary, counted), with the config
  # --config names; --stdin with --dir is refused.
  printf 'see /home/alice/x\nbuilt on MYHOST\n' > .git/in.txt
  printf 'pattern MYHOST\n' > .git/rc
  assert_exit 1 "$BIN" --stdin < .git/in.txt
  assert_contains "stdin:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] see /home/alice/x" "$LC_OUT"
  assert_not_contains "MYHOST" "$LC_OUT"
  assert_contains "leakcheck: scanned 1 files (standard input;" "$LC_ERR"
  assert_exit 1 "$BIN" --stdin --config "$PWD/.git/rc" --json < .git/in.txt
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["target"] == "stdin" and sorted(h["pattern"] for h in d["hits"])[0] == "/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/" and d["count"] == 2, d' "$LC_OUT"
  printf 'a\0b /home/alice/x\n' > .git/bin.txt
  assert_exit 0 "$BIN" --stdin < .git/bin.txt
  assert_contains "1 binary skipped" "$LC_OUT"
  assert_exit 1 "$BIN" --stdin --strict < .git/bin.txt
  printf 'clean\n' > .git/clean.txt
  assert_exit 0 "$BIN" --stdin < .git/clean.txt
  assert_contains "leakcheck: clean — 0 matches across 1 files (standard input;" "$LC_OUT"
  assert_exit 2 "$BIN" --stdin --dir "$PWD/.git" < .git/clean.txt
}

t_decode_finds_encoded_values() {
  # Stage E (v0.27.0): --decode reads each tracked line again with each
  # encoded value decoded in place, where it decodes to text — base64 (the
  # URL-safe alphabet too, unpadded), hex, percent-encoding — so a keyword
  # beside the value still counts; a hit names its encoding, a key stays
  # masked, an image's base64 is not decoded, and the values decoded are
  # counted. A config pattern reaches the pass through pat_args (`(?i)`), and
  # the config's own lines are decoded for the credential rules alone, as the
  # tree passes read it. Without the flag nothing changes.
  local gh b64 tok hex pw hostb cfgk cfgp
  gh=$(cred github-token)
  b64=$(python3 -c 'import base64; print(base64.b64encode(b"see /home/alice/b64\n").decode())')
  # URL-safe and unpadded: `~~~` encodes to `fn5-`, so a - is in it.
  tok=$(python3 -c 'import base64,sys; v=base64.urlsafe_b64encode(("~~~ token: " + sys.argv[1]).encode()).decode().rstrip("="); assert "-" in v; print(v)' "$gh")
  hex=$(python3 -c 'print(b"/home/alice/hexvalue".hex())')
  pw=$(python3 -c 'import base64; print(base64.b64encode(b"Xq7vR2mPz9Lw4sKd8Tn3bQy5").decode())')
  hostb=$(python3 -c 'import base64; print(base64.b64encode(b"built on MyHost today").decode())')
  cfgk=$(python3 -c 'import base64,sys; print(base64.b64encode(("token = " + sys.argv[1]).encode()).decode())' "$gh")
  cfgp=$(python3 -c 'import base64; print(base64.b64encode(b"see /home/alice/config").decode())')
  seed a.txt "data: $b64"
  seed b.txt "blob = $tok"
  seed c.txt "cfg: $hex"
  seed d.txt "url = https://x/%2Fhome%2Falice%2Fpct"
  seed e.yaml "  password: $pw"
  seed f.txt "img: iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  seed g.txt "note: $hostb"
  rc_file "pattern (?i)myhost
# $cfgk
# $cfgp"
  commit init
  # Without --decode only the raw base64 under `password:` is a finding.
  assert_exit 1 "$BIN"
  assert_contains "leakcheck: 1 match(es)" "$LC_ERR"
  assert_exit 1 "$BIN" --decode
  assert_contains "a.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] data: see /home/alice/b64 (decoded base64)" "$LC_OUT"
  assert_contains "b.txt:1: [credential:github-token] $(masked "$gh") (decoded base64)" "$LC_OUT"
  assert_contains "c.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] cfg: /home/alice/hexvalue (decoded hex)" "$LC_OUT"
  assert_contains "d.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] url = https://x//home/alice/pct (decoded percent)" "$LC_OUT"
  assert_contains "e.yaml:1: [credential:generic-secret] password[redacted, 24 chars] (decoded base64)" "$LC_OUT"
  assert_contains "g.txt:1: [(?i)myhost] note: built on MyHost today (decoded base64)" "$LC_OUT"
  assert_contains ".leakcheckrc:2: [credential:github-token] $(masked "$gh") (decoded base64)" "$LC_OUT"
  assert_not_contains "alice/config" "$LC_OUT"
  assert_not_contains "f.txt" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
  assert_contains "leakcheck: 8 match(es)" "$LC_ERR"
  assert_contains "; 8 encoded values decoded (tracked content, one level)" "$LC_ERR"
  # Standard input decodes too, and the summary names what it read.
  printf 'cfg: %s\n' "$b64" > .git/dec.txt
  assert_exit 1 "$BIN" --stdin --decode < .git/dec.txt
  assert_contains "stdin:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] cfg: see /home/alice/b64 (decoded base64)" "$LC_OUT"
  assert_contains "; 1 encoded values decoded (standard input, one level)" "$LC_ERR"
  assert_exit 1 "$BIN" --decode --json
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
src = sorted((h["file"], h["source"]) for h in d["hits"])
assert src == [(".leakcheckrc", "decoded-base64"), ("a.txt", "decoded-base64"), ("b.txt", "decoded-base64"), ("c.txt", "decoded-hex"), ("d.txt", "decoded-percent"), ("e.yaml", "both"), ("e.yaml", "decoded-base64"), ("g.txt", "decoded-base64")], src
' "$LC_OUT"
}

t_archives_read_what_they_publish() {
  # /qaa (v0.29.1), each case a member or a byte v0.29.0 left unread or
  # printed: a key in a member's name printed whole in the hit's text, a
  # .p12 member past the path rules, an entry past the end record's count,
  # an unknown tar type's data, a member holding more than its stated size,
  # metadata (zip and gzip comments, a tar owner, pax records, a .tar.gz's
  # own name), and --redact leaving a member name's tell in its path.
  local gh H='[/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/]'
  gh=$(cred github-token)
  python3 - "$gh" <<'PY'
import gzip, io, struct, sys, tarfile, zipfile, zlib
gh = sys.argv[1]
def tbytes(members, fmt=tarfile.USTAR_FORMAT, **kw):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w", format=fmt, **kw) as t:
        for ti, data in members:
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
    return b.getvalue()
def zbytes(entries, comment=b""):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.comment = comment
        for zi, data in entries:
            z.writestr(zi, data)
    return bytearray(b.getvalue())
open("names.tar", "wb").write(tbytes([(tarfile.TarInfo("MYHOST/" + gh), b"x\n")]))
open("certs.zip", "wb").write(bytes(zbytes([(zipfile.ZipInfo("certs/client.p12"), b"0\x82\x01\x00")])))
# The end record's two counts one short.
z = zbytes([(zipfile.ZipInfo("one.txt"), b"x\n"), (zipfile.ZipInfo("two.txt"), b"see /home/alice/two\n")])
e = z.rfind(b"PK\x05\x06")
z[e + 8:e + 12] = struct.pack("<HH", 1, 1)
open("count.zip", "wb").write(bytes(z))
u = tarfile.TarInfo("u.dat"); u.type = b"U"
open("type.tar", "wb").write(tbytes([(u, b"see /home/alice/typeu\n")]))
# Stated 100 bytes, deflating to 10 KB: under a buffer of 16 KiB more.
zi = zipfile.ZipInfo("long.txt"); zi.compress_type = zipfile.ZIP_DEFLATED
z = zbytes([(zi, b"x\n" * 5000 + b"see /home/alice/tail\n")])
c = z.rfind(b"PK\x01\x02")
z[c + 24:c + 28] = struct.pack("<I", 100)
open("long.zip", "wb").write(bytes(z))
zi = zipfile.ZipInfo("e.txt"); zi.comment = b"see /home/alice/meta2"
open("meta.zip", "wb").write(bytes(zbytes([(zi, b"x\n")], comment=b"built in /home/alice/meta1")))
raw = zlib.compressobj(9, zlib.DEFLATED, -15)
body = raw.compress(b"x\n") + raw.flush()
open("c.gz", "wb").write(b"\x1f\x8b\x08\x10\0\0\0\0\0\x03" + b"see /home/alice/gzc\0" + body
                         + struct.pack("<II", zlib.crc32(b"x\n"), 2))
o = tarfile.TarInfo("f.txt"); o.uname = "MYHOST"; o.pax_headers = {"comment": "see /home/alice/pax"}
open("owner.tar", "wb").write(tbytes([(o, b"x\n")], fmt=tarfile.PAX_FORMAT))
open("glob.tar", "wb").write(tbytes([(tarfile.TarInfo("g.txt"), b"x\n")], fmt=tarfile.PAX_FORMAT,
                                    pax_headers={"comment": "see /home/alice/glob"}))
g = io.BytesIO()
with gzip.GzipFile(filename="MYHOST-backup.tar", mode="wb", fileobj=g, mtime=0) as f:
    f.write(tbytes([(tarfile.TarInfo("h.txt"), b"x\n")]))
open("named.tar.gz", "wb").write(g.getvalue())
PY
  git add names.tar certs.zip count.zip type.tar long.zip meta.zip c.gz owner.tar glob.tar named.tar.gz
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 1 "$BIN" --archives
  assert_contains "names.tar!MYHOST/$(masked "$gh"):0: [MYHOST] MYHOST/$(masked "$gh")" "$LC_OUT"
  assert_contains "names.tar!MYHOST/$(masked "$gh"):0: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_contains "certs.zip!certs/client.p12:0: [credential:pkcs12-file] certs/client.p12" "$LC_OUT"
  assert_contains "count.zip!two.txt:1: $H see /home/alice/two" "$LC_OUT"
  assert_contains "type.tar!u.dat:1: $H see /home/alice/typeu" "$LC_OUT"
  assert_not_contains "alice/tail" "$LC_OUT"
  assert_contains "meta.zip:0: $H (comment) built in /home/alice/meta1" "$LC_OUT"
  assert_contains "meta.zip!e.txt:0: $H (comment) see /home/alice/meta2" "$LC_OUT"
  assert_contains "c.gz:0: $H (comment) see /home/alice/gzc" "$LC_OUT"
  assert_contains "owner.tar!f.txt:0: [MYHOST] (owner) MYHOST:" "$LC_OUT"
  assert_contains "owner.tar!f.txt:0: $H (pax) comment=see /home/alice/pax" "$LC_OUT"
  assert_contains "glob.tar:0: $H (pax) comment=see /home/alice/glob" "$LC_OUT"
  assert_contains "named.tar.gz:0: [MYHOST] (name) MYHOST-backup.tar" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
  assert_not_contains "$gh" "$LC_ERR"
  assert_contains "1 not read)" "$LC_ERR"
  assert_exit 1 "$BIN" --archives --strict --json
  assert_not_contains "$gh" "$LC_OUT"
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
u = [(h["file"], h["text"]) for h in d["hits"] if h["pattern"] == "unscanned:archive"]
assert u == [("long.zip!long.txt", "(archive member not read: not read whole)")], u
' "$LC_OUT"
  # --redact hides a tell found in a member's name wherever a path prints.
  assert_exit 1 "$BIN" --archives --redact
  assert_not_contains "MYHOST" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
}

t_dir_counts_paths_named_git() {
  # /qaa (v0.29.2): --dir dropped every path named .git silently — git
  # indexes none — under a summary saying "every file". Each is counted
  # (a backup's .git directory, a file named .git, the top's), a .git inside
  # an embedded repository stays that repository's (a submodule), and
  # --strict reports each.
  local d="$PWD/.git/plain"
  mkdir -p "$d/backup/.git" "$d/w" "$d/sub" "$d/.git"
  printf 'url = https://x/home/alice/\n' > "$d/backup/.git/config"
  printf 'gitdir: /home/alice/elsewhere\n' > "$d/w/.git"
  printf 'x\n' > "$d/.git/HEAD"
  git -C "$d/sub" init -q
  printf 'x\n' > "$d/sub/a.txt"
  git -C "$d/sub" -c core.hooksPath=/dev/null add a.txt
  git -C "$d/sub" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -q -m i
  printf 'clean\n' > "$d/top.txt"
  assert_exit 0 "$BIN" --dir "$d"
  assert_contains "1 submodules not scanned" "$LC_OUT"
  assert_contains "; 3 paths named .git not scanned" "$LC_OUT"
  assert_exit 1 "$BIN" --dir "$d" --strict --json
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
g = sorted((h["file"], h["text"]) for h in d["hits"] if h["pattern"] == "unscanned:git-dir")
assert g == [(".git", "(named .git; contents not scanned)"), ("backup/.git", "(named .git; contents not scanned)"),
             ("w/.git", "(named .git; contents not scanned)")], g
assert d["git_dirs"] == 3, d
assert list(d)[-1] == "git_dirs", list(d)
' "$LC_OUT"
  # A tree, not --dir: no such count.
  seed a.txt "clean"
  commit init
  assert_exit 0 "$BIN"
  assert_not_contains "named .git" "$LC_OUT"
}

t_decode_reads_past_prefixes() {
  # /qaa (v0.29.2): --decode missed a percent line holding one escape that
  # is not text, hex after 0x, base64 after a path, a type-changed file, an
  # archive member, and a run the 8192 bytes of a line read at a time cut
  # (two ways: reaching their end, and starting in their last 20 bytes).
  local H='[/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/]' b64
  python3 - <<'PY'
import base64, zipfile
b = lambda s: base64.b64encode(s.encode()).decode()
lines = [
    "u: ?p=%2Fhome%2Falice%2Fpct&who=Zo%C3%AB",
    "h: 0x" + "see /home/alice/hex0x".encode().hex(),
    "s: /static/" + b("see /home/alice/b64path"),
    # A run from byte 8149 on: the first 8192 read reach their end in it.
    " " * 8146 + "r: " + b("x" * 40 + " see /home/alice/winend"),
    # A run from byte 8181 on: its first 11 bytes alone in the first 8192
    # (not 12: base64 cut by a multiple of 4 still decodes).
    " " * 8178 + "q: " + b("y" * 30 + " see /home/alice/wincut"),
]
open("a.txt", "w").write("\n".join(lines) + "\n")
z = zipfile.ZipFile("z.zip", "w")
z.writestr("m.txt", "v: " + b("see /home/alice/ardec") + "\n")
z.close()
open("tc.txt", "w").write("k: " + b("see /home/alice/tcdec") + "\n")
PY
  ln -s target l.txt
  git add a.txt z.zip l.txt
  commit init
  rm l.txt
  mv tc.txt l.txt
  assert_exit 1 "$BIN" --decode --archives
  assert_contains "a.txt:1: $H u: ?p=/home/alice/pct&who=Zo%C3%AB (decoded percent)" "$LC_OUT"
  assert_contains "a.txt:2: $H h: 0xsee /home/alice/hex0x (decoded hex)" "$LC_OUT"
  assert_contains "a.txt:3: $H s: /static/see /home/alice/b64path (decoded base64)" "$LC_OUT"
  assert_contains "a.txt:4: $H" "$LC_OUT"
  assert_contains "see /home/alice/winend (decoded base64)" "$LC_OUT"
  assert_contains "a.txt:5: $H" "$LC_OUT"
  assert_contains "see /home/alice/wincut (decoded base64)" "$LC_OUT"
  assert_contains "z.zip!m.txt:1: $H v: see /home/alice/ardec (decoded base64)" "$LC_OUT"
  assert_contains "l.txt:1: $H k: see /home/alice/tcdec (decoded base64)" "$LC_OUT"
}

t_kv_random_camel_values_are_keys() {
  # /qaa (v0.29.3): v0.25.1 took one word-part value with a hump for a
  # camel-case name, and a random key has one often (1.9% at 16): these two
  # read as code. A name in whole words is still code (a guard).
  printf '%s\n' "SIGNING_KEY=Vqm""Cplppjs46Lmue" "HEROKU=WPns""uvBqbwq7sdTW" "key: privateKeyPEM" > .env.example
  git add .env.example
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted((h["line"], h["pattern"]) for h in d["hits"]) == [(1, "credential:generic-key"), (2, "credential:service-secret")], d["hits"]
assert d["credentials"]["weak"] == 1, d["credentials"]
PY
}

t_kv_quoted_value_is_no_call() {
  # Codex, the /qaa of main..dev (v0.29.4): v0.25.2's call reading took a
  # quoted value followed by `(` for a function's name: set aside, exit 0.
  # The unquoted call stays code (t_kv_parts_values_are_code, a guard).
  printf '%s\n' 'key = "Zq7Lm2Xv9''Rt4Wp8Ks3Nb(foo)"' > c.py
  git add c.py
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN"
  assert_contains "c.py:1: [credential:generic-key] key[redacted, 20 chars]" "$LC_OUT"
}

t_credential_opened_and_slashed_rules_judge_the_key() {
  # Codex, the /qaa of main..dev (v0.29.4): rules whose length is fixed and
  # taken as a least, and rules taking `/`, read text glued after a key as
  # the key's: `12345678` or `/XXXXXXXX` made it a stand-in, exit 0. And a
  # long-term Bedrock key in JSON, its `/` written `\/`, was no match.
  local id m
  local -a lines=()
  for id in adobe-client-secret infracost-token clickhouse-secret octopus-key \
            easypost-key frameio-token intra42-secret aws-bedrock-long-term-key; do
    # No `/` of its own, so the slash rules cannot decide it.
    m=$(cred "$id"); m=${m#=}; m=${m//\//+}
    lines+=("k: $m""1234""5678")
  done
  m=$(cred aws-bedrock-long-term-key); m=${m#=}
  lines+=("s: ${m//\//+}/XXXX""XXXX")
  lines+=("Authorization: Bearer Zq7Lm2Xv9""Rt4Wp8Ks3Nb7Hd/XXXX""XXXX")
  lines+=("Authorization: Basic WGszajlmTHEy""bVpwN3dSNGFROlpyOEx""tMktx/XXXX""XXXX")
  lines+=('j: {"k": "AB''SKZq7Lm2Xv9Rt4Wp8Ks3Nb\/'"$(printf 'Hq3Lm8Xv2Rt9Wp4Ks7Nb%.0s' 1 2 3 4 5)"'"}')
  printf '%s\n' "${lines[@]}" > k.txt
  git add k.txt
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = ["adobe-client-secret", "infracost-token", "clickhouse-secret", "octopus-key",
        "easypost-key", "frameio-token", "intra42-secret", "aws-bedrock-long-term-key",
        "aws-bedrock-long-term-key", "http-bearer-token", "http-basic-auth",
        "aws-bedrock-long-term-key"]
got = sorted((h["line"], h["pattern"]) for h in d["hits"])
assert got == [(n + 1, "credential:" + w) for n, w in enumerate(want)], got
assert d["credentials"].get("placeholders", 0) == 0 and d["credentials"].get("weak", 0) == 0, d["credentials"]
PY
}

t_archives_compare_raw_bytes() {
  # Codex, the /qaa of main..dev (v0.29.4): the worktree archive was hashed
  # with its filters to compare with the index's, so a clean filter in
  # .git/info/attributes made the two equal: the worktree's members alone
  # were read, and the index's leak was missed, exit 0.
  python3 - <<'PY'
import zipfile
z = zipfile.ZipFile(".git/staged.zip", "w"); z.writestr("m.txt", "see /home/alice/staged\n"); z.close()
z = zipfile.ZipFile("a.zip", "w"); z.writestr("m.txt", "clean\n"); z.close()
PY
  printf 'a.zip filter=swap\n' > .git/info/attributes
  git config filter.swap.clean 'cat .git/staged.zip'
  git add a.zip
  commit init
  assert_exit 1 "$BIN" --archives
  assert_contains "a.zip!m.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] see /home/alice/staged" "$LC_OUT"
}

t_decode_tries_every_path_part() {
  # Codex, the /qaa of main..dev (v0.29.4): --decode tried eight path parts,
  # and `//localhost` took three, so a value after six was never read. Hex
  # after a path is its last part (a guard: v0.29.3 reads it too).
  local H='[/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/]'
  python3 - <<'PY'
import base64
b = lambda s: base64.b64encode(s.encode()).decode()
open("a.txt", "w").write("\n".join([
    "u: http://localhost/a/b/c/d/e/f/" + b("see /home/alice/url6"),
    "p: x/1/2/3/4/5/6/7/8/9/10/11/" + b("see /home/alice/deep12"),
    "h: /a/b/" + "see /home/alice/hexpath".encode().hex(),
    # Its base64 holds a `/` (`b2s/`): a try that is not the last part.
    "q: /x/y/" + b("ok? see /home/alice/qmark"),
]) + "\n")
PY
  git add a.txt
  commit init
  assert_exit 1 "$BIN" --decode
  assert_contains "a.txt:1: $H u: http://localhost/a/b/c/d/e/f/see /home/alice/url6 (decoded base64)" "$LC_OUT"
  assert_contains "a.txt:2: $H p: x/1/2/3/4/5/6/7/8/9/10/11/see /home/alice/deep12 (decoded base64)" "$LC_OUT"
  assert_contains "a.txt:3: $H h: /a/b/see /home/alice/hexpath (decoded hex)" "$LC_OUT"
  assert_contains "a.txt:4: $H q: /x/y/ok? see /home/alice/qmark (decoded base64)" "$LC_OUT"
}

t_kv_long_value_is_masked_whole() {
  # Codex, the /qaa of main..dev (v0.29.5): a keyword rule's value was
  # bounded (Bearer's at 126), so a longer value's tail lay outside the
  # match and printed in a name and an allow rule; and a URL's password
  # over 128 characters was no match at all, exit 0. The judgement still
  # reads the start a bounded match held: a tail saying `example` past it
  # sets nothing aside (a guard; v0.29.4 never saw the tail), and Basic's
  # decoded password is judged whole (a guard: `Q7xLm2Kp.changeme`).
  local t a p
  t=$(python3 -c 'import random; r = random.Random(5); print("".join(r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(160)))')
  a=$(python3 -c 'import random; r = random.Random(6); print("".join(r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(160)))')
  p=$(python3 -c 'import random; r = random.Random(7); print("".join(r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(200)))')
  mkdir n
  printf 'x\n' > "n/Authorization Bearer $t"
  printf 'db: postgres://app:%s@db.example:5432/app\n' "$p" > u.txt
  printf 'password = "%s_example_tail"\n' "${p:0:100}" >> u.txt
  printf 'Authorization: Basic %s\n' "$(printf 'admin:Q7xLm2Kp.changeme' | base64)" >> u.txt
  # A keyword rule yields to another's value as before, by the start a
  # bounded match held (a guard): the generic value runs on through
  # `key=…`, and both are reported, as in v0.29.4.
  printf 'password=%skey=%s\n' "${p:0:110}" "${a:0:30}" >> u.txt
  git add -A
  rc_file 'no-defaults' "allow Authorization Bearer $a"
  commit init
  assert_exit 1 "$BIN" --json
  assert_not_contains "${t:100}" "$LC_OUT"
  assert_not_contains "${a:100}" "$LC_OUT"
  assert_not_contains "${p:100}" "$LC_OUT"
  python3 - "$LC_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
got = sorted((h["file"].split("/")[0], h["line"], h["pattern"], h["text"]) for h in d["hits"])
# The allow rule's key is published in the config too, and reported.
assert got == [(".leakcheckrc", 2, "credential:http-bearer-token", "Bearer[redacted, 160 chars]"),
               ("n", 0, "credential:http-bearer-token", "Bearer[redacted, 160 chars]"),
               ("u.txt", 1, "credential:url-password", "postgres://[redacted, 200 chars]"),
               ("u.txt", 2, "credential:generic-secret", "password[redacted, 113 chars]"),
               ("u.txt", 4, "credential:generic-key", "key[redacted, 30 chars]"),
               ("u.txt", 4, "credential:generic-secret", "password[redacted, 144 chars]")], got
PY
  # Matched to its end, a value can hold a key and more: masking yields to a
  # key only when the key holds the whole value. v0.29.4 yielded to a key
  # the value held and printed the rest (`<key>.Zq7…`).
  assert_exit 2 "$BIN" "--secret=$(cred github-token).Zq7Lm2Xv9""Rt4"
  assert_not_contains "Zq7Lm2Xv9""Rt4" "$LC_ERR"
}

t_redact_list_patterns_hides_plain_patterns() {
  # Codex, the /qaa of main..dev (v0.29.6): --redact hid a config pattern's
  # regex in its hits, as `pattern:<n>`, and --list-patterns printed it.
  # A label is the name a user chose to print (a guard).
  seed a.txt "MYHOST INTERNAL-XYZ"
  rc_file 'no-defaults' 'no-credentials' 'pattern MYHOST' 'label codename INTERNAL-XYZ'
  commit init
  assert_exit 0 "$BIN" --redact --list-patterns
  assert_not_contains "MYHOST" "$LC_OUT"
  [[ "$(cat "$LC_OUT")" == $'pattern:1\ncodename' ]] || { cat "$LC_OUT"; return 1; }
  assert_exit 1 "$BIN" --redact
  assert_contains "[pattern:1]" "$LC_OUT"
}

t_rule_path_rule_alone_scans() {
  # Codex, the /qaa of main..dev (v0.29.6): the empty-scan guard counted the
  # content rules alone, so `--rule credential:pkcs12-file` was "no
  # patterns to scan", exit 2.
  seed certs/client.p12 "x"
  commit init
  assert_exit 1 "$BIN" --rule credential:pkcs12-file
  assert_contains "certs/client.p12:0: [credential:pkcs12-file]" "$LC_OUT"
}

t_baseline_counts_each_copy_apart() {
  # Codex, the /qaa of main..dev (v0.29.6): a baselined line moved in the
  # worktree alone was found twice, the index's copy and the worktree's,
  # and counted together the second read as new until staged; under
  # --decode too. A copy added is still new (a guard).
  local b
  b=$(python3 -c 'import base64; print(base64.b64encode(b"see /home/alice/moved").decode())')
  printf '%s\n' a b "key = \"Zq7Lm2Xv9""Rt4Wp8Ks3Nb\"" "v: $b" > m.txt
  git add m.txt
  commit init
  assert_exit 1 "$BIN" --decode --write-baseline .git/bl
  printf '%s\n' "v: $b" "key = \"Zq7Lm2Xv9""Rt4Wp8Ks3Nb\"" a b > m.txt
  assert_exit 0 "$BIN" --decode --baseline .git/bl
  assert_contains "4 in baseline" "$LC_OUT"
  printf '%s\n' "v: $b" "key = \"Zq7Lm2Xv9""Rt4Wp8Ks3Nb\"" a b "key = \"Zq7Lm2Xv9""Rt4Wp8Ks3Nb\"" > m.txt
  assert_exit 1 "$BIN" --decode --baseline .git/bl
  assert_contains "[credential:generic-key]" "$LC_OUT"
  [[ "$(wc -l < "$LC_OUT")" -eq 1 ]] || { cat "$LC_OUT"; return 1; }
  # A decoded copy beside a line in both copies: the line counts in both.
  printf '%s\n' a b "key = \"Zq7Lm2Xv9""Rt4Wp8Ks3Nb\"" "v: $b" "v: $b" > m.txt
  assert_exit 1 "$BIN" --decode --baseline .git/bl
  assert_contains "m.txt:5: [/home/" "$LC_OUT"
  [[ "$(wc -l < "$LC_OUT")" -eq 1 ]] || { cat "$LC_OUT"; return 1; }
}

t_baseline_holds_a_member_s_content() {
  # Codex, the /qaa of main..dev (v0.29.6): an unscanned archive member's
  # fingerprint looked for `outer.zip!inner.bin` on disk, found neither id,
  # and a member whose bytes changed stayed baselined, exit 0.
  python3 -c 'import zipfile; z = zipfile.ZipFile("o.zip", "w"); z.writestr("inner.bin", bytes(range(256))); z.close()'
  git add o.zip
  commit init
  assert_exit 1 "$BIN" --archives --strict --write-baseline .git/bl
  assert_contains "o.zip!inner.bin:0: [unscanned:binary]" "$LC_OUT"
  assert_exit 0 "$BIN" --archives --strict --baseline .git/bl
  python3 -c 'import zipfile; z = zipfile.ZipFile("o.zip", "w"); z.writestr("inner.bin", bytes(range(255, -1, -1))); z.close()'
  # The worktree's member alone changed; the index's alone; both.
  assert_exit 1 "$BIN" --archives --strict --baseline .git/bl
  assert_contains "o.zip!inner.bin:0: [unscanned:binary]" "$LC_OUT"
  git add o.zip
  git show HEAD:o.zip > o.zip
  assert_exit 1 "$BIN" --archives --strict --baseline .git/bl
  assert_contains "o.zip!inner.bin:0: [unscanned:binary]" "$LC_OUT"
  git checkout -- o.zip
  commit two
  assert_exit 1 "$BIN" --archives --strict --baseline .git/bl
  assert_contains "o.zip!inner.bin:0: [unscanned:binary]" "$LC_OUT"
}

t_kv_basic_auth_user_is_judged() {
  # /qaa (v0.29.3): Basic auth judged by its password alone set aside an
  # API key sent as the user with `X` for the password (Freshdesk,
  # BambooHR, Teamwork). Weak only when both are (a guard: admin:changeme).
  local b w
  b=$(python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "Xk3j9fLq""2mZp7wR4aQ:X")
  w=$(python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "admin:changeme")
  seed h.txt $'Authorization: Basic '"$b"$'\nAuthorization: Basic '"$w"
  rc_file 'no-defaults'
  commit init
  assert_exit 1 "$BIN" --json
  python3 - "$LC_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert [(h["line"], h["pattern"]) for h in d["hits"]] == [(1, "credential:http-basic-auth")], d["hits"]
assert d["credentials"]["weak"] == 1, d["credentials"]
PY
}

t_redact_hides_tells_in_credential_text() {
  # /qaa (v0.29.3): --redact gathered tells from names alone, and hid them
  # in paths alone: a path rule's hit printed its name (MYHOST-client.p12),
  # and xml-key-value its keyword (MYHOST.Password), each a tell another
  # hit had hidden.
  seed "MYHOST-client.p12" "x"
  seed n.config '<add key="MYHOST.Password" value="Xk3j9fLq2mZp7wR4a"/>'
  rc_file 'pattern MYHOST'
  commit init
  assert_exit 1 "$BIN" --redact
  assert_contains "[credential:pkcs12-file]" "$LC_OUT"
  assert_contains "[credential:xml-key-value]" "$LC_OUT"
  assert_not_contains "MYHOST" "$LC_OUT"
  assert_exit 1 "$BIN" --redact --json
  assert_not_contains "MYHOST" "$LC_OUT"
  # The tell in a line alone, in no name: gathered from the line's hit.
  git rm -q "MYHOST-client.p12"
  commit two
  assert_exit 1 "$BIN" --redact
  assert_contains "[credential:xml-key-value]" "$LC_OUT"
  assert_not_contains "MYHOST" "$LC_OUT"
}

t_credential_cut_only_past_an_edge() {
  # /qaa (v0.29.3): cred_key cut a match at its rule's literal wherever it
  # sat, and facebook-token's <app id>|<secret> can hold EAA in its secret:
  # the cut printed the secret's head in a name, and masked the rest as a
  # shorter key.
  local fb
  fb="7391046""28517392|Qx7kZp2""EA""Am9Lw4Rt8Vy3Nb6Hc1Jd5"
  seed "cfg-$fb.txt" "x"
  seed a.txt "tok: $fb"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [credential:facebook-token] $(masked "$fb")" "$LC_OUT"
  assert_contains "cfg-$(masked "$fb").txt:0: [credential:facebook-token] $(masked "$fb")" "$LC_OUT"
  assert_not_contains "Qx7kZp2" "$LC_OUT"
}

t_baseline_holds_unscanned_content() {
  # /qaa (v0.29.3): an unscanned finding's print was its path, pattern and
  # fixed text, so a baselined binary file stayed baselined whatever it came
  # to hold. Its content's identity is in the print now, the worktree's and
  # the index's.
  printf 'a\0b' > data.bin
  git add data.bin
  commit init
  assert_exit 1 "$BIN" --strict --write-baseline .git/bl
  assert_exit 0 "$BIN" --strict --baseline .git/bl
  printf 'c\0d' > data.bin
  assert_exit 1 "$BIN" --strict --baseline .git/bl
  git add data.bin
  commit two
  assert_exit 1 "$BIN" --strict --baseline .git/bl
}

t_junit_drops_xml_noncharacters() {
  # /qaa (v0.29.3): U+FFFE and U+FFFF are well-formed UTF-8 and no XML 1.0
  # character; a hit line holding one made the JUnit report unparseable.
  seed a.txt "see /home/alice/x $(printf '\xef\xbf\xbf\xef\xbf\xbe') y"
  commit init
  assert_exit 1 "$BIN" --format junit
  python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$LC_OUT"
  assert_contains "/home/alice/x" "$LC_OUT"
}

t_history_text_driver_sends_merges_to_m() {
  # /qaa (v0.29.3): merge.default=text, pinned so the re-merge runs git's
  # own driver, named a user's `[merge "text"]` driver instead, as git looks
  # a name up among the user's first: it wrote the merge's own line again,
  # and the re-merge hid it. Such a driver sends the pass to -m.
  local cfg="$PWD/.git/text.cfg" m
  printf '[merge]\n\tdefault = text\n[merge "text"]\n\tdriver = printf '"'"'see /home/alice/textdrv\\\\n'"'"' >> %%A\n' > "$cfg"
  seed a.txt $'one\ntwo\nthree'
  commit base
  git checkout -q -b side
  seed a.txt $'ONE\ntwo\nthree'
  commit side
  git checkout -q dev
  seed a.txt $'one\ntwo\nTHREE'
  commit dev
  GIT_CONFIG_GLOBAL="$cfg" git -c core.hooksPath=/dev/null -c commit.gpgsign=false merge -q --no-edit side >/dev/null
  m=$(sha_of)
  seed a.txt "clean"
  commit scrub
  GIT_CONFIG_GLOBAL="$cfg" assert_exit 1 "$BIN" --history --json
  python3 - "$LC_OUT" "$m" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["history"]["merge_diffs"] == "separate", doc["history"]
assert [(h["commit"], h["file"], h["line"]) for h in doc["hits"]] == [(sys.argv[2], "a.txt", 4)], doc["hits"]
PY
}

t_archives_read_members() {
  # Stage E (v0.28.0): --archives reads tracked zip, tar and gzip files by
  # their first bytes, with bash and git alone: a deflated member, a stored
  # one with a key, one past 64 KiB, one exactly 65536 bytes (the padding's
  # edge), a pax, a ustar-prefix and a GNU long name, a link's target, a
  # gzip's own name, member names; an encrypted member and one not read
  # whole counted, an archive inside one a binary member, a damaged archive
  # still a binary file; --strict reports each, --dir reads them too, a
  # caller's GIT_OBJECT_DIRECTORY is not the scratch repository's, and an
  # index copy differing from the worktree's is read as its own. Without
  # the flag nothing changes.
  local gh d
  gh=$(cred github-token)
  python3 - "$gh" <<'PY'
import gzip, io, sys, tarfile, zipfile
gh = sys.argv[1]
def zbytes(entries):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        for name, data, method in entries:
            zi = zipfile.ZipInfo(name)
            zi.compress_type = method
            z.writestr(zi, data)
    return bytearray(b.getvalue())
def set_flag(z, name, bit):
    # zipfile clears flag_bits as it writes: set them in the bytes.
    i = 0
    while True:
        i = z.find(b"PK\x01\x02", i)
        n = int.from_bytes(z[i + 28:i + 30], "little")
        if z[i + 46:i + 46 + n] == name.encode():
            z[i + 8] |= bit
            lho = int.from_bytes(z[i + 42:i + 46], "little")
            z[lho + 6] |= bit
            return
        i += 4
inner = zbytes([("in.txt", "see /home/alice/inner\n", zipfile.ZIP_DEFLATED)])
big = "".join("line %d\n" % i for i in range(30000)) + "end /home/alice/big\n"
ex = "see /home/alice/exact\n"
ex += "a" * (65536 - len(ex) - 1) + "\n"
assert len(ex) == 65536
a = zbytes([
    ("conf/app.txt", "x\nsee /home/alice/zip\n", zipfile.ZIP_DEFLATED),
    ("stored.txt", "token = " + gh + "\n", zipfile.ZIP_STORED),
    ("big.txt", big, zipfile.ZIP_DEFLATED),
    ("exact.txt", ex, zipfile.ZIP_DEFLATED),
    ("locked.txt", "see /home/alice/locked\n", zipfile.ZIP_STORED),
    ("inner.zip", bytes(inner), zipfile.ZIP_STORED),
    ("dir-MYHOST/", "", zipfile.ZIP_STORED),
])
set_flag(a, "locked.txt", 1)
open("a.zip", "wb").write(a)
# The stated size one more than the truth: never read whole.
bad = zbytes([("bad.txt", "see /home/alice/bad\n" * 50, zipfile.ZIP_DEFLATED)])
cd = bad.rfind(b"PK\x01\x02")
u = int.from_bytes(bad[cd + 24:cd + 28], "little")
bad[cd + 24:cd + 28] = (u + 1).to_bytes(4, "little")
open("bad.zip", "wb").write(bytes(bad))
open("broken.zip", "wb").write(b"PK\x03\x04" + bytes(range(256)) * 4)
def tbytes(fmt, members):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w", format=fmt) as t:
        for name, data, link in members:
            ti = tarfile.TarInfo(name)
            if link is not None:
                ti.type = tarfile.SYMTYPE
                ti.linkname = link
                t.addfile(ti)
            else:
                d = data.encode()
                ti.size = len(d)
                t.addfile(ti, io.BytesIO(d))
    return b.getvalue()
tgz = tbytes(tarfile.PAX_FORMAT, [("etc/x.cfg", "key: value\ntoken = " + gh + "\n", None),
                                 ("lnk", None, "/home/alice/link"),
                                 ("d/" + "n" * 120 + "/deep.txt", "see /home/alice/deep\n", None)])
open("b.tar.gz", "wb").write(gzip.compress(tgz, mtime=0))
open("c.tar", "wb").write(tbytes(tarfile.USTAR_FORMAT, [("p" * 80 + "/" + "q" * 60 + ".txt", "see /home/alice/prefix\n", None)]))
open("d.tar", "wb").write(tbytes(tarfile.GNU_FORMAT, [("g/" + "m" * 120 + "/x.txt", "see /home/alice/gnu\n", None)]))
def gz(text):
    b = io.BytesIO()
    with gzip.GzipFile(filename="orig.txt", mode="wb", fileobj=b, mtime=0) as g:
        g.write(text)
    return b.getvalue()
open("e.gz", "wb").write(gz(b"x\nsee /home/alice/gz\n"))
open("e2.gz", "wb").write(gz(b"x\nsee /home/alice/gz2\n"))
PY
  git add a.zip bad.zip broken.zip b.tar.gz c.tar d.tar e.gz
  rc_file 'pattern MYHOST'
  commit init
  local H='[/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/]' n m p q
  n=$(printf 'n%.0s' {1..120}); m=$(printf 'm%.0s' {1..120})
  p=$(printf 'p%.0s' {1..80}); q=$(printf 'q%.0s' {1..60})
  assert_exit 0 "$BIN"
  assert_contains "7 binary skipped" "$LC_OUT"
  assert_exit 1 "$BIN" --archives
  assert_contains "a.zip!conf/app.txt:2: $H see /home/alice/zip" "$LC_OUT"
  assert_contains "a.zip!stored.txt:1: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_contains "a.zip!big.txt:30001: $H end /home/alice/big" "$LC_OUT"
  assert_contains "a.zip!exact.txt:1: $H see /home/alice/exact" "$LC_OUT"
  assert_contains "a.zip!dir-MYHOST/:0: [MYHOST] dir-MYHOST/" "$LC_OUT"
  assert_contains "b.tar.gz!etc/x.cfg:2: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_contains "b.tar.gz!lnk:0: $H -> /home/alice/link" "$LC_OUT"
  assert_contains "b.tar.gz!d/$n/deep.txt:1: $H see /home/alice/deep" "$LC_OUT"
  assert_contains "c.tar!$p/$q.txt:1: $H see /home/alice/prefix" "$LC_OUT"
  assert_contains "d.tar!g/$m/x.txt:1: $H see /home/alice/gnu" "$LC_OUT"
  assert_contains "e.gz!orig.txt:2: $H see /home/alice/gz" "$LC_OUT"
  assert_not_contains "locked" "$LC_OUT"
  assert_not_contains "alice/inner" "$LC_OUT"
  assert_not_contains "alice/bad" "$LC_OUT"
  assert_not_contains "$gh" "$LC_OUT"
  assert_not_contains "internal error" "$LC_ERR"
  assert_contains "leakcheck: 11 match(es)" "$LC_ERR"
  assert_contains "; 2 binary skipped," "$LC_ERR"
  assert_contains "; 6 archives read (10 members, 2 not read), 1 archives not read (one level)" "$LC_ERR"
  assert_exit 1 "$BIN" --archives --strict --json
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
u = sorted((h["pattern"], h["file"], h["text"]) for h in d["hits"] if h["pattern"].startswith("unscanned"))
assert u == [("unscanned:archive", "a.zip!locked.txt", "(archive member not read: encrypted)"),
             ("unscanned:archive", "bad.zip!bad.txt", "(archive member not read: not read whole)"),
             ("unscanned:binary", "a.zip!inner.zip", "(binary file; content not scanned)"),
             ("unscanned:binary", "broken.zip", "(binary file; content not scanned)")], u
assert d["archives"] == {"read": 6, "members": 10, "members_not_read": 2, "not_read": 1}, d["archives"]
' "$LC_OUT"
  # A caller's object directory (a hook sets one) is not the scratch
  # repository's: git would look for the member there.
  GIT_OBJECT_DIRECTORY="$PWD/.git/objects" assert_exit 1 "$BIN" --archives
  assert_contains "a.zip!big.txt:30001: $H end /home/alice/big" "$LC_OUT"
  # --dir reads them too: its scratch repository is not git's here.
  d="$PWD/.git/plain"
  mkdir "$d"
  cp a.zip e.gz "$d/"
  assert_exit 1 "$BIN" --dir "$d" --archives
  assert_contains "a.zip!conf/app.txt:2: $H see /home/alice/zip" "$LC_OUT"
  assert_contains "e.gz!orig.txt:2: $H see /home/alice/gz" "$LC_OUT"
  rm -rf "$d"
  # A worktree copy differing from the index's: each read, as its own.
  cp e2.gz e.gz
  rm e2.gz
  assert_exit 1 "$BIN" --archives --json
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
e = sorted((h["source"], h["text"]) for h in d["hits"] if h["file"] == "e.gz!orig.txt")
assert e == [("index", "see /home/alice/gz"), ("worktree", "see /home/alice/gz2")], e
' "$LC_OUT"
}

t_credential_v029_near_misses_are_clean() {
  # The v0.29.0 rules' edges and lengths: EAAA, 4b1d and ABSK inside base64
  # or hex, API- after a letter, and each prefix one short of its least —
  # a guard, as v0.28.0 has none of these rules — and facebook-token's new
  # edge: EAAM inside base64, which v0.28.0 reports.
  python3 - <<'PY'
import random
r = random.Random(29)
def run(cs, n):
    return "".join(r.choice(cs) for _ in range(n))
AN = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
HEX = "0123456789abcdef"
B64 = AN + "+/"
UD = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
lines = [
    "blob: x" + "EA" + "AA" + run(AN + "_", 70),
    "sha: " + run(HEX, 6) + "4b" + "1d" + run(HEX, 40),
    "data: Q" + "AB" + "SK" + run(B64, 140),
    "name: MY" + "AP" + "I-" + run(UD, 30),
    "a: " + "rd" + "me_" + run(AN, 15),
    "b: " + "4b" + "1d" + run(AN, 34),
    "c: " + "AP" + "I-" + run(UD, 25),
    "d: " + "EZ" + "AK" + run(AN, 53),
    "e: " + "fio" + "-u-" + run(AN, 63),
    "f: " + "s-s4" + "t2ud-" + run(HEX, 63),
    "g: " + "AB" + "SK" + run(B64, 108),
    "h: " + "pa" + "t" + run(AN, 14) + "." + run(HEX, 63),
    "i: " + "EA" + "AA" + run(AN, 59),
    "img: Q" + "EA" + "AM" + run(AN, 120),
]
open("near.txt", "w").write("\n".join(lines) + "\n")
PY
  git add near.txt
  commit init
  assert_exit 0 "$BIN"
  assert_contains "leakcheck: clean" "$LC_OUT"
}

t_credential_left_edge_is_not_masked_in_a_name() {
  # Guard (passes on v0.11.10, which had no edge): the character before a
  # deepseek-key in a path is not part of the key, so it prints; a mask
  # spanning it would print `=sk-` and one character too many.
  local ds
  ds=$(cred deepseek-key)
  seed "k=$ds/a.txt" "see /home/alice/x"
  commit init
  assert_exit 1 "$BIN"
  assert_contains "k=$(masked "$ds")/a.txt:1: [" "$LC_OUT"
}

t_credential_allow_rule_case_prefix_is_dropped_from_the_literal_form() {
  # Guard for v0.11.10 (no edge there): `(?i)sk\-<hex>` names the key with
  # an escape, so only the literal form finds it, and that form dropped the
  # parentheses alone, leaving `?isk-<hex>` — an `i` the deepseek edge
  # refuses, so the key printed. The literal form drops `(?i)` whole.
  local ds
  ds=$(cred deepseek-key)
  seed c.txt "k=$ds"
  rc_file "allow credential:deepseek-key (?i)sk\\-${ds:3}"
  commit init
  assert_exit 0 "$BIN" --json
  assert_not_contains "${ds:3:28}" "$LC_OUT"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
a = [(r["rule"], r["count"]) for r in doc["allowed"]]
assert a == [("credential:deepseek-key (?i)" + sys.argv[2], 1)], a' "$LC_OUT" "$(masked "sk\\-${ds:3}")"
}

t_config_errors_never_echo_a_key_for_a_rule_id() {
  # Until v0.11.0 a token was excused by `allow <token>`; one moved behind
  # `credential:` lands where a rule id goes, and each error printed it
  # (/qaa, v0.11.5).
  local gh line
  gh=$(cred github-token)
  seed a.txt "x"
  commit init
  for line in "allow credential:$gh" "allow credential:$gh ^a\\.txt:" "disable credential:$gh" "disable $gh"; do
    rc_file "$line"
    assert_exit 2 "$BIN"
    assert_not_contains "${gh:4:30}" "$LC_ERR"
    assert_not_contains "${gh:4:30}" "$LC_OUT"
  done
}

t_config_errors_mask_a_key_in_the_regex() {
  # An error quotes the rule it refuses, and git's own error quotes a
  # pattern it cannot compile: a key written there printed whole (v0.11.6
  # §4). Each error still names its line and its reason, the key masked;
  # one escaped with `\.` is found in its literal form, and a private key
  # header masks to the end of the line.
  local gh sg pk body k nb=$'\xc2\xa0'
  gh=$(cred github-token); sg=$(cred sendgrid-key); pk=$(cred private-key)
  body=$(python3 -c 'import random, string; r = random.Random(7); print("".join(r.choice(string.ascii_letters + string.digits + "+/") for _ in range(200)))')
  seed a.txt "x"
  commit init
  local -a cases=(   # config line, then what the error says
    "pattern $gh\\d"            ".leakcheckrc:1: pattern '$(masked "$gh")\\d': '\\d' is a plain 'd'"
    "allow [$gh\\d]"            ".leakcheckrc:1: allow '[$(masked "$gh")\\d]': inside [...] a backslash is literal"
    "pattern $gh "              ".leakcheckrc:1: pattern '$(masked "$gh") ' ends in whitespace"
    "allow $gh$nb"              ".leakcheckrc:1: allow '$(masked "$gh")$nb' begins or ends in an invisible Unicode space"
    "allow $gh|"                ".leakcheckrc:1: allow '$(masked "$gh")|' matches the empty string"
    "pattern $gh("              "scan error: pattern '$(masked "$gh")(' (git exited 128)"
    "$gh"                       "unknown directive: $(masked "$gh")"
    "allow ${sg//./\\.}\\d"     ".leakcheckrc:1: allow '$(masked "${sg//./\\.}")\\d': '\\d' is a plain 'd'"
  )
  for (( k = 0; k < ${#cases[@]}; k += 2 )); do
    rc_file "${cases[k]}"
    assert_exit 2 "$BIN"
    assert_contains "${cases[k + 1]}" "$LC_ERR"
    assert_not_contains "${gh:4:30}" "$LC_ERR"
    assert_not_contains "${sg:6:20}" "$LC_ERR"
  done
  # git's own message quotes the pattern too.
  rc_file "pattern $gh("
  assert_exit 2 "$BIN"
  assert_contains "  fatal: -e option, '$(masked "$gh")(': Unmatched" "$LC_ERR"
  rc_file "pattern $pk$body\\d"
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: pattern '----[redacted, " "$LC_ERR"
  assert_not_contains "${body:20:30}" "$LC_ERR"
  assert_not_contains "${body:170:30}" "$LC_ERR"
}

t_scan_errors_mask_a_key_in_a_path() {
  # A scan error names the file it could not read, in its own line and in
  # git's or cp's message; a key in that file's name printed whole there,
  # though every hit masks it.
  [[ "$(id -u)" -ne 0 ]] || return 0   # root reads everything
  local gh got
  gh=$(cred github-token)
  seed "d$gh.md" "ok"
  ln -s elsewhere "t$gh"
  git add -- "t$gh"
  commit init
  chmod 000 "d$gh.md"
  got=0
  "$BIN" >"$LC_OUT" 2>"$LC_ERR" || got=$?
  chmod 644 "d$gh.md"
  [[ "$got" -eq 2 ]] || { echo "    expected exit 2, got $got"; cat "$LC_ERR"; return 1; }
  assert_contains "scan error" "$LC_ERR"
  assert_contains "d$(masked "$gh").md" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  # A type change copied out for its scan: an index symlink, now a file
  # that cannot be read.
  git rm -q --cached "d$gh.md"
  rm -f "d$gh.md" "t$gh"
  commit drop
  printf 'ok\n' > "t$gh"
  chmod 000 "t$gh"
  got=0
  "$BIN" >"$LC_OUT" 2>"$LC_ERR" || got=$?
  chmod 644 "t$gh"
  [[ "$got" -eq 2 ]] || { echo "    expected exit 2, got $got"; cat "$LC_ERR"; return 1; }
  assert_contains "scan error: cannot read t$(masked "$gh")" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
}

t_error_masking_failure_prints_nothing_of_the_message() {
  # If the masking cannot run, the message is withheld rather than printed
  # unchecked. Break the first git call of the masking in a copy.
  local gh
  gh=$(cred github-token)
  seed a.txt "x"
  rc_file "pattern $gh\\d"
  commit init
  sed 's/grep --no-index -a -l -E "\${cre\[@\]}"/grep --no-such-flag/' "$BIN" > .git/mutated.sh
  grep -q -- '--no-such-flag' .git/mutated.sh
  assert_exit 2 bash .git/mutated.sh
  assert_contains "it is not printed" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  assert_not_contains ".leakcheckrc:1" "$LC_ERR"
}

t_error_masking_runs_apart_from_the_callers_git() {
  # GIT_TRACE makes every git call write to stderr, so the scan fails at
  # its first call, and the masking's own grep failed with it: one fixed
  # line printed, naming neither the call nor the cause (/qaa, v0.11.8).
  # Now the error names both, every git line indented under it.
  local gh line
  gh=$(cred github-token)
  seed a.txt "x"
  commit init
  GIT_TRACE=1 assert_exit 2 "$BIN"
  assert_contains "leakcheck: scan error: " "$LC_ERR"
  assert_contains "trace: built-in: git " "$LC_ERR"
  while IFS= read -r line; do
    [[ "$line" == leakcheck:* || "$line" == "  "* ]] || { echo "    a line past the error: $line"; return 1; }
  done < "$LC_ERR"
  # A config error quoting a key, under the same setting: masked, not withheld.
  rc_file "pattern $gh\\d"
  GIT_TRACE=1 assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: pattern '$(masked "$gh")\\d'" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  # And a trace2 target in the caller's global config, at either home.
  mkdir -p .git/h .git/x/git
  printf '[trace2]\n\tnormalTarget = true\n' | tee .git/h/.gitconfig > .git/x/git/config
  HOME="$PWD/.git/h" assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: pattern '$(masked "$gh")\\d'" "$LC_ERR"
  XDG_CONFIG_HOME="$PWD/.git/x" assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: pattern '$(masked "$gh")\\d'" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
}

t_no_patterns_is_an_error() {
  # Guard: with the defaults, the credential rules and the config all off
  # there is nothing to scan, which is an error, never a clean verdict.
  # Passes on v0.11.8 too: the message moved to die, unchanged.
  seed a.txt "x"
  rc_file 'no-defaults' 'no-credentials'
  commit init
  assert_exit 2 "$BIN"
  assert_contains "leakcheck: no patterns to scan (defaults disabled and config empty)" "$LC_ERR"
}

t_command_line_errors_mask_a_key() {
  # An error repeating an argument or a path printed before the masking
  # existed: a CI log shows an expanded `--config "$X"` or `--root "$X"`, a
  # key included, that the runner's echo of the command does not (Codex,
  # /qaa of v0.11.8). Each still names its reason, exit 2, and a flag error
  # is still followed by the usage.
  local gh usage="leakcheck — scan a repo's tracked files"
  gh=$(cred github-token)
  seed a.txt "x"
  commit init
  assert_exit 2 "$BIN" --config "c$gh.rc"
  assert_contains "leakcheck: config not found: c$(masked "$gh").rc" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  assert_exit 2 "$BIN" --root "r$gh"
  assert_contains "leakcheck: cannot cd to r$(masked "$gh")" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  assert_exit 2 "$BIN" --history-range "--$gh"
  assert_contains "leakcheck: --history-range takes a revision range, not an option: --$(masked "$gh")" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  assert_exit 2 "$BIN" "--token=$gh"
  assert_contains "leakcheck: unknown flag: --token=$(masked "$gh")" "$LC_ERR"
  assert_contains "$usage" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  assert_exit 2 "$BIN" --json "$gh"
  assert_contains "leakcheck: unexpected arg: $(masked "$gh")" "$LC_ERR"
  assert_contains "$usage" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  # The repo's own path, in an error about a config at its top level.
  mkdir "r$gh"
  git -C "r$gh" init -q
  ln -s nowhere "r$gh/.leakcheckrc"
  assert_exit 2 "$BIN" --root "r$gh"
  assert_contains "/r$(masked "$gh")/.leakcheckrc" "$LC_ERR"
  assert_not_contains "${gh:4:30}" "$LC_ERR"
  # The temp dir now comes before the cds, so a relative TMPDIR names a place
  # from where the run started, whatever --root or the top level says.
  mkdir -p .git/rt sub
  TMPDIR=.git/rt assert_exit 2 "$BIN" --root sub --config "c$gh.rc"
  assert_contains "leakcheck: config not found: c$(masked "$gh").rc" "$LC_ERR"
  (cd sub && TMPDIR=../.git/rt assert_exit 0 "$BIN")
}

t_credential_rules_read_a_type_changed_config() {
  # .leakcheckrc a symlink in the index and a file on disk: `git commit -a`
  # publishes the file, a token in it included. Its own pattern lines are
  # still not reported.
  local gh
  gh=$(cred github-token)
  ln -s elsewhere .leakcheckrc
  git add .leakcheckrc
  commit init
  rm .leakcheckrc
  printf '%s\n' 'pattern MYHOST' "# k=$gh" > .leakcheckrc
  assert_exit 1 "$BIN"
  assert_contains ".leakcheckrc:2: [credential:github-token] $(masked "$gh")" "$LC_OUT"
  assert_not_contains "[MYHOST]" "$LC_OUT"
  assert_contains "leakcheck: 1 match(es)" "$LC_ERR"
}

t_history_merge_lines_under_combined_diff_merges() {
  # A line only a merge adds — an evil merge's resolution — is published by
  # that merge. log.diffMerges=combined made git print it in a format the
  # parser skipped, exit 0.
  seed a.txt "base"
  commit base
  git checkout -q -b side
  seed b.txt "side"
  commit side
  git checkout -q dev
  seed c.txt "main"
  commit main
  git -c core.hooksPath=/dev/null merge -q --no-ff --no-commit side >/dev/null 2>&1
  printf 'see /home/alice/x\n' >> a.txt
  git add a.txt
  commit merge
  local m; m=$(sha_of)
  git rm -q a.txt
  commit scrub
  local cfg="$PWD/.git/dm.cfg" mode
  for mode in combined dense-combined; do
    printf '[log]\n\tdiffMerges = %s\n' "$mode" > "$cfg"
    GIT_CONFIG_GLOBAL="$cfg" assert_exit 1 "$BIN" --history
    assert_contains "$m:a.txt:2: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] see /home/alice/x" "$LC_OUT"
  done
  rm -f "$cfg"
}

t_history_submodule_under_diff_submodule_log() {
  # Guard (v0.10.0 passes too, by skipping what it does not read): under
  # diff.submodule=log a gitlink's diff is a `Submodule` summary, which the
  # parser now refuses, so the history pass pins the short form, and a
  # commit holding a gitlink still scans as ever.
  local z; printf -v z '%040d' 1
  git update-index --add --cacheinfo "160000,$z,sub"
  seed a.txt "see /home/alice/x"
  commit init
  local c; c=$(sha_of)
  local cfg="$PWD/.git/sm.cfg"
  printf '[diff]\n\tsubmodule = log\n' > "$cfg"
  GIT_CONFIG_GLOBAL="$cfg" assert_exit 1 "$BIN" --history
  assert_contains "$c:a.txt:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] see /home/alice/x" "$LC_OUT"
}

t_config_rule_ending_in_whitespace_is_refused() {
  # `pattern MYHOST ` misses `MYHOST.`: the trailing blank is part of the
  # regex and invisible in an editor.
  seed a.txt "deploys to MYHOST."
  rc_file 'pattern MYHOST '
  commit init
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: pattern 'MYHOST ' ends in whitespace" "$LC_ERR"
  printf '%s\n' 'pattern MYHOST' $'allow a\\.txt\t' > .leakcheckrc
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:2: allow" "$LC_ERR"
  assert_contains "ends in whitespace" "$LC_ERR"
  rc_file 'pattern MYHOST[ ]'
  assert_exit 0 "$BIN"
}

t_config_rule_matching_the_empty_string_is_refused() {
  # An allow rule matching the empty string matches somewhere in every
  # hit's `path:line:match`, so it excused every hit, exit 0; a pattern
  # matching it flags every line.
  seed a.txt "see /home/alice/x on MYHOST"
  rc_file 'pattern MYHOST' 'allow docs\.example\.com|'
  commit init
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:2: allow 'docs\.example\.com|' matches the empty string, so it would excuse every hit" "$LC_ERR"
  rc_file 'pattern MYHOST' 'allow (fixtures/)?'
  assert_exit 2 "$BIN"
  assert_contains "matches the empty string" "$LC_ERR"
  rc_file 'pattern MYHOST' 'allow (?i)x*'
  assert_exit 2 "$BIN"
  assert_contains "matches the empty string" "$LC_ERR"
  rc_file 'pattern MYHOST|'
  assert_exit 2 "$BIN"
  assert_contains ".leakcheckrc:1: pattern 'MYHOST|' matches the empty string, so it would flag every line" "$LC_ERR"
  # An anchor alone is not the empty string on its own.
  rc_file 'pattern MYHOST' 'allow ^fixtures/'
  assert_exit 1 "$BIN"
}

t_config_rule_matching_the_empty_string_beside_a_word_is_refused() {
  # No empty line shows these: each matches the empty string only next to
  # a word character or a word's edge, which every hit's path:line:match
  # holds, so it excused every hit, exit 0.
  seed a.txt "see /home/alice/x on MYHOST"
  commit init
  local r
  for r in '\b(docs|)\b' '\<' '\b' 'a|\b' '\B' '(?i)\>' '\b(docs|)\1\b' '(x|)\1\b' 'x[]|]|\b' '(docs|\>)'; do
    rc_file 'pattern MYHOST' "allow $r"
    assert_exit 2 "$BIN"
    assert_contains ".leakcheckrc:2: allow '$r' matches the empty string, so it would excuse every hit" "$LC_ERR"
  done
  rc_file 'pattern \bx?\b'
  assert_exit 2 "$BIN"
  assert_contains "pattern '\bx?\b' matches the empty string, so it would flag every line" "$LC_ERR"
  # A boundary around something is a rule, a backreference keeps its number
  # in the probes, each alternative gets its own context (unsplit, `qq|d`
  # would read as `…qq` or `d$`), and a `|` escaped, in brackets or in a
  # class bracket is not an alternative.
  rc_file 'pattern MYHOST' 'allow \bdocs\b' 'allow (MY)\1' 'allow (zz)|(yy)\2' 'allow qq|d' \
    'allow [|]\b' 'allow x\|\b' 'allow [[:alpha:]|]zz'
  assert_exit 1 "$BIN"
}

t_config_rule_with_an_invisible_unicode_space_is_refused() {
  # A copy from a rendered page brings a no-break or zero-width space that
  # [[:space:]] does not see; trailing, it narrowed `pattern MYHOST` to miss
  # `MYHOST.`, exit 0.
  seed a.txt "deploys to MYHOST."
  commit init
  local b
  for b in $'\xc2\xa0' $'\xe2\x80\x8b' $'\xef\xbb\xbf'; do
    rc_file "pattern MYHOST$b"
    LC_ALL=C.UTF-8 assert_exit 2 "$BIN"
    assert_contains "begins or ends in an invisible Unicode space" "$LC_ERR"
    LC_ALL=C assert_exit 2 "$BIN"
    rc_file "pattern ${b}MYHOST"
    LC_ALL=C.UTF-8 assert_exit 2 "$BIN"
    assert_contains "begins or ends in an invisible Unicode space" "$LC_ERR"
  done
}

t_history_range_tag_on_a_blob_or_tree() {
  # The README's pre-push hook passes a new ref's own id as the range, and
  # a tag on a blob or a tree is in no range a walk lists: it went out
  # clean, 0 refs.
  seed f.txt "x"
  commit one
  local blob tree tag
  blob=$(printf 'deployed\n' | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tf\n' "$blob" | git mktree)
  git tag deploy-MYHOST "$blob"
  git tag -a -m "tree built on MYHOST" treetag "$tree"
  tag=$(git rev-parse treetag)
  rc_file 'pattern MYHOST'
  commit two
  assert_exit 1 "$BIN" --history-range "$blob"
  assert_contains "$blob:(ref):0: [MYHOST] refs/tags/deploy-MYHOST" "$LC_OUT"
  assert_contains "1 refs, 0 annotated tags, 1 tagged trees or blobs not scanned" "$LC_ERR"
  assert_exit 1 "$BIN" --history-range "$tag"
  assert_contains "$tag:(tag message):1: [MYHOST] tree built on MYHOST" "$LC_OUT"
  assert_not_contains "deploy-MYHOST" "$LC_OUT"
  # The object itself as the range: the tag on it is the ref that carries it.
  assert_exit 1 "$BIN" --history-range "$tree"
  assert_contains "$tag:(tag message):1: [MYHOST] tree built on MYHOST" "$LC_OUT"
  # A range that names no tip of theirs still leaves them out.
  assert_exit 0 "$BIN" --history-range "HEAD~1..HEAD"
  assert_contains "1 refs, 0 annotated tags, 0 tagged trees or blobs not scanned" "$LC_OUT"
}

t_history_signed_tag_a_merge_carries() {
  # Merging a signed tag copies the whole tag into the merge commit's
  # header (mergetag); the push publishes it with no tag ref, and its
  # tagger never reaches the commit's own fields: clean, exit 0.
  rc_file 'pattern MYHOST'
  seed f.txt "x"
  commit one
  git checkout -q -b side
  seed s.txt "s"
  commit side
  local tg m
  tg=$(printf 'object %s\ntype commit\ntag v1-rc\ntagger bob <bob@MYHOST.example> 1700000000 +0000\n\nrelease candidate built on MYHOST\n-----BEGIN PGP SIGNATURE-----\n\nc2lnbmF0dXJl\n-----END PGP SIGNATURE-----\n' "$(sha_of)" | git mktag)
  git checkout -q dev
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false merge -q --no-ff -m "Merge release candidate" "$tg" >/dev/null 2>&1
  git branch -q -D side
  m=$(sha_of)
  git cat-file -p HEAD | grep -q '^mergetag ' || { echo "    git recorded no mergetag"; return 1; }
  assert_exit 1 "$BIN" --history
  assert_contains "$m:(tagger):0: [MYHOST] bob <bob@MYHOST.example>" "$LC_OUT"
  assert_contains "$m:(tag message):1: [MYHOST] release candidate built on MYHOST" "$LC_OUT"
}

t_history_big_file_under_a_small_threshold() {
  # core.bigFileThreshold makes `log -p` print a larger file as binary: a
  # removed source map's home path went to "binary files skipped", exit 0.
  python3 -c 'print("{\"sources\":[\"/home/alice/src/app.ts\"],\"x\":\"" + "a" * 4000 + "\"}")' > app.js.map
  git add app.js.map
  commit one
  git rm -q app.js.map
  commit two
  local cfg="$PWD/.git/bft.cfg"
  printf '[core]\n\tbigFileThreshold = 1k\n' > "$cfg"
  GIT_CONFIG_GLOBAL="$cfg" assert_exit 1 "$BIN" --history
  assert_contains "app.js.map:1: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/]" "$LC_OUT"
  assert_contains "0 binary files skipped" "$LC_ERR"
  rm -f "$cfg"
}

t_history_metadata_under_another_log_encoding() {
  # i18n.logOutputEncoding re-encodes what the metadata pass reads: UTF-16
  # split its NUL framing, and Latin-1 hid a non-ASCII username.
  seed f.txt "x"
  git -c user.email=ops@MYHOST.example commit -q -m "see /home/zoë/x" --no-verify
  rc_file 'pattern MYHOST'
  commit two
  local cfg="$PWD/.git/enc.cfg" enc
  for enc in UTF-16LE ISO-8859-1; do
    printf '[i18n]\n\tlogOutputEncoding = %s\n' "$enc" > "$cfg"
    GIT_CONFIG_GLOBAL="$cfg" LC_ALL=C.UTF-8 assert_exit 1 "$BIN" --history
    assert_contains "(author):0: [MYHOST] t <ops@MYHOST.example>" "$LC_OUT"
    assert_contains "(message):1: [/(home|Users)/" "$LC_OUT"
  done
  rm -f "$cfg"
}

t_history_pathspec_env_cannot_hide_a_local_config() {
  # GIT_LITERAL_PATHSPECS=1 read `:(literal).leakcheckrc.local` as a file
  # of that name, so a .leakcheckrc.local in history went unreported.
  seed f.txt "x"
  printf 'pattern ^SECRET-[0-9]+$\n' > .leakcheckrc.local
  git add .leakcheckrc.local
  commit one
  git rm -q --cached .leakcheckrc.local
  commit two
  GIT_LITERAL_PATHSPECS=1 assert_exit 1 "$BIN" --history
  assert_contains ".leakcheckrc.local:0: [config:local-in-history]" "$LC_OUT"
}

t_default_finds_a_latin1_username_in_a_utf8_locale() {
  # In a Latin-1 file ë is one byte, which no UTF-8 regex reads as a
  # character: /home/zoë/ was clean under UTF-8 and found under C.
  printf '/home/zo\xeb/x\n' > a.txt
  git add a.txt
  commit init
  LC_ALL=C.UTF-8 assert_exit 1 "$BIN"
  assert_contains "a.txt:1: [/(home|Users)/" "$LC_OUT"
}

t_skip_cannot_hide_a_tracked_local_config() {
  # `skip .leakcheckrc*` listed the tracked .leakcheckrc.local away before
  # it could be reported: clean, exit 0.
  seed f.txt "x"
  printf 'pattern ZZZ-UNUSED\n' > .leakcheckrc.local
  git add .leakcheckrc.local
  rc_file 'skip .leakcheckrc*'
  commit init
  assert_exit 1 "$BIN"
  assert_contains ".leakcheckrc.local:0: [config:local-tracked]" "$LC_OUT"
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
lc_test "history: a conflict's resolution (remerge)"  t_history_remerge_conflict_resolution
lc_test "history: a line only an octopus adds"       t_history_octopus_merge_line
lc_test "history: merges without remerge (-m)"       t_history_merges_without_remerge
lc_test "history: merge drivers and remerge"         t_history_remerge_and_merge_drivers
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
lc_test "allow: another pattern's hit survives"       t_allow_does_not_hide_another_patterns_hit
lc_test "allow: a second match survives"              t_allow_does_not_hide_a_second_match
lc_test "allow: overlap excuses a match"              t_allow_overlap_excuses_a_match_it_is_part_of
lc_test "allow: a location rule allows all there"     t_allow_location_rule_allows_everything_there
lc_test "allow: adjacent match, non-ASCII path"       t_allow_adjacent_match_behind_a_non_ascii_path
lc_test "allow: in a name with a newline"             t_allow_in_a_name_with_a_newline
lc_test "allow: every match allowed is allowed"       t_allow_every_match_allowed_is_allowed
lc_test "allow: a partial-line rule excuses nothing"  t_allow_partial_line_rule_excuses_nothing
lc_test "allow: whole line means every line"          t_allow_whole_line_means_every_line
lc_test "allow: credit goes to the lowest rule"       t_allow_credit_goes_to_the_lowest_rule
lc_test "history: ref names"                          t_history_ref_names
lc_test "history: annotated tag"                      t_history_annotated_tag
lc_test "history: nested tag"                         t_history_nested_tag
lc_test "history: tagged blob counted, --strict"      t_history_tagged_blob_counted_and_strict
lc_test "history: refs with no commits"            t_history_refs_with_no_commits
lc_test "history range: refs in the range only"       t_history_range_refs_in_range_only
lc_test "history: tag holding NUL bytes"             t_history_tag_holding_nul_bytes
lc_test "(?i): pattern in the tree"                   t_ignorecase_pattern_in_the_tree
lc_test "(?i): pattern in history"                    t_ignorecase_pattern_in_history
lc_test "(?i): allow rules"                           t_ignorecase_allow
lc_test "(?i): alone is refused"                      t_ignorecase_alone_is_refused
lc_test "(?i): only at the start"                     t_ignorecase_only_at_the_start
lc_test "credentials: every rule, its own format"     t_credential_every_rule_finds_its_own_format
lc_test "credentials: every tree source"              t_credential_in_every_tree_source
lc_test "credentials: every history source"           t_credential_in_every_history_source
lc_test "credentials: placeholders counted"           t_credential_placeholders_are_counted_not_reported
lc_test "credentials: a placeholder excuses itself"   t_credential_placeholder_excuses_only_itself
lc_test "credentials: no-credentials"                 t_credential_no_credentials_directive
lc_test "credentials: --list-patterns appends"        t_credential_list_patterns_appends_the_rules
lc_test "credentials: a label is not a pattern"       t_credential_label_cannot_be_a_pattern
lc_test "credentials: allow sees the real text"       t_credential_allow_rules_see_the_real_text
lc_test "credentials: in the committed config"        t_credential_in_the_committed_config
lc_test "credentials: a PEM header needs a key"       t_credential_private_key_needs_a_key_after_its_header
lc_test "credentials: other hits keep their text"     t_credential_other_hits_keep_their_text
lc_test "credentials: a key is never a placeholder"    t_credential_private_key_is_never_a_placeholder
lc_test "credentials: zero bytes are not a run"       t_credential_zero_bytes_are_not_a_placeholder_run
lc_test "credentials: base64url JWT header"           t_credential_jwt_header_in_base64url
lc_test "credentials: Hugging Face token with digits" t_credential_huggingface_token_with_digits
lc_test "credentials: masked wherever a name prints"  t_credential_in_a_name_is_masked_wherever_the_name_prints
lc_test "credentials: masked in a JSON allow rule"    t_credential_in_an_allow_rule_is_masked_in_json
lc_test "credentials: a type-changed config"          t_credential_rules_read_a_type_changed_config
lc_test "credentials: JSON-escaped slashes"        t_credential_json_escaped_slashes
lc_test "credentials: a key written as a regex"     t_credential_allow_rule_written_as_regex_is_masked
lc_test "credentials: a key split by regex groups"  t_credential_allow_rule_key_split_by_groups_is_masked
lc_test "credentials: two keys, found two ways"     t_credential_allow_rule_keys_found_two_ways_are_both_masked
lc_test "credentials: a key inside a key"           t_credential_allow_rule_key_inside_a_key_is_masked
lc_test "credentials: a private key to its end"     t_credential_allow_rule_private_key_is_masked_to_its_end
lc_test "credentials: keys back to back"            t_credential_allow_rule_back_to_back_keys_are_masked
lc_test "credentials: a disabled rule masks names"  t_credential_disabled_rule_still_masks_names
lc_test "config errors never echo a key"            t_config_errors_never_echo_a_key_for_a_rule_id
lc_test "config errors mask a key in the regex"     t_config_errors_mask_a_key_in_the_regex
lc_test "scan errors mask a key in a path"          t_scan_errors_mask_a_key_in_a_path
lc_test "a failed error mask prints nothing"        t_error_masking_failure_prints_nothing_of_the_message
lc_test "error masking ignores the caller's git"    t_error_masking_runs_apart_from_the_callers_git
lc_test "no patterns at all is an error"            t_no_patterns_is_an_error
lc_test "command-line errors mask a key"            t_command_line_errors_mask_a_key
lc_test "credentials: overlapping keys in a name"   t_credential_overlapping_keys_in_a_name_are_masked
lc_test "credentials: deepseek-key left edge"       t_credential_deepseek_key_has_a_left_edge
lc_test "credentials: an edge is not in the mask"   t_credential_left_edge_is_not_masked_in_a_name
lc_test "credentials: webhook URLs stop at segments" t_credential_webhook_urls_stop_at_their_segments
lc_test "credentials: issuer-documented variants"   t_credential_issuer_variants
lc_test "credentials: zero bytes are no AWS/FB key" t_credential_zero_bytes_are_no_aws_or_facebook_key
lc_test "credentials: PGP secret and SSH2 headers"  t_credential_pgp_secret_and_ssh2_headers
lc_test "credentials: GitHub's checksum"            t_credential_github_checksum
lc_test "credentials: pkcs12-file, by name only"    t_credential_pkcs12_file
lc_test "credentials: pkcs12-file, a whole name"   t_credential_pkcs12_file_ends_a_whole_name
lc_test "credentials: a tail after a body's slash"  t_credential_tail_after_a_slash_in_a_body
lc_test "credentials: a glued tail is no stand-in"  t_credential_glued_tail_is_no_stand_in
lc_test "a hit on a 1.2 MB line, quickly"         t_long_line_hit_is_quick
lc_test "a 400 KB credential match, quickly"     t_long_credential_match_is_quick
lc_test "keyword rules: unprefixed secrets"       t_kv_rules_find_unprefixed_secrets
lc_test "keyword rules: weak values counted"      t_kv_weak_values_are_counted
lc_test "keyword rules: yield to a fixed rule"    t_kv_rules_yield_to_a_fixed_format_rule
lc_test "keyword rules: yield to a key run into"  t_kv_rules_yield_to_a_key_they_run_into
lc_test "keyword rules: yield by position"       t_kv_rules_yield_by_position_not_text
lc_test "keyword rules: a crowded line, quickly"  t_kv_overlaps_on_a_crowded_line_are_quick
lc_test "keyword rules: overlaps judged in place" t_kv_overlap_edges_are_judged_at_their_place
lc_test "a caller's shell settings stay outside"  t_caller_shell_settings_do_not_reach_the_scan
lc_test "keyword rules: masked where they print"  t_kv_values_are_masked_where_they_print
lc_test "keyword rules: URL sub-delims"          t_kv_url_password_takes_rfc3986_sub_delims
lc_test "keyword rules: a dotted token is no name" t_kv_dotted_token_is_no_name
lc_test "keyword rules: HTTP authentication"     t_kv_http_auth_rules
lc_test "keyword rules: the weaker names"       t_kv_generic_key_names
lc_test "credentials: issuer-sourced, v0.19.0"   t_credential_issuer_sourced_v019
lc_test "credentials: v0.19.0 near misses clean" t_credential_issuer_sourced_near_misses_are_clean
lc_test "credentials: v0.29.0 near misses clean" t_credential_v029_near_misses_are_clean
lc_test "keyword rules: a service's name"       t_kv_service_names
lc_test "keyword rules: code is no key"          t_kv_code_identifiers_are_weak
lc_test "label: a pattern prints its name"       t_label_pattern_prints_its_name
lc_test "config from the environment"            t_config_from_environment
lc_test "--redact hides every hit's text"        t_redact_hides_every_hit_text
lc_test "--rule runs only the named rules"      t_rule_runs_only_named_rules
lc_test "--format sarif"                        t_format_sarif
lc_test "--format csv"                          t_format_csv
lc_test "--format junit"                        t_format_junit
lc_test "--format: json, text, errors"          t_format_flag
lc_test "--baseline: only new findings"         t_baseline_reports_only_new_findings
lc_test "--baseline: errors"                    t_baseline_errors
lc_test "--dir: every file under a directory"   t_dir_scans_every_file
lc_test "--stdin"                               t_stdin_scans_input
lc_test "--decode: base64, hex, percent"        t_decode_finds_encoded_values
lc_test "--archives: zip, tar, gzip"            t_archives_read_members
lc_test "--archives: what they publish"       t_archives_read_what_they_publish
lc_test "--dir: paths named .git counted"     t_dir_counts_paths_named_git
lc_test "--decode: past prefixes, in copies"  t_decode_reads_past_prefixes
lc_test "credentials: random camel values are keys" t_kv_random_camel_values_are_keys
lc_test "credentials: Basic auth's user judged" t_kv_basic_auth_user_is_judged
lc_test "--redact: tells in credential text" t_redact_hides_tells_in_credential_text
lc_test "credentials: cut only past an edge" t_credential_cut_only_past_an_edge
lc_test "--baseline: unscanned content" t_baseline_holds_unscanned_content
lc_test "--format junit: XML noncharacters" t_junit_drops_xml_noncharacters
lc_test "history: a user's text driver, -m" t_history_text_driver_sends_merges_to_m
lc_test "credentials: a quoted value is no call" t_kv_quoted_value_is_no_call
lc_test "credentials: opened and slashed rules" t_credential_opened_and_slashed_rules_judge_the_key
lc_test "--archives: raw bytes compared" t_archives_compare_raw_bytes
lc_test "--decode: every path part tried" t_decode_tries_every_path_part
lc_test "credentials: a long value masked whole" t_kv_long_value_is_masked_whole
lc_test "--redact: --list-patterns" t_redact_list_patterns_hides_plain_patterns
lc_test "--rule: a path rule alone" t_rule_path_rule_alone_scans
lc_test "--baseline: a line moved in one copy" t_baseline_counts_each_copy_apart
lc_test "--baseline: an archive member's content" t_baseline_holds_a_member_s_content
lc_test "pre-commit hook and GitHub Action"     t_integrations_run_leakcheck
lc_test "credentials: (?i) out of the literal form" t_credential_allow_rule_case_prefix_is_dropped_from_the_literal_form
lc_test "allow: an unscoped rule never a credential" t_allow_unscoped_never_excuses_a_credential
lc_test "allow: unscoped rule and a stand-in"        t_allow_unscoped_and_a_placeholder
lc_test "allow: a scope excuses only its rule"       t_allow_credential_scope_excuses_only_its_rule
lc_test "allow: a scope in history"                  t_allow_credential_scope_in_history
lc_test "allow: a scope on a whole line"             t_allow_credential_scope_whole_line
lc_test "allow: scope errors"                        t_allow_credential_scope_errors
lc_test "disable: one credential rule"               t_disable_one_credential_rule
lc_test "--list-rules"                               t_list_rules
lc_test "history: merge lines, combined diffMerges"   t_history_merge_lines_under_combined_diff_merges
lc_test "history: submodule, diff.submodule=log"     t_history_submodule_under_diff_submodule_log
lc_test "config: trailing whitespace refused"         t_config_rule_ending_in_whitespace_is_refused
lc_test "config: empty-string rule refused"           t_config_rule_matching_the_empty_string_is_refused
lc_test "config: empty match beside a word refused"   t_config_rule_matching_the_empty_string_beside_a_word_is_refused
lc_test "config: invisible Unicode space refused"     t_config_rule_with_an_invisible_unicode_space_is_refused
lc_test "history range: tag on a blob or tree"        t_history_range_tag_on_a_blob_or_tree
lc_test "history: a signed tag a merge carries"       t_history_signed_tag_a_merge_carries
lc_test "history: big file, small threshold"          t_history_big_file_under_a_small_threshold
lc_test "history: metadata, other log encoding"       t_history_metadata_under_another_log_encoding
lc_test "history: pathspec env, local config"         t_history_pathspec_env_cannot_hide_a_local_config
lc_test "default: Latin-1 username, UTF-8 locale"     t_default_finds_a_latin1_username_in_a_utf8_locale
lc_test "skip cannot hide a tracked .local"           t_skip_cannot_hide_a_tracked_local_config

echo
echo "  $PASS passed  ·  $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0

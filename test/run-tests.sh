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
# Stand-in credentials, one per built-in credential rule, built at run time
# from a fixed seed: this file is public, and is scanned by leakcheck and by
# other scanners, so it holds no token, nor anything a credential rule
# matches. Each row: rule id, a line holding the stand-in, the exact match.
CRED_TSV="$(mktemp -t lc-cred.XXXXXX)"
trap 'rm -f "$LC_OUT" "$LC_ERR" "$CRED_TSV"' EXIT
python3 - > "$CRED_TSV" <<'PY'
import random
r = random.Random(20261105)
CS = {
    "an": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    "an-_": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
    "an_": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_",
    "UD": "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "a": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    "d": "0123456789",
    "hex": "0123456789abcdef",
    "b64": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
    "bech": "QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L",
    "lan": "abcdefghijklmnopqrstuvwxyz0123456789",
}
def stand_in_ok(s):
    # Never a placeholder shape: those are excused (and tested on their own).
    for i in range(len(s) - 7):
        w = s[i:i + 8]
        if len(set(w)) == 1 or all(ord(w[k + 1]) == ord(w[k]) + 1 for k in range(7)):
            return False
    return "EXAMPLE" not in s and "example" not in s
def gen(spec):
    while True:
        s = "".join(p if isinstance(p, str) else "".join(r.choice(CS[p[0]]) for _ in range(p[1])) for p in spec)
        if stand_in_ok(s):
            return s
GUID = [("hex", 8), "-", ("hex", 4), "-", ("hex", 4), "-", ("hex", 4), "-", ("hex", 12)]
# id: (text before the match on its line, the match's parts)
SPECS = {
 "private-key": ("KEY=", ["-----BEGIN RSA ", "PRIVATE KEY-----"]),
 "putty-private-key": ("", ["PuTTY-User-", "Key-File-3:"]),
 "aws-access-key-id": ("KEY=", ["AK", "IA", ("UD", 16)]),
 "github-token": ("KEY=", ["gh", "p_", ("an", 36)]),
 "github-fine-grained-token": ("KEY=", ["github", "_pat_", ("an_", 82)]),
 "gitlab-token": ("KEY=", ["gl", "pat-", ("an-_", 20)]),
 "slack-token": ("KEY=", ["xo", "xb-", ("d", 12), "-", ("d", 13), "-", ("an", 24)]),
 "slack-webhook": ("URL=https://", ["hooks", ".slack.com/services/T", ("UD", 10), "/B", ("UD", 10), "/", ("an", 24)]),
 "discord-webhook": ("URL=https://", ["discord", ".com/api/webhooks/", ("d", 18), "/", ("an-_", 68)]),
 "teams-webhook": ("URL=https://acme", [".webhook", ".office.com/webhookb2/"] + GUID + ["@"] + GUID + ["/IncomingWebhook/", ("hex", 32), "/"] + GUID),
 "stripe-key": ("KEY=", ["sk", "_live_", ("an", 24)]),
 "webhook-signing-secret": ("KEY=", ["wh", "sec_", ("an", 32)]),
 "google-api-key": ("KEY=", ["AI", "za", ("an-_", 35)]),
 "google-oauth-client-secret": ("KEY=", ["GOC", "SPX-", ("an-_", 28)]),
 "anthropic-key": ("KEY=", ["sk-", "ant-api03-", ("an-_", 93), "AA"]),
 "openai-key": ("KEY=", ["sk-", "proj-", ("an-_", 74), "T3BlbkFJ", ("an-_", 74)]),
 "openrouter-key": ("KEY=", ["sk-", "or-v1-", ("hex", 64)]),
 "deepseek-key": ("KEY=", ["sk", "-", ("hex", 32)]),
 "groq-key": ("KEY=", ["gs", "k_", ("an", 52)]),
 "perplexity-key": ("KEY=", ["pp", "lx-", ("an", 48)]),
 "xai-key": ("KEY=", ["xa", "i-", ("an", 80)]),
 "huggingface-token": ("KEY=", ["hf", "_", ("a", 34)]),
 "npm-token": ("KEY=", ["np", "m_", ("an", 36)]),
 "pypi-token": ("KEY=", ["pypi-", "AgEIcHlwaS5vcmc", ("an-_", 70)]),
 "rubygems-token": ("KEY=", ["ruby", "gems_", ("hex", 48)]),
 "clojars-token": ("KEY=", ["CLO", "JARS_", ("lan", 60)]),
 "sendgrid-key": ("KEY=", ["SG", ".", ("an-_", 22), ".", ("an-_", 43)]),
 "brevo-key": ("KEY=", ["xkey", "sib-", ("hex", 64), "-", ("an", 16)]),
 "mailchimp-key": ("KEY=", [("hex", 32), "-us", ("d", 2)]),
 "twilio-api-key": ("KEY=", ["S", "K", ("hex", 32)]),
 "digitalocean-token": ("KEY=", ["dop", "_v1_", ("hex", 64)]),
 "shopify-token": ("KEY=", ["shp", "at_", ("hex", 32)]),
 "jwt": ("KEY=", ["eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", ".", "eyJ", ("an", 40), ".", ("an-_", 43)]),
 "age-secret-key": ("KEY=", ["AGE-", "SECRET-KEY-1", ("bech", 58)]),
 "vault-token": ("KEY=", ["hv", "s.", ("an-_", 95)]),
 "terraform-cloud-token": ("KEY=", [("an", 14), ".atlas", "v1.", ("an-_", 67)]),
 "doppler-token": ("KEY=", ["dp", ".pt.", ("an", 43)]),
 "linear-api-key": ("KEY=", ["lin", "_api_", ("an", 40)]),
 "postman-api-key": ("KEY=", ["PM", "AK-", ("hex", 24), "-", ("hex", 34)]),
 "sentry-token": ("KEY=", ["sntr", "yu_", ("hex", 64)]),
 "grafana-token": ("KEY=", ["gl", "sa_", ("an", 32), "_", ("hex", 8)]),
 "databricks-token": ("KEY=", ["da", "pi", ("hex", 32)]),
 "atlassian-token": ("KEY=", ["ATA", "TT3", ("an-_", 186)]),
 "notion-token": ("KEY=", ["nt", "n_", ("d", 11), ("an", 35)]),
 "1password-token": ("KEY=", ["ops", "_eyJ", ("b64", 260)]),
 "facebook-token": ("KEY=", ["EA", "AC", ("an", 120)]),
 "square-token": ("KEY=", ["sq0", "csp-", ("an-_", 43)]),
 "pulumi-token": ("KEY=", ["pu", "l-", ("hex", 40)]),
 "planetscale-token": ("KEY=", ["pscale", "_tkn_", ("an", 43)]),
 "flyio-token": ("KEY=", ["fo", "1_", ("an-_", 43)]),
 "dynatrace-token": ("KEY=", ["dt0", "c01.", ("UD", 24), ".", ("an", 64)]),
 "tailscale-key": ("KEY=", ["tskey", "-auth-", ("an", 14), "-", ("an", 32)]),
 "heroku-key": ("KEY=", ["HRKU", "-AA", ("an-_", 58)]),
 "supabase-key": ("KEY=", ["sb", "p_", ("hex", 40)]),
 "azure-storage-key": ("X;", ["Account", "Key=", ("b64", 86), "=="]),
 "azure-ad-client-secret": ("KEY=", [("an", 3), ("d", 1), "Q", "~", ("an", 32)]),
 "new-relic-key": ("KEY=", ["NR", "AK-", ("UD", 27)]),
 "cloudflare-origin-ca-key": ("KEY=", ["v1", ".0-", ("hex", 24), "-", ("hex", 146)]),
 "mapbox-secret-token": ("KEY=", ["sk", ".eyJ1", ("an-_", 80)]),
}
for cid, (before, spec) in SPECS.items():
    m = gen(spec)
    print(cid, before + m, m, sep="\t")
PY

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
assert doc["history"] == {"commits": 2, "binary": 0, "skipped": 0, "config_lines_exempt": 0, "range": None, "refs": 1, "tags": 0, "tagged_unscanned": 0}, doc
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
  python3 - "$LC_OUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["clean"] is True, doc
assert doc["history"] == {"commits": 1, "binary": 0, "skipped": 0, "config_lines_exempt": 0, "range": "HEAD~1..HEAD", "refs": 1, "tags": 0, "tagged_unscanned": 0}, doc
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
  git add .
  commit init
  assert_exit 1 "$BIN" --json
  cp "$LC_OUT" .git/cred.json
  # Each file is one hit, of its own rule only, printed masked; the count of
  # rules is the count of stand-ins, so a rule added without one fails here.
  python3 - .git/cred.json "$CRED_TSV" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
markers = {"private-key", "putty-private-key"}
by = {}
for h in doc["hits"]:
    by.setdefault(h["file"], []).append(h)
assert doc["credentials_scanned"] is True and doc["credentials"] == {"rules": len(rows), "placeholders": 0}, doc["credentials"]
assert list(doc)[-2:] == ["credentials_scanned", "credentials"], list(doc)
for cid, line, m in rows:
    hs = by.pop(cid + ".txt", [])
    want = m if cid in markers else "%s[redacted, %d chars]" % (m[:4], len(m))
    assert [(h["pattern"], h["text"]) for h in hs] == [("credential:" + cid, want)], (cid, hs)
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
  # Seven in a row, equal or counting up, is not a placeholder.
  printf '%s\n' "g=gh""p_${r:4:29}XXXXXXX" "h=np""m_${r:4:29}1234567" > q.txt
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
  local n; n=$(wc -l < "$CRED_TSV")
  # Defaults, then the config's patterns, then one ERE per credential rule:
  # what earlier versions printed stays a prefix.
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
  rc_file "allow $gh"
  commit init
  assert_exit 0 "$BIN"
  assert_contains "2 allowed" "$LC_OUT"
  rc_file "allow ^a\\.txt:1:k=$gh\$"
  assert_exit 1 "$BIN"
  assert_contains "1 allowed" "$LC_ERR"
  assert_contains ".leakcheckrc:1: [credential:github-token]" "$LC_OUT"
  rc_file "allow $other"
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
  rc_file "allow $gh" "allow $aws"
  commit init
  assert_exit 0 "$BIN" --json
  assert_not_contains "$gh" "$LC_OUT"
  python3 -c '
import json, sys
a = [r["rule"] for r in json.load(open(sys.argv[1]))["allowed"]]
assert a == sys.argv[2:], a' \
    "$LC_OUT" "$(masked "$gh")" "$aws"
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
  for r in '\b(docs|)\b' '\<' '\b' 'a|\b' '\B' '(?i)\>'; do
    rc_file 'pattern MYHOST' "allow $r"
    assert_exit 2 "$BIN"
    assert_contains ".leakcheckrc:2: allow '$r' matches the empty string, so it would excuse every hit" "$LC_ERR"
  done
  rc_file 'pattern \bx?\b'
  assert_exit 2 "$BIN"
  assert_contains "pattern '\bx?\b' matches the empty string, so it would flag every line" "$LC_ERR"
  # A boundary around something is a rule, and a backreference keeps its
  # number (the probes are skipped for it).
  rc_file 'pattern MYHOST' 'allow \bdocs\b' 'allow (MY)\1'
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

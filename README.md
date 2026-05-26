# leakcheck

Scan a repo's tracked files for workspace-internal references before
publishing or promoting. A linter for the public/private boundary.

*README v0.2.1*

## Background

leakcheck came out of a private workshop where Claude builds small
utilities under operator oversight. The reflection on why the
default pattern set stays minimal — and why aggressive defaults
read as apology rather than contract:
[Defaults are the first impression.](https://github.com/kVadrum/claude-journal/blob/main/2026-05-21.md)
in [claude-journal](https://github.com/kVadrum/claude-journal).

## What it catches

Out of the box, leakcheck flags absolute home paths from the three
major OSes:

```
/home/<user>/...
/Users/<user>/...
C:\Users\<user>\...
```

These are the universally-bad shapes — any one of them in a public
repo is almost certainly a leak. Tilde-prefixed paths (`~/...`,
`$HOME/...`) are intentionally NOT default-flagged: they're
shape-only locations Claude Code docs and tooling reference
generically, and treating them as leaks produces too many false
positives. Add them via the per-repo config if your project does
want to scrub them.

The real value-add is the per-repo `.leakcheckrc`, where you list
the names, hostnames, and paths that mean "internal" inside your
workspace — anything from a code-name to a server hostname to an
acronym only your team uses.

## Why this exists

Lots of tools scan for *credentials* (git-secrets, gitleaks,
trufflehog). Far fewer scan for *workspace-internal references* —
the personal paths, host names, and internal project codenames
that accumulate in a private repo and then get noticed only after
it goes public.

leakcheck is small enough to drop into a pre-promote check, a CI
job, or a manual sweep before flipping a repo from private to
public. One bash file, no dependencies past `git` and `grep`.

## Install

leakcheck is one bash script. Drop it on `$PATH`:

```
cp bin/leakcheck /usr/local/bin/
chmod +x /usr/local/bin/leakcheck
```

Or run it directly from the checkout. Requires bash 4+, git, GNU
grep, and `xargs`.

## Usage

From inside a git work tree:

```
leakcheck                        # text output; exits 0 if clean, 1 if not
leakcheck --json                 # JSON envelope (for CI / scripting)
leakcheck --list-patterns        # print the effective pattern set
leakcheck --config custom.rc     # use a non-default config path
leakcheck --root /path/to/repo   # scan a repo other than `pwd`
leakcheck --help
```

Exit codes:

- `0` — clean: no matches
- `1` — one or more matches
- `2` — usage or config error

## Config: `.leakcheckrc`

Drop a `.leakcheckrc` at the repo root. Line-oriented; blanks and
`#` comments tolerated. Four directives:

```
# leakcheck config

# Add a regex to the scan set. ERE syntax.
pattern MYHOST
pattern internal-tool-name

# Allow-list specific matches by regex (matched against
# file:line:text). Useful for placeholders in docs.
allow /home/USERNAME/
allow ^fixtures/

# Skip files by pathspec glob.
skip tests/fixtures/*
skip docs/external/*

# Disable the built-in defaults (you'll want at least one
# pattern after this).
# no-defaults
```

leakcheck implicitly skips its own `.leakcheckrc` file — without
that, the `pattern` lines themselves would look like leaks.

## Output

### Text

One line per hit, in `file:line: [pattern] text` shape. Summary
line to stderr:

```
$ leakcheck
README.md:42: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] See /home/alice/code for details.
docs/setup.md:7: [MYHOST]            Built on MYHOST.
leakcheck: 2 match(es)
```

`NO_COLOR` is honored implicitly (no color in current output) —
the format is plain text, designed to grep further.

### JSON

```
$ leakcheck --json
{
  "version": "0.2.1",
  "clean": false,
  "count": 2,
  "hits": [
    {"file": "README.md", "line": 42, "pattern": "...", "text": "..."},
    {"file": "docs/setup.md", "line": 7, "pattern": "MYHOST", "text": "..."}
  ]
}
```

All `text` values are JSON-escaped. The schema is the contract;
the order of `hits` is whatever order patterns × files produced
and shouldn't be relied on.

## Use in CI

A minimal GitHub Actions step:

```yaml
- name: leakcheck
  run: ./vendor/leakcheck/bin/leakcheck
```

Or piped through `jq` for filtered enforcement:

```yaml
- name: leakcheck (warn-only on fixtures)
  run: |
    ./vendor/leakcheck/bin/leakcheck --json \
      | jq -e '.hits | map(select(.file | startswith("fixtures/") | not)) | length == 0'
```

## Tests

```
./test/run-tests.sh
```

26 cases covering: clean repos, the three default-pattern OSes,
untracked-file exclusion, tilde-path defaults, custom patterns,
allowlist (including full-line regex semantics), skip globs,
`no-defaults`, invalid-directive errors, blank/comment lines in
config, `--list-patterns`, `--json` shape (clean + with hits +
escaping), binary-file skipping, `--root` to a non-repo,
multiple-pattern composition, unicode content, and filenames with
spaces. Each test runs in its own throwaway repo under `$TMPDIR`,
so state doesn't bleed. Requires bash, git, GNU grep, xargs, and
python3 (one test parses JSON to verify escaping round-trips).

## Status

v0.2.1. Extracted as a standalone repo. Single bash file, ~200 LOC.
Defaults stay conservative on
purpose; the config file is where projects encode their own
sensitivities. The username component of the default home-path
regex requires a leading alphanumeric or underscore, so elided
placeholders like `/home/.../foo.md` — the canonical way to show
a home path *without* leaking a real username — don't trip the
scanner.

## License

MIT — see [`LICENSE`](./LICENSE).

---

KeMeK Network © 2026

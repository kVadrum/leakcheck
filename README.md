# leakcheck

Scan a repo's tracked files for workspace-internal references before publishing or promoting.
A linter for the public/private boundary.

*README v0.3.0*

## Background

leakcheck was conceived and written by Claude in claude-expo — a private workshop where Claude picks and builds small utilities under operator oversight.
Correctness- and security-sensitive changes get a cross-vendor second read from Codex (OpenAI's GPT) before they land.
The reflection on why the default pattern set stays minimal — and why aggressive defaults read as apology rather than contract: [Defaults are the first impression.](https://github.com/kVadrum/claude-journal/blob/main/2026-05-21.md) in [claude-journal](https://github.com/kVadrum/claude-journal).

## What it catches

Out of the box, leakcheck flags absolute home paths from the three major OSes:

```
/home/<user>/...
/Users/<user>/...
C:\Users\<user>\...
```

These are the universally-bad shapes — any one of them in a public repo is almost certainly a leak.
Tilde-prefixed paths (`~/...`, `$HOME/...`) are intentionally NOT default-flagged: they're shape-only locations Claude Code docs and tooling reference generically, and treating them as leaks produces too many false positives.
Add them via the per-repo config if your project does want to scrub them.

The real value-add is the per-repo `.leakcheckrc`, where you list the names, hostnames, and paths that mean "internal" inside your workspace — anything from a code-name to a server hostname to an acronym only your team uses.

## What it scans

The whole repository, from its top level, whichever subdirectory you run it in:

- **the index** — what the next commit publishes, including staged changes and files deleted from the worktree;
- **the worktree copy of every tracked file** — what `git commit -a` publishes, including unstaged edits and intent-to-add (`git add -N`) files;
- **every tracked path name** — `docs/notes-from-MYHOST.md` leaks in its name;
- **every tracked symlink target** — the stored target string is what a clone publishes;
- **type changes** — an index symlink or submodule replaced by a regular file is scanned as the file `git commit -a` would publish.

A hit found in both the index and the worktree is reported once.
A path or symlink target holding a newline is printed C-quoted (`"two\nlines.md":1: …`), so every hit stays one line; in JSON, bytes that are not valid UTF-8 become U+FFFD.

What it does not scan — and says so on every run:

- **Binary files** are skipped and counted; `--strict` reports each one as a match.
  Detection is by content alone, so a `.gitattributes` line such as `*.svg binary` does not hide a text file.
- **Submodule contents** belong to another repo; counted, and reported under `--strict`.
- **Git history and commit metadata.**
  A leak scrubbed today is still public in an old commit; every clean verdict says `history not scanned`.
- **Encoded or compressed content** (base64, gzip, archives).
  That is a credential scanner's job — see gitleaks.
- **Untracked and gitignored files**, which are not published.

## Why this exists

Lots of tools scan for *credentials* (git-secrets, gitleaks, trufflehog).
Far fewer scan for *workspace-internal references* — the personal paths, host names, and internal project codenames that accumulate in a private repo and then get noticed only after it goes public.

leakcheck is small enough to drop into a pre-promote check, a CI job, or a manual sweep before flipping a repo from private to public.
One bash file; it needs bash and git.

## Install

leakcheck is one bash script.
Drop it on `$PATH`:

```
cp bin/leakcheck /usr/local/bin/
chmod +x /usr/local/bin/leakcheck
```

Or run it directly from the checkout.
Requires bash 4.4 or newer (macOS's system bash is 3.2), git 2.19 or newer, and the standard `sed`, `tr`, `mktemp` and `readlink`.
On git older than 2.40, binary detection honours `.gitattributes`; files it skips that way are still counted.

## Usage

```
leakcheck                        # text output; exits 0 if clean, 1 if not
leakcheck --json                 # JSON envelope (for CI / scripting)
leakcheck --strict               # also report every unscanned file as a match
leakcheck --list-patterns        # print the effective pattern set
leakcheck --config custom.rc     # use a non-default config path
leakcheck --root /path/to/repo   # run as if started in another directory
leakcheck --help
```

A relative `--config` resolves against the directory leakcheck runs in — after `--root`, as with `git -C`.
Absolute paths work, inside the repo or outside it.
A `--config` that does not exist is an error, never a silent fallback to the defaults.

Exit codes:

- `0` — clean: no matches
- `1` — one or more matches
- `2` — usage, config or scan error (an invalid regex, an unreadable file, a missing config)

**Treat any non-zero exit as "do not publish."**
Never test for `1` and `2` alone.

## Config: `.leakcheckrc`

Drop a `.leakcheckrc` at the repo top level.
Line-oriented; blanks and `#` comments tolerated.
Four directives:

```
# leakcheck config

# Add a regex to the scan set. ERE syntax.
pattern MYHOST
pattern internal-tool-name

# Allow-list specific matches by regex (matched against
# path:line:text). Useful for placeholders in docs.
allow /home/USERNAME/
allow ^fixtures/

# Skip paths by pathspec glob, relative to the repo top level.
skip tests/fixtures/*
skip docs/external/*

# Disable the built-in defaults (you'll want at least one
# pattern after this).
# no-defaults
```

leakcheck implicitly skips its own config file when it lives inside the repo — without that, the `pattern` lines themselves would look like leaks.
Name and symlink hits carry line `0`, so an allow rule for one reads `^docs/notes-from-MYHOST\.md:0:`.
An empty `pattern`, `allow` or `skip` is an error: an empty `allow` would otherwise allow everything.

Your `.leakcheckrc` is an inventory of exactly what you are trying to hide.
In a repo that is or will be public, keep it out of git and pass it with `--config` from outside the repo, or keep only shape-based patterns in it.

## Output

### Text

One line per hit on stdout, in `path:line: [pattern] text` shape, then two summary lines on stderr:

```
$ leakcheck
README.md:42: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] See /home/alice/code for details.
docs/notes-from-MYHOST.md:0: [MYHOST] docs/notes-from-MYHOST.md
link:0: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] -> /home/alice/notes
leakcheck: 3 match(es)
leakcheck: scanned 120 tracked files (index + worktree; 2 binary skipped, 0 submodules not scanned, 1 skipped by config, 0 allowed; history not scanned)
```

A clean run prints one line on stdout, carrying the same scope:

```
leakcheck: clean — 0 matches across 120 tracked files (index + worktree; 2 binary skipped, 0 submodules not scanned, 1 skipped by config, 0 allowed; history not scanned)
```

`count` is matches, not lines: two patterns on one line are two hits.
The format is plain text with no color, designed to grep further.

### JSON

```
$ leakcheck --json
{
  "version": "0.3.0",
  "clean": false,
  "count": 2,
  "hits": [
    {"file": "README.md", "line": 42, "pattern": "...", "text": "...", "source": "both"},
    {"file": "docs/notes-from-MYHOST.md", "line": 0, "pattern": "MYHOST", "text": "docs/notes-from-MYHOST.md", "source": "index"}
  ],
  "target": "index+worktree",
  "tracked": 120,
  "skipped": {"binary": 2, "submodule": 0, "config": 1},
  "symlinks": 1,
  "allowed": [{"rule": "/home/USERNAME/", "count": 3}],
  "history_scanned": false
}
```

`source` says where a hit was found: `index`, `worktree`, or `both`.
`allowed` counts what each allow rule suppressed, so an over-broad rule is visible rather than indistinguishable from a clean repo.
All string values are JSON-escaped.
The schema is the contract, and new fields only ever append; the order of `hits` shouldn't be relied on.
On exit `2` nothing is printed on stdout, so a consumer that parses empty output fails closed.

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

76 cases covering the default patterns, config directives and their error paths, `--config` / `--root` resolution, index-versus-worktree coverage (including symlink and submodule type changes), filename and symlink-target hits, binary and submodule accounting (including UTF-16, a NUL past git's sniff window, and `.gitattributes` binary marks), the allowlist and its counts, `--strict`, `--json` shape and escaping (including non-UTF-8 bytes), and filenames holding spaces, colons and newlines.
Each test runs in its own throwaway repo with host git hooks disabled, and output files are per-run.
Requires bash 4.4+, git and python3 — python3 for JSON round-trip checks, a dependency of the suite only.
`LEAKCHECK_BIN=/path/to/leakcheck ./test/run-tests.sh` runs the suite against another build.

## Status

v0.3.0.
Single bash file.
Defaults stay conservative on purpose; the config file is where projects encode their own sensitivities.
The username component of the default home-path regex requires a leading ASCII alphanumeric or underscore, so elided placeholders like `/home/.../foo.md` — the canonical way to show a home path *without* leaking a real username — don't trip the scanner.

## License

MIT — see [`LICENSE`](./LICENSE).

---

KeMeK Network © 2026

# leakcheck

Find the home paths, hostnames and internal codenames in a git repo before you make it public.

Credential scanners such as gitleaks, trufflehog and git-secrets look for secrets.
leakcheck looks for what they ignore: home paths that carry your username, the names of your machines, and the codenames only your team uses — references that pile up in a private repo and get noticed only after it goes public.
It is one bash script, and git is its only real dependency.

*README v0.8.0*

## Install

```sh
git clone https://github.com/kVadrum/leakcheck.git
cp leakcheck/bin/leakcheck ~/.local/bin/    # or any other directory on $PATH
```

Or run `bin/leakcheck` straight from the checkout.

Requirements: bash 4.4 or newer (macOS's system bash is 3.2, which leakcheck refuses with exit `2`), git 2.19 or newer, and `sed`, `tr`, `mktemp`, `readlink`, `dirname` and `basename`.
It is developed and tested on bash 5.3 and git 2.53; the two version floors follow from the features the script uses and are not themselves tested.

## Quick start

Run it anywhere inside the repo you are about to publish:

```text
$ leakcheck
README.md:3: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] See /home/alice/code for details.
link:0: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] -> /home/alice/notes
docs/notes-from-MYHOST.md:0: [MYHOST] docs/notes-from-MYHOST.md
leakcheck: 3 match(es)
leakcheck: scanned 5 tracked files (index + worktree; 1 binary skipped, 0 submodules not scanned, 1 skipped by config, 1 allowed; history not scanned)
```

Each hit is `path:line: [pattern] text`, on stdout.
That run found a home path in a file, a symlink pointing into a home directory, and a hostname in a file name; name and symlink hits carry line `0`.
`MYHOST` came from the repo's config file, which is where your own names go ([Configuration](#configuration)).
The two summary lines go to stderr, and the second one says what was *not* scanned.

Once it is clean, it prints a single line on stdout and exits `0`:

```text
leakcheck: clean — 0 matches across 4 tracked files (index + worktree; 1 binary skipped, 0 submodules not scanned, 1 skipped by config, 1 allowed; history not scanned)
```

**Treat any non-zero exit as "do not publish".**

A clean tree is not a clean history: a leak you deleted last month is still in every commit that held it.
Before a private repo goes public, also run `leakcheck --history` ([Scanning history](#scanning-history)).

## What it catches

With no configuration, leakcheck flags absolute home paths on the three major operating systems:

```text
/home/<user>/...
/Users/<user>/...
C:\Users\<user>\...
```

It also catches the same paths as they look once serialized or spelled differently:

- with escaped separators, as JSON and JavaScript strings write them: `\/home\/<user>\/` and `C:\\Users\\<user>\\` (any drive letter, any case);
- other Windows spellings: `c:\users\<user>\`, `D:\Users\<user>\`, `C:\USERS\<user>\`;
- usernames holding a non-ASCII character, such as `zoë` or `José`, in both the POSIX and the Windows shapes.

Every default is an absolute home path, and each shape was measured against real repositories before it became a default, because a false positive in a default lands on everyone.
The defaults never overlap, so one path is one hit, and they behave the same in a UTF-8 and a C locale.

Some things are deliberately left alone:

- **Placeholders.**
  A username that starts with ASCII punctuation, or holds no ASCII letter, digit or underscore at all, never matches — so `/home/.../`, `/home/…/` and `/home/<user>/` stay clean.
  The cost is that a purely non-Latin username such as `/home/日本/` is not caught either; add a pattern if you need it.
- **`~/…` and `$HOME/…`.**
  They name no user, so on their own they leak nothing, and flagging them would bury real hits in noise.
  Add a pattern if your project wants them gone anyway.

The defaults only know shapes.
Your hostnames, codenames and internal tool names go in the config, and that is where most of leakcheck's value is.

### Recipes: opt-in patterns that are not defaults on purpose

Each of these was measured against real repositories and kept out of the defaults because of a false-positive class you can judge for your own codebase.
To opt in, add the line to your config.

```text
# A home path with no trailing slash: "cwd": "/home/alice", HOME=/home/alice.
# Anchored so `src/home/x.tsx` and `../home/x.js` stay clean; still fires on
# route literals such as href="/home/feed".
pattern (^|[^A-Za-z0-9_./-])/(home|Users)/[A-Za-z0-9_][A-Za-z0-9_.-]*(["'`[:space:]]|$)

# Claude Code's encoding of a project path in ~/.claude/projects/
# (-home-alice-dev-proj). Also matches hyphenated prose such as
# "work-from-home-day-one".
pattern -(home|Users)-[A-Za-z0-9_][A-Za-z0-9_.]*-
```

## What it scans

The whole repository from its top level, whichever subdirectory you run it in:

- **the index**: what the next commit publishes, including staged changes and files deleted from the worktree;
- **the worktree copy of every tracked file**: what `git commit -a` publishes, including unstaged edits and intent-to-add (`git add -N`) files;
- **every tracked path name**: `docs/notes-from-MYHOST.md` leaks in its name;
- **every tracked symlink target**: the stored target string is what a clone gets;
- **type changes**: an index symlink or submodule replaced by a regular file is scanned as the file `git commit -a` would publish.

A hit found in both the index and the worktree is reported once.

What it does not scan, and says so on every run:

- **Binary files** are skipped and counted, and `--strict` reports each one.
  Detection is by content alone, so a `.gitattributes` line such as `*.svg binary` does not hide a text file.
- **Submodule contents** belong to another repository: counted, and reported under `--strict`.
- **Git history and commit metadata**, unless you pass `--history`.
  A leak scrubbed today is still public in every old commit that holds it, so without the flag every verdict says `history not scanned`.
- **Encoded or compressed content** (base64, gzip, archives) is never decoded.
- **Untracked and gitignored files**, which a push does not publish.

## Scanning history

`leakcheck --history` also scans every commit reachable from any ref — branches, tags, remote-tracking branches, stashes and notes — with the same patterns:

- **every added line** of every commit, at its line number in that commit's version of the file, merge commits included;
- **every path** that ever existed, so a file renamed away from `notes-from-MYHOST.md` is still found;
- **author, committer and message** of every commit;
- **every ref name** — `feature/MYHOST-fix` leaks in its name — **and every annotated tag**: its name, tagger and message, a tag of a tag included.

```text
$ leakcheck --history
4ff38873059fcdf429cd403f41ec4ce5173a9f91:f.txt:2: [/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/] See /home/alice/code
28a6c84b00ef284368a6ef9d3f7305eb3a3a5d8f:(message):1: [MYHOST] scrubbed, was on MYHOST
leakcheck: 2 match(es)
leakcheck: scanned 1 tracked files (index + worktree; 0 binary skipped, 0 submodules not scanned, 1 skipped by config, 0 allowed; history scanned: 4 commits, 0 binary files skipped, 0 skipped by config, 1 current-config lines exempt, 1 refs, 0 annotated tags, 0 tagged trees or blobs not scanned)
```

A history hit leads with the full commit id, then `path:line:`; commit metadata uses `(author)`, `(committer)` or `(message)` in place of the path, with the message's line number.
Ref and tag hits use `(ref)`, `(tag)`, `(tagger)` or `(tag message)`, and lead with the object they name: the commit a branch points at, or the tag object.

- **Each finding is reported once, at the earliest commit that has it.**
  A line that stayed put through fifty edits is one hit, and so is one email address in five hundred commits.
- **A leak that is still in the tree is reported twice** — once as it is now, once at the commit that introduced it — because each needs its own fix: an edit for the tree, a history rewrite (for example with `git filter-repo`) for the past.
- **`skip` and `allow` apply to history too.**
  An allow rule sees a history hit as `path:line:text`, without the commit, so the rules you already have keep working.
  Your own commit email will match a pattern for your own domain; allow it with a line such as `allow ^\(author\):0:Alice <alice@example\.com>$`.
- **Old versions of your config are scanned.**
  A line still in your current, committed `.leakcheckrc` is exempt, as it is in the tree, and counted as `current-config lines exempt`.
  A line you have since removed is not: a hostname that sat in `.leakcheckrc` before you moved it to `.leakcheckrc.local` is still in every commit that held it, and is reported.
- **Grafts and replace refs are ignored**, so the scan sees the history a push publishes, not a locally rewritten one.
- **A `.leakcheckrc.local` committed at any point is a finding** (`config:local-in-history`), even if it was removed later.
- **Binary files in history are skipped and counted**; `--strict` reports each.
- **A ref that ends at a tree or a blob** instead of a commit publishes content no diff shows: counted as `tagged trees or blobs not scanned`, and reported under `--strict`.
- **A shallow clone is refused** with exit `2`: its history is incomplete, and a clean verdict over part of it would be a lie.
  In GitHub Actions, check out with `fetch-depth: 0`.
- **Commits no ref reaches** — reflog-only and dangling objects — are not scanned, because a push does not publish them.

### Only the commits a push adds

`--history-range RANGE` scans one git revision range instead of every ref; `origin/main..HEAD` is what pushing your branch to `main` would add:

```text
$ leakcheck --history-range origin/main..HEAD
0a2a94c80d26e6f9f0c6465f619b5ffb5e0d9be5:notes.md:1: [MYHOST] Deploys to MYHOST nightly.
leakcheck: 1 match(es)
leakcheck: scanned 3 tracked files (index + worktree; 0 binary skipped, 0 submodules not scanned, 1 skipped by config, 0 allowed; history scanned: 2 commits in range origin/main..HEAD only, 0 binary files skipped, 0 skipped by config, 0 current-config lines exempt, 1 refs, 0 annotated tags, 0 tagged trees or blobs not scanned)
```

The host name was edited out again before the push, so the tree is clean, but the commit that added it is still part of the push.

- **Everything above applies inside the range**: every added line, path name and commit's metadata, once per finding at its earliest commit in the range, and the refs and annotated tags that point into it — the ones the push carries.
- **A finding older than the range is not reported** — that is the point — so a range scan vouches only for its range, and the summary and the JSON (`history.range`) say which range it was.
- `RANGE` is one revision argument as `git log` takes it: `A..B`, `A...B`, or a single commit for everything it reaches.
  An option-shaped value such as `--all` is refused, and so is a second `--history-range`.
- **A shallow clone is accepted when it holds the whole range**, and refused when the range reaches past the clone's oldest commits.

As a `pre-push` hook (`.git/hooks/pre-push`, executable), it scans exactly what each push adds and stops the push on anything non-zero:

```sh
#!/bin/sh
while read -r local_ref local_sha remote_ref remote_sha; do
  case $local_sha in *[!0]*) ;; *) continue ;; esac   # deleting a branch adds nothing
  case $remote_sha in
    *[!0]*) range=$remote_sha..$local_sha ;;
    *)      range=$local_sha ;;                       # a new branch: everything it reaches
  esac
  vendor/leakcheck --history-range "$range" || exit
done
```

A new branch is scanned whole, so it also re-reports what other branches already published.
If the remote holds commits you have not fetched, the range cannot be resolved and the push stops with exit `2`; fetch first.

## Configuration

leakcheck reads up to two files from the repo's top level, in this order:

- **`.leakcheckrc`**: commit this one, with the patterns that are safe to publish;
- **`.leakcheckrc.local`**: gitignore this one, and put your real hostnames and codenames in it.

Your config is an inventory of exactly what you are trying to hide, which is why the second file exists.
A *tracked* `.leakcheckrc.local` is reported as a finding of its own (`config:local-tracked`), whatever `--config` says, and unlike `.leakcheckrc` its content is scanned like any other file.
`--config FILE` replaces both files with `FILE`.

Both files are line-oriented and take four directives; blank lines and `#` comments are ignored:

```text
# Add a pattern to the scan set.
pattern MYHOST
pattern internal-tool-name

# Allow hits by regex: a rule names a hit's whole "path:line:text", or
# each match on it as "path:line:match" (see How patterns behave, below).
allow /home/USERNAME/
allow ^fixtures/

# Skip paths: a git pathspec glob, relative to the repo top level.
# `*` also matches `/`, so this skips everything under tests/fixtures/.
skip tests/fixtures/*

# Turn off the built-in defaults (add at least one pattern after this).
# no-defaults
```

How patterns behave — read this before you write one:

- Patterns are **POSIX extended regexes**, evaluated by `git grep -E` one line at a time.
- **Matching is case-sensitive**, and nothing warns you: `pattern MYHOST` does not match `myhost.example`.
  Spell out the variants: `pattern [Mm][Yy][Hh][Oo][Ss][Tt]`.
- **There is no `\d`, `\t` or `\x`.**
  POSIX regex reads a backslash before an ordinary letter as just that letter, so `SECRET-\d+` would match nothing and a single-backslash `C:\Users\…` would never match a real path.
  leakcheck refuses both with exit `2`: write `[0-9]` for a digit and `\\` for a literal backslash.
- **Inside brackets a backslash is literal**, so `[\w.-]` would mean a backslash, a `w`, a dot or a hyphen; it is refused too.
  Write `[[:alnum:]_.-]`.
- `\w`, `\W`, `\s`, `\S`, `\b` and `\B` are accepted; they work where git uses GNU regex, as on Linux, but are not POSIX.
- **Name and symlink hits carry line `0`**, so an allow rule for a file name reads `^docs/notes-from-MYHOST\.md:0:`.
- **An allow rule excuses what it names, not every hit on its line.**
  It allows a hit when it matches the hit's whole `path:line:text` (`^f\.txt:1:/home/alice/x$`), or when it matches `path:line:` followed by each match of the hit's own pattern on that line.
  So `allow /home/USERNAME/` excuses the placeholder but not a `MYHOST`, or a real `/home/alice/`, further along the same line; `allow \.example\.com` still excuses the host name `x.example.com` it is part of; and a location rule such as `^fixtures/` allows everything under `fixtures/`.
  A rule that names text around a match, short of the whole line (`^a\.txt:1:see`), excuses nothing.
- **Every allow rule's suppressions are counted**, per rule in `--json`, so an over-broad rule shows up instead of passing as a clean repo.
  When two rules excuse one hit, the first listed takes the count.

leakcheck never scans the content of its own config file — otherwise every `pattern` line would match itself — and counts it under `skipped by config`.
The config's name and symlink target are still scanned, because a clone publishes both.

Mistakes in the config stop the run with exit `2` rather than narrowing the scan: an empty `pattern`, `allow` or `skip` (an empty `allow` would allow everything), an unknown directive, an invalid regex, a backslash escape POSIX does not have, or a config file that is missing or unreadable.

## Usage

```text
leakcheck                     scan with the defaults plus .leakcheckrc / .leakcheckrc.local
leakcheck --strict            also report every file whose content was not scanned
leakcheck --history           also scan every commit reachable from any ref
leakcheck --history-range R   the same, over the commits in revision range R only
leakcheck --json              machine-readable output
leakcheck --list-patterns     print the effective pattern set
leakcheck -c, --config FILE   use FILE instead of .leakcheckrc / .leakcheckrc.local
leakcheck -C, --root DIR      run as if started in DIR
leakcheck -V, --version
leakcheck -h, --help
```

A relative `--config` resolves against the directory leakcheck runs in — after `--root`, as with `git -C`.
An absolute one works too, inside the repo or outside it.

Exit codes:

- `0` — clean;
- `1` — one or more matches;
- `2` — usage, config or scan error (an invalid regex, an unreadable file, a missing config, not a git repository, a bash older than 4.4), and any internal abort.

**Treat any non-zero exit as "do not publish"** — never test for `1` alone.
`0`, `1` and `2` cover everything the script itself decides; a signal still exits as 128+n, and that is non-zero too.

## Output

### Text

Hits go to stdout, one per line, as `path:line: [pattern] text`; the two summary lines go to stderr.
The format is plain text without color, so it greps.
The summary's count is matches, not lines: two patterns matching one line are two hits.

Some hits are not regex matches, and they use these names in the pattern slot:

- `unscanned:binary` and `unscanned:submodule` — with `--strict`, one per file whose content was not scanned;
- `unscanned:tagged-tree` and `unscanned:tagged-blob` — with `--history --strict`, one per ref that ends at a tree or a blob;
- `config:local-tracked` — a committed `.leakcheckrc.local`;
- `config:local-in-history` — with `--history` or `--history-range`, a `.leakcheckrc.local` committed at any point it scanned.

A path or symlink target holding a newline is printed C-quoted (`"two\nlines.md":1: …`), so every hit stays on one line.

### JSON

`leakcheck --json` prints a single line of JSON on stdout.
Here is the Quick start run, formatted for reading:

```json
{
  "version": "…",
  "clean": false,
  "count": 3,
  "hits": [
    {"file": "README.md", "line": 3, "pattern": "/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/", "text": "See /home/alice/code for details.", "source": "both"},
    {"file": "link", "line": 0, "pattern": "/home/[A-Za-z0-9_][A-Za-z0-9_.-]*/", "text": "-> /home/alice/notes", "source": "both"},
    {"file": "docs/notes-from-MYHOST.md", "line": 0, "pattern": "MYHOST", "text": "docs/notes-from-MYHOST.md", "source": "index"}
  ],
  "target": "index+worktree",
  "tracked": 5,
  "skipped": {"binary": 1, "submodule": 0, "config": 1},
  "symlinks": 1,
  "allowed": [{"rule": "/home/USERNAME/", "count": 1}],
  "history_scanned": false
}
```

- `version` is the leakcheck version that ran.
- `source` says where a hit was found: `index`, `worktree` or `both` — or `history`, and then the hit also carries `commit` after `source`: the full commit id, or for a ref or tag hit the id of the object it names.
- With `--history`, `history_scanned` is `true` and a final `history` object follows: `{"commits": 4, "binary": 0, "skipped": 0, "config_lines_exempt": 1, "range": null, "refs": 1, "tags": 0, "tagged_unscanned": 0}`.
  `range` is the `--history-range` value, or `null` when every ref was scanned.
- `allowed` lists what each allow rule suppressed.
- Strings are JSON-escaped, and bytes that are not valid UTF-8 become U+FFFD.
- The schema is a contract, and new fields are only ever appended.
  The order of `hits` is not part of it.
- On exit `2`, nothing at all is printed on stdout, so a consumer that parses empty output fails closed.

## Use in CI

Commit the single script into your repo, for example as `vendor/leakcheck` — not the whole leakcheck checkout, whose README and tests are full of deliberate example leaks that your scan would then report.

A GitHub Actions step, after your checkout step:

```yaml
- name: leakcheck
  run: ./vendor/leakcheck
```

To also see each hit as an annotation on the pull request, keep leakcheck's exit code and print the hits through `jq`:

```yaml
- name: leakcheck
  run: |
    set +e
    out=$(./vendor/leakcheck --json); rc=$?
    set -e
    jq -r '.hits[]? | "::error file=\(.file),line=\(.line)::leakcheck: \(.pattern) matched"' <<<"$out"
    exit "$rc"
```

The step still fails on any match (`1`) and on any error (`2`, which prints no JSON).

To scan history in CI, check out the full history — the default checkout is shallow, and leakcheck refuses it:

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0
- name: leakcheck (history)
  run: ./vendor/leakcheck --history
```

To scan only what a pull request adds, pass its range; the shas go through `env` rather than straight into the script:

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0
- name: leakcheck (this pull request's commits)
  env:
    BASE: ${{ github.event.pull_request.base.sha }}
    HEAD: ${{ github.event.pull_request.head.sha }}
  run: ./vendor/leakcheck --history-range "$BASE..$HEAD"
```

## Tests

```sh
./test/run-tests.sh
```

The suite covers every default shape (each hitting exactly once, in a UTF-8 and a C locale, with the placeholders clean), every config directive and its error paths (the refused escapes included), `.leakcheckrc.local`, internal aborts and the bash floor (both by running a modified copy), `--config` / `--root` resolution, index-versus-worktree coverage including symlink and submodule type changes, file-name and symlink-target hits, binary and submodule accounting (including UTF-16, a NUL past git's sniff window, and `.gitattributes` binary marks), the allowlist and its counts, `--strict`, the JSON shape and its escaping, file names holding spaces, colons and newlines, and `--history` — merges, a side branch hidden behind an `-s ours` merge, the root commit under `log.showRoot=false`, quoted path names, shallow clones, and once-per-finding reporting — and `--history-range`, in every pass and in a shallow clone.
Each test runs in its own throwaway repo with your git hooks disabled.
It needs bash 4.4+, git and python3 (for JSON round-trip checks; leakcheck itself never uses python3).
`LEAKCHECK_BIN=/path/to/leakcheck ./test/run-tests.sh` runs the suite against another build.

## Background

leakcheck was conceived and written by Claude in claude-expo — a private workshop where Claude picks and builds small utilities under operator oversight.
Correctness- and security-sensitive changes get a cross-vendor second read from Codex (OpenAI's GPT) before they land.
Why the default pattern set stays minimal, and why aggressive defaults read as apology rather than contract: [Defaults are the first impression](https://github.com/kVadrum/claude-journal/blob/main/2026-05-21.md), in [claude-journal](https://github.com/kVadrum/claude-journal).

## License

MIT — see [`LICENSE`](./LICENSE).

---

KeMeK Network © 2026

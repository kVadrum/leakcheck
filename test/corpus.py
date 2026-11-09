#!/usr/bin/env python3
"""leakcheck corpus harness: measures the built-in credential rules.

Three corpora, each run through bin/leakcheck as a black box (--json, and a
config holding only `no-defaults`, so the credential rules run alone):

  positives     stand-ins per rule (test/credential_specs.py), each in every
                context below. A plain context must produce exactly one hit,
                labelled with the stand-in's own rule; escaped (JSON's \\/) and
                encoded (percent, base64) contexts are measured in columns of
                their own — misses there are the decoding work still to do.
  look-alikes   strings real code is full of that no rule should match: UUIDs,
                hashes, base64 of random bytes, integrity strings, identifiers.
  repositories  any repositories named on the command line, their tree or,
                with --history, their whole history. Every credential hit is
                listed for a person to label: real code is where precision is
                measured, and no generator can stand in for it.

Nothing is printed unmasked: leakcheck masks its hits, and this harness shows
a stand-in as its first four characters and its length. Stand-ins are built
at run time from a seed; this file holds no token.

Usage:
  python3 test/corpus.py [--bin PATH] [--per-rule N] [--seed S] [--history]
                         [--json OUT] [--compare OLD.json] [REPO ...]

Exit: 0 when every plain positive hit exactly its own rule and no look-alike
hit anything; 1 otherwise; 2 when the harness or leakcheck fails.
"""
import argparse
import base64
import concurrent.futures
import importlib.util
import json
import os
import random
import subprocess
import sys
import tempfile
import urllib.parse
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # no __pycache__ beside a tracked file
_spec = importlib.util.spec_from_file_location("credential_specs", os.path.join(HERE, "credential_specs.py"))
specs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(specs)

# Header-only rules: their match is a marker before the secret, so they get
# layouts of their own instead of value contexts.
MARKER_RULES = {"private-key", "putty-private-key"}


def mask(s):
    return f"{s[:4]}[{len(s)} chars]"


def die(msg):
    print(f"corpus: {msg}", file=sys.stderr)
    sys.exit(2)


# ─── positives ────────────────────────────────────────────────────────

def value_for(cid, before, m):
    """The text a context wraps: the match, plus the part of its line a real
    value carries with it (a webhook URL's scheme and host)."""
    lead = before
    for p in ("KEY=", "URL=", "X;"):
        if lead.startswith(p):
            lead = lead[len(p):]
            break
    if cid == "azure-storage-key":
        return "DefaultEndpointsProtocol=https;AccountName=acct;" + m + ";EndpointSuffix=core.windows.net"
    return lead + m


MIN_L = ('!function(e,t){"use strict";var n=e.config||{},r=t.headers,o=function(i){'
         'return i&&i.length>0?i.trim():null};n.timeout=3e4,n.retries=3;var a=o(n.token)||"')
MIN_R = '";return r.set("X-Request-Id",n.id),r.set("Authorization","Bearer "+a),t}(window,request);'

PLAIN = [
    ("env",      lambda v: f"SERVICE_TOKEN={v}"),
    ("export",   lambda v: f'export SERVICE_TOKEN="{v}"'),
    ("json",     lambda v: f'  "token": "{v}",'),
    ("yaml",     lambda v: f"token: '{v}'"),
    ("toml",     lambda v: f'token = "{v}"'),
    ("template", lambda v: f"const token = `{v}`;"),
    ("python",   lambda v: f'client = Client(api_key="{v}")'),
    ("query",    lambda v: f"https://api.service.invalid/v1?token={v}&page=2"),
    ("header",   lambda v: f"Authorization: Bearer {v}"),
    ("bare",     lambda v: v),
    ("tabs",     lambda v: f"\t{v}\t# rotated"),
    ("parens",   lambda v: f"call({v}),"),
    ("markdown", lambda v: f"Use `{v}` here."),
    ("shell",    lambda v: f'curl -H "X-Token: {v}" https://api.service.invalid'),
    ("minified", lambda v: MIN_L + v + MIN_R),
    ("crlf",     lambda v: f"SERVICE_TOKEN={v}\r"),
]
# Only where the transform changes the value: otherwise it is a plain case.
ESCAPED = [
    ("json-escaped", lambda v: '  "url": "' + v.replace("/", "\\/") + '",'),
]
ENCODED = [
    ("percent", lambda v: "https://api.service.invalid/cb?state=" + urllib.parse.quote(v, safe="")),
    ("base64",  lambda v: "auth: " + base64.b64encode(("token=" + v).encode()).decode()),
]


def b64_body(r, n=64):
    return specs.gen([("b64", n)], r)


def marker_cases(cid, r, n):
    """(context, lines, index of the line that must hit) for a header rule."""
    out = []
    if cid == "private-key":
        kinds = ["RSA ", "EC ", "OPENSSH ", "", "ENCRYPTED ", "DSA "]
        for i in range(n):
            kind = kinds[i % len(kinds)]
            head = "-----BEGIN " + kind + "PRIV" + "ATE KEY-----"
            foot = "-----END " + kind + "PRIV" + "ATE KEY-----"
            body = [b64_body(r) for _ in range(3)]
            out += [
                ("pem-file", [head] + body + [foot], 0),
                ("crlf", [ln + "\r" for ln in [head] + body + [foot]], 0),
                ("json", ['  "private_key": "' + head + "\\n" + "\\n".join(body) + "\\n" + foot + '\\n",'], 0),
                ("env-escaped", ['PRIVATE_KEY="' + head + "\\n" + body[0] + '"'], 0),
                ("yaml-block", ["key: |", "  " + head] + ["  " + b for b in body] + ["  " + foot], 1),
                ("one-line", [head + " " + " ".join(body) + " " + foot], 0),
            ]
    elif cid == "putty-private-key":
        for i in range(n):
            ver, alg = (("3", "ssh-ed25519"), ("2", "ssh-rsa"))[i % 2]
            out += [
                ("ppk-file", ["PuTTY-User-" + "Key-File-" + ver + ": " + alg, "Encryption: none",
                              "Comment: deploy", "Public-Lines: 1", b64_body(r)], 0),
                ("crlf", ["PuTTY-User-" + "Key-File-" + ver + ": " + alg + "\r", "Encryption: none\r"], 0),
            ]
    return out


def build_positives(r, per_rule):
    """{(group, rule): [(context, lines, hit index, stand-in)]}"""
    cases = {}
    for cid, (before, spec) in specs.SPECS.items():
        if cid in MARKER_RULES:
            cases[("plain", cid)] = [(ctx, lines, k, lines[k].strip()) for ctx, lines, k in marker_cases(cid, r, per_rule)]
            continue
        for _ in range(per_rule):
            m = specs.gen(spec, r)
            v = value_for(cid, before, m)
            for ctx, f in PLAIN:
                cases.setdefault(("plain", cid), []).append((ctx, [f(v)], 0, m))
            for ctx, f in ESCAPED:
                if "/" in v:
                    cases.setdefault(("escaped", cid), []).append((ctx, [f(v)], 0, m))
            for ctx, f in ENCODED:
                if ctx != "percent" or urllib.parse.quote(v, safe="") != v:
                    cases.setdefault(("encoded", cid), []).append((ctx, [f(v)], 0, m))
    return cases


# ─── look-alikes ──────────────────────────────────────────────────────

WORDS = ("user account token cache config request response handler client server session "
         "build deploy release version module package router service worker queue event "
         "stream buffer record schema table index field value status result error retry "
         "timeout limit offset cursor batch job task disk desk mask risk flask ask "
         "image layer volume node cluster region zone bucket object file path name").split()


def lookalike_kinds(r):
    def hexs(n, upper=False):
        s = "".join(r.choice("0123456789abcdef") for _ in range(n))
        return s.upper() if upper else s

    def b64(nbytes, urlsafe=False, pad=True):
        raw = r.getrandbits(8 * nbytes).to_bytes(nbytes, "big")
        s = (base64.urlsafe_b64encode if urlsafe else base64.b64encode)(raw).decode()
        return s if pad else s.rstrip("=")

    def words(k, sep=""):
        return sep.join(r.choice(WORDS) for _ in range(k))

    def camel(k):
        w = [r.choice(WORDS) for _ in range(k)]
        return w[0] + "".join(x.capitalize() for x in w[1:])

    return {
        "uuid": lambda: str(uuid.UUID(int=r.getrandbits(128), version=4)),
        "uuid-upper": lambda: str(uuid.UUID(int=r.getrandbits(128), version=4)).upper(),
        "uuid-bare": lambda: uuid.UUID(int=r.getrandbits(128), version=4).hex,
        "md5": lambda: hexs(32),
        "sha1": lambda: hexs(40),
        "sha256": lambda: hexs(64),
        "sha512": lambda: hexs(128),
        "hex-upper": lambda: hexs(r.choice((32, 40, 64)), upper=True),
        "docker-digest": lambda: "sha256:" + hexs(64),
        "integrity": lambda: "sha512-" + b64(64),
        "sri": lambda: "sha384-" + b64(48),
        "base64": lambda: b64(r.randint(12, 300)),
        "base64url": lambda: b64(r.randint(12, 300), urlsafe=True, pad=False),
        "data-uri": lambda: "data:image/png;base64," + b64(r.randint(60, 400)),
        "alnum": lambda: specs.gen([("an", r.randint(20, 90))], r),
        "identifier": lambda: camel(r.randint(3, 6)),
        "constant": lambda: words(r.randint(2, 4), "_").upper() + "_" + str(r.randint(0, 999)),
        "kebab-hex": lambda: r.choice(WORDS) + "-" + hexs(32),
        "snake-hex": lambda: r.choice(WORDS) + "_" + hexs(32),
        "k8s-name": lambda: words(2, "-") + "-" + hexs(10) + "-" + hexs(5),
        "semver": lambda: f"{r.randint(0, 20)}.{r.randint(0, 50)}.{r.randint(0, 200)}",
        "iso-time": lambda: f"2026-{r.randint(1, 12):02d}-{r.randint(1, 28):02d}T{r.randint(0, 23):02d}:{r.randint(0, 59):02d}:00Z",
        "ipv6": lambda: ":".join(hexs(4) for _ in range(8)),
    }


def build_lookalikes(r, n):
    kinds = lookalike_kinds(r)
    out = {}
    for kind, f in kinds.items():
        lines = []
        for i in range(n):
            v = f()
            lines.append((f'  "{kind}": "{v}",' if i % 2 else f"{kind}={v}", v))
        out[kind] = lines
    return out


# ─── running leakcheck ────────────────────────────────────────────────

GIT_QUIET = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-c", "core.autocrlf=false", "-c", "core.safecrlf=false"]


def git(cwd, *a):
    subprocess.run(["git", *GIT_QUIET, *a], cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def run_leakcheck(binary, rc, cwd, extra=()):
    p = subprocess.run([binary, "--json", "--config", rc, *extra], cwd=cwd,
                       capture_output=True, text=True, errors="replace")
    if p.returncode not in (0, 1):
        return None, (p.stderr.strip().splitlines() or ["exit %d" % p.returncode])[-1]
    try:
        return json.loads(p.stdout), None
    except json.JSONDecodeError as e:
        return None, f"unparseable JSON: {e}"


def leakcheck_version(binary):
    p = subprocess.run([binary, "--version"], capture_output=True, text=True)
    return p.stdout.strip().split()[-1] if p.returncode == 0 else "?"


def rule_ids(binary, rc, cwd):
    p = subprocess.run([binary, "--list-rules", "--config", rc], cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        die("--list-rules failed: " + p.stderr.strip())
    return [ln.split("\t")[0][len("credential:"):] for ln in p.stdout.splitlines()]


# ─── the run ──────────────────────────────────────────────────────────

def measure_synthetic(binary, rc, work, per_rule, seed):
    r = random.Random(seed)
    pos = build_positives(r, per_rule)
    look = build_lookalikes(r, per_rule * 4)
    repo = os.path.join(work, "synthetic")
    os.makedirs(repo)
    git(repo, "init", "-q")
    expect = {}  # (file, line) -> (group, rule, context, stand-in)
    for (group, cid), cs in pos.items():
        rel = f"pos/{group}/{cid}.txt"
        lines = []
        for ctx, ls, k, m in cs:
            expect[(rel, len(lines) + k + 1)] = (group, cid, ctx, m)
            lines += ls
        os.makedirs(os.path.join(repo, os.path.dirname(rel)), exist_ok=True)
        with open(os.path.join(repo, rel), "w", newline="") as fh:
            fh.write("\n".join(lines) + "\n")
    look_at = {}  # (file, line) -> (kind, value)
    for kind, ls in look.items():
        rel = f"look/{kind}.txt"
        os.makedirs(os.path.join(repo, "look"), exist_ok=True)
        with open(os.path.join(repo, rel), "w") as fh:
            fh.write("\n".join(ln for ln, _ in ls) + "\n")
        for i, (_, v) in enumerate(ls):
            look_at[(rel, i + 1)] = (kind, v)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=corpus", "-c", "user.email=corpus@invalid", "commit", "-q", "-m", "corpus")
    doc, err = run_leakcheck(binary, rc, repo)
    if doc is None:
        die("leakcheck failed on the synthetic corpus: " + err)

    got = {}
    for h in doc["hits"]:
        got.setdefault((h["file"], h["line"]), []).append(h["pattern"])
    res = {"per_rule": {}, "misses": [], "cross": [], "stray": [], "lookalike_hits": [],
           "placeholders": doc.get("credentials", {}).get("placeholders", 0)}
    for key, (group, cid, ctx, m) in expect.items():
        row = res["per_rule"].setdefault(cid, {g: [0, 0] for g in ("plain", "escaped", "encoded")})
        row[group][1] += 1
        labels = got.pop(key, [])
        own = "credential:" + cid
        if own in labels:
            row[group][0] += 1
        elif group == "plain":
            res["misses"].append({"rule": cid, "context": ctx, "stand_in": mask(m)})
        others = [lb for lb in labels if lb != own]
        if others:
            res["cross"].append({"rule": cid, "group": group, "context": ctx, "also": others})
    for key, labels in sorted(got.items()):
        if key in look_at:
            kind, v = look_at[key]
            for lb in labels:
                res["lookalike_hits"].append({"kind": kind, "rule": lb, "value": mask(v)})
        else:
            res["stray"].append({"file": key[0], "line": key[1], "rules": labels})
    res["lookalike_lines"] = len(look_at)
    return res


def measure_repos(binary, rc, repos, history, jobs):
    def one(path):
        doc, err = run_leakcheck(binary, rc, path, ["--history"] if history else [])
        if doc is None:
            return path, {"error": err}
        hits = [{"file": h["file"], "line": h["line"], "rule": h["pattern"][len("credential:"):],
                 "text": h["text"], "commit": h.get("commit", "")[:12]}
                for h in doc["hits"] if h["pattern"].startswith("credential:")]
        return path, {"hits": hits, "placeholders": doc.get("credentials", {}).get("placeholders", 0)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        return dict(ex.map(one, repos))


# ─── reporting ────────────────────────────────────────────────────────

def pct(a, b):
    return "—" if b == 0 else f"{a}/{b}"


def report(out, prev):
    syn = out["synthetic"]
    rules = out["rules"]
    look_by_rule = {}
    for h in syn["lookalike_hits"]:
        look_by_rule[h["rule"]] = look_by_rule.get(h["rule"], 0) + 1
    repo_by_rule = {}
    for rd in out["repos"].values():
        for h in rd.get("hits", []):
            repo_by_rule[h["rule"]] = repo_by_rule.get(h["rule"], 0) + 1
    print(f"leakcheck {out['version']} · seed {out['seed']} · {out['per_rule']} stand-ins per rule · "
          f"{len(rules)} rules · {syn['lookalike_lines']} look-alike lines · {len(out['repos'])} repositories"
          + (" (history)" if out["history"] else ""))
    print()
    print(f"{'rule':28} {'plain':>9} {'escaped':>9} {'encoded':>9} {'look-alike':>10} {'repos':>6}")
    for cid in rules:
        row = syn["per_rule"].get(cid, {g: [0, 0] for g in ("plain", "escaped", "encoded")})
        flag = "" if row["plain"][0] == row["plain"][1] and row["plain"][1] else "  ✗"
        print(f"{cid:28} {pct(*row['plain']):>9} {pct(*row['escaped']):>9} {pct(*row['encoded']):>9} "
              f"{look_by_rule.get('credential:' + cid, 0):>10} {repo_by_rule.get(cid, 0):>6}{flag}")
    tot = {g: [sum(r[g][0] for r in syn["per_rule"].values()), sum(r[g][1] for r in syn["per_rule"].values())]
           for g in ("plain", "escaped", "encoded")}
    print(f"{'total':28} {pct(*tot['plain']):>9} {pct(*tot['escaped']):>9} {pct(*tot['encoded']):>9} "
          f"{len(syn['lookalike_hits']):>10} {sum(repo_by_rule.values()):>6}")
    if syn["placeholders"]:
        print(f"\n{syn['placeholders']} synthetic matches set aside as placeholders (a generator bug: stand-ins avoid those shapes)")

    def section(title, items, fmt, limit=40):
        if not items:
            return
        print(f"\n{title} ({len(items)}):")
        for it in items[:limit]:
            print("  " + fmt(it))
        if len(items) > limit:
            print(f"  … {len(items) - limit} more (--json for all)")

    section("plain misses", syn["misses"], lambda m: f"{m['rule']:28} {m['context']:12} {m['stand_in']}")
    section("hits on another rule too", syn["cross"],
            lambda c: f"{c['rule']:28} {c['group']}/{c['context']:12} also {', '.join(c['also'])}")
    section("look-alike hits", syn["lookalike_hits"], lambda h: f"{h['rule']:40} {h['kind']:14} {h['value']}")
    section("hits on lines with nothing planted", syn["stray"], lambda s: f"{s['file']}:{s['line']} {', '.join(s['rules'])}")
    errs = [(p, d["error"]) for p, d in out["repos"].items() if "error" in d]
    section("repositories not scanned", errs, lambda e: f"{e[0]}: {e[1]}")
    hits = [(p, h) for p, d in sorted(out["repos"].items()) for h in d.get("hits", [])]
    section("repository hits — label each: real, stand-in, or false positive", hits,
            lambda ph: f"{os.path.basename(ph[0].rstrip('/'))}: "
                       f"{(ph[1]['commit'] + ':') if ph[1]['commit'] else ''}{ph[1]['file']}:{ph[1]['line']} "
                       f"[{ph[1]['rule']}] {ph[1]['text']}", limit=200)
    if prev:
        print(f"\ncompared with leakcheck {prev.get('version', '?')} (seed {prev.get('seed')}, {prev.get('per_rule')} per rule):")
        changed = 0
        for cid in sorted(set(rules) | set(prev["synthetic"]["per_rule"])):
            a = prev["synthetic"]["per_rule"].get(cid)
            b = syn["per_rule"].get(cid)
            if a != b:
                changed += 1
                print(f"  {cid:28} {a} -> {b}")
        pl = len(prev["synthetic"]["lookalike_hits"])
        if pl != len(syn["lookalike_hits"]):
            print(f"  look-alike hits {pl} -> {len(syn['lookalike_hits'])}")
        prh = sum(len(d.get("hits", [])) for d in prev.get("repos", {}).values())
        if prh != sum(repo_by_rule.values()):
            print(f"  repository hits {prh} -> {sum(repo_by_rule.values())}")
        if not changed:
            print("  per-rule counts identical")


def main():
    ap = argparse.ArgumentParser(description="Measure leakcheck's credential rules.")
    ap.add_argument("--bin", default=os.environ.get("LEAKCHECK_BIN", os.path.join(HERE, "..", "bin", "leakcheck")))
    ap.add_argument("--per-rule", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20261109)
    ap.add_argument("--history", action="store_true", help="scan each repository's whole history")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--json", metavar="OUT", help="write the full result as JSON")
    ap.add_argument("--compare", metavar="OLD", help="a previous --json result to diff against")
    ap.add_argument("repos", nargs="*")
    a = ap.parse_args()
    binary = os.path.abspath(a.bin)
    if not os.access(binary, os.X_OK):
        die(f"not executable: {binary}")
    for p in a.repos:
        if not os.path.exists(os.path.join(p, ".git")):
            die(f"not a git repository: {p}")
    prev = None
    if a.compare:
        with open(a.compare) as fh:
            prev = json.load(fh)
    with tempfile.TemporaryDirectory(prefix="leakcheck-corpus.") as work:
        rc = os.path.join(work, "rc")
        with open(rc, "w") as fh:
            fh.write("no-defaults\n")
        probe = os.path.join(work, "probe")
        os.makedirs(probe)
        git(probe, "init", "-q")
        rules = rule_ids(binary, rc, probe)
        missing = sorted(set(rules) - set(specs.SPECS))
        extra = sorted(set(specs.SPECS) - set(rules))
        if missing or extra:
            die(f"rules without a stand-in spec: {missing}; specs for no rule: {extra}")
        syn = measure_synthetic(binary, rc, work, a.per_rule, a.seed)
        repos = measure_repos(binary, rc, [os.path.abspath(p) for p in a.repos], a.history, a.jobs)
    out = {"version": leakcheck_version(binary), "seed": a.seed, "per_rule": a.per_rule,
           "history": a.history, "rules": rules, "synthetic": syn, "repos": repos}
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)
    report(out, prev)
    # A repository leakcheck could not scan is a measurement not taken, so it
    # outranks any finding: exit 2, as leakcheck itself does on a scan error.
    if any("error" in d for d in repos.values()):
        sys.exit(2)
    bad = syn["misses"] or syn["cross"] or syn["lookalike_hits"] or syn["stray"]
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

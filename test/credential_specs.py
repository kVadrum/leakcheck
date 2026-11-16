"""Stand-in credentials for leakcheck's built-in credential rules.

One spec per rule: the text before the match on its line, and the match's
parts. A tracked file is public and is scanned by leakcheck and by other
scanners, so nothing here is a token, nor anything a credential rule matches:
every literal prefix is split ("gh", "p_"), and every stand-in is built at run
time from a seeded random source. Two consumers, so a rule's format changes in
one place: test/run-tests.sh (one stand-in per rule, `python3 credential_specs.py`
prints the TSV it reads) and test/corpus.py (many per rule, in many contexts).
A stand-in never has a placeholder's shape (stand_in_ok): those are set aside,
and tested on their own.
"""
import random

CS = {
    "an": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    "an-_": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
    "an_": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_",
    "UD": "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "a": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    "d": "0123456789",
    "hex": "0123456789abcdef",
    "hexU": "0123456789ABCDEF",
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


def gen(spec, r):
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


# Every other branch of a rule's alternation, and every other prefix its
# issuer hands out, one spec each: SPECS exercises one branch per rule, and a
# branch nothing exercises can break silently (stage B, v0.11.1: `glc_`,
# `sntrys_`, `fm1_` and `whsec_` with `/` went untested). The corpus harness
# reads these; the suite reads SPECS alone, so its rows stay as they were.
VARIANTS = {
 "aws-access-key-id": [("KEY=", [p, ("UD", 16)]) for p in ("AS" "IA", "AB" "IA", "AC" "CA", "A3" "TX")],
 "github-token": [("KEY=", ["gh", p + "_", ("an", 36)]) for p in "ousr"],
 "gitlab-token": [("KEY=", ["gl", p + "-", ("an-_", 26)]) for p in
                  ("ptt", "rt", "dt", "soat", "cbt", "ft", "imt", "agent", "oas")]
                 + [("KEY=", ["GR13", "48941", ("an-_", 20)])],
 "slack-token": [("KEY=", ["xo", "x" + p + "-", ("d", 12), "-", ("d", 13), "-", ("an", 32)]) for p in "paeors"]
                + [("KEY=", ["xa", "pp-1-", ("UD", 11), "-", ("d", 13), "-", ("hex", 64)])],
 "slack-webhook": [("URL=https://", ["hooks", ".slack.com/workflows/T", ("UD", 10), "/A", ("UD", 10), "/", ("d", 18), "/", ("an", 24)]),
                   ("URL=https://", ["hooks", ".slack.com/triggers/T", ("UD", 10), "/", ("d", 13), "/", ("hex", 32)])],
 "discord-webhook": [("URL=https://", ["discord", "app.com/api/webhooks/", ("d", 19), "/", ("an-_", 68)])],
 "stripe-key": [("KEY=", ["rk", "_live_", ("an", 99)]), ("KEY=", ["sk", "_test_", ("an", 99)]),
                ("KEY=", ["sk", "_prod_", ("an", 24)])],
 "webhook-signing-secret": [("KEY=", ["wh", "sec_", ("b64", 43), "="])],
 "openai-key": [("KEY=", ["sk-", "svcacct-", ("an-_", 74), "T3BlbkFJ", ("an-_", 74)]),
                ("KEY=", ["sk-", "admin-", ("an-_", 74), "T3BlbkFJ", ("an-_", 74)]),
                ("KEY=", ["sk-", ("an", 20), "T3BlbkFJ", ("an", 20)])],
 "huggingface-token": [("KEY=", ["api", "_org_", ("a", 34)])],
 "pypi-token": [("KEY=", ["pypi-", "AgENdGVzdC5weXBpLm9yZw", ("an-_", 70)])],
 "brevo-key": [("KEY=", ["xsmtp", "sib-", ("hex", 64), "-", ("an", 16)])],
 "digitalocean-token": [("KEY=", ["do", p + "_v1_", ("hex", 64)]) for p in "or"],
 "shopify-token": [("KEY=", ["shp", p + "_", ("hex", 32)]) for p in ("ca", "pa", "ss")],
 "jwt": [("KEY=", ["eyJhbGciOiJub25lIn0", ".", "eyJ", ("an", 40), "."])],
 "vault-token": [("KEY=", ["hv", "b.", ("an-_", 138)])],
 "doppler-token": [("KEY=", ["dp", "." + p + ".", ("an", 43)]) for p in ("st", "sa", "ct", "scim", "audit")],
 "sentry-token": [("KEY=", ["sntr", "ys_eyJ", ("b64", 120)])],
 "grafana-token": [("KEY=", ["gl", "c_", ("b64", 64), "=="])],
 "databricks-token": [("KEY=", ["da", "pi", ("hex", 32), "-", ("d", 1)])],
 "1password-token": [("KEY=", ["A3", "-", ("UD", 6), "-", ("UD", 11), "-", ("UD", 5), "-", ("UD", 5), "-", ("UD", 5)]),
                     ("KEY=", ["A3", "-", ("UD", 6), "-", ("UD", 6), "-", ("UD", 5), "-", ("UD", 5), "-", ("UD", 5), "-", ("UD", 5)])],
 "facebook-token": [("KEY=", ["EA", "AM", ("an", 120)])],
 "square-token": [("KEY=", ["sq0", "atp-", ("an-_", 22)])],
 "planetscale-token": [("KEY=", ["pscale", "_" + p + "_", ("an", 43)]) for p in ("oauth", "pw")],
 "flyio-token": [("KEY=", ["f", "m" + p + "_", ("b64", 140)]) for p in ("1", "2", "1a", "2r")],
 "tailscale-key": [("KEY=", ["tskey", "-" + p + "-", ("an", 14), "-", ("an", 32)]) for p in ("api", "client", "scim", "webhook")],
 "supabase-key": [("KEY=", ["sb", "_secret_", ("an-_", 32)])],
 "new-relic-key": [("KEY=", ["NR", "II-", ("an-_", 32)])],
 "twilio-api-key": [("KEY=", ["S", "K", ("hexU", 32)])],
}


def variants(cid):
    """Every spec of a rule, SPECS' first."""
    return [SPECS[cid]] + VARIANTS.get(cid, [])


def suite_rows():
    """(rule id, the line holding the stand-in, the exact match), one per
    rule, in table order, from the suite's fixed seed: the rows the suite has
    always read, byte for byte."""
    r = random.Random(20261105)
    for cid, (before, spec) in SPECS.items():
        m = gen(spec, r)
        yield cid, before + m, m


if __name__ == "__main__":
    for cid, line, m in suite_rows():
        print(cid, line, m, sep="\t")

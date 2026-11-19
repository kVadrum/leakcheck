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
import base64
import random
import zlib

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
    "hexh": "0123456789abcdefgh",
 "AL": "ABCDEFGHIJKL",
 "AP": "ABCDEFGHIJKLMNOP",
 "AD": "ABCD",
 "AQgw": "AQgw",
 "b32": "abcdefghijklmnopqrstuvwxyz234567",
 "b32U": "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567",
 "b58": "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz",
}


def stand_in_ok(s):
    # Never a placeholder shape: those are excused (and tested on their own).
    for i in range(len(s) - 7):
        w = s[i:i + 8]
        if len(set(w)) == 1 or all(ord(w[k + 1]) == ord(w[k]) + 1 for k in range(7)):
            return False
    return "EXAMPLE" not in s and "example" not in s


B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def part(p, r):
    if isinstance(p, str):
        return p
    if p[0] == "basic":
        # HTTP Basic credentials: the base64 of the parts (a user, `:`, a
        # password), as RFC 7617 sends them.
        return base64.b64encode("".join(part(q, r) for q in p[1]).encode()).decode()
    s = "".join(r.choice(CS["an" if p[0] == "an-crc" else p[0]]) for _ in range(p[1]))
    if p[0] == "an-crc":
        # GitHub's checksum: the last six are the base62 CRC-32 of the rest.
        # Drawn at full length first, so every later stand-in is unchanged.
        n, c = zlib.crc32(s[:-6].encode()), ""
        for _ in range(6):
            n, d = divmod(n, 62)
            c = B62[d] + c
        s = s[:-6] + c
    return s


def gen(spec, r):
    while True:
        s = "".join(part(p, r) for p in spec)
        if stand_in_ok(s):
            return s


GUID = [("hex", 8), "-", ("hex", 4), "-", ("hex", 4), "-", ("hex", 4), "-", ("hex", 12)]
# id: (text before the match on its line, the match's parts)
SPECS = {
 "private-key": ("KEY=", ["-----BEGIN RSA ", "PRIVATE KEY-----"]),
 "putty-private-key": ("", ["PuTTY-User-", "Key-File-3:"]),
 "aws-access-key-id": ("KEY=", ["AK", "IA", ("UD", 16)]),
 "github-token": ("KEY=", ["gh", "p_", ("an-crc", 36)]),
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
 "azure-cask-key": ("KEY=", [("an", 52), "JQ", "QJ99", ("an", 1), ("AL", 1), ("an", 16), ("a", 1), ("an", 7)]),
 "azure-identifiable-key": ("KEY=", [("b64", 33), "+AE", "h", ("AP", 1), ("b64", 5), "="]),
 "nuget-key": ("KEY=", ["oy", "2", ("b32", 43)]),
 "cloudflare-api-token": ("KEY=", ["cf", "ut_", ("an", 48)]),
 "circleci-token": ("KEY=", ["CCIP", "AT_", ("b58", 22), "_", ("hex", 40)]),
 "replicate-token": ("KEY=", ["r8", "_", ("an", 37)]),
 "sourcegraph-token": ("KEY=", ["sg", "p_", ("hex", 16), "_", ("hex", 40)]),
 "docker-swarm-token": ("KEY=", ["SWM", "TKN-1-", ("lan", 50), "-", ("lan", 25)]),
 "aws-secret-access-key": ("", ["aws", "_secret_access_key = ", ("b64", 40)]),
 "url-password": ("URL=", ["post", "gres://app:", ("an", 14), ("d", 1), ("a", 1), "@"]),
 "generic-secret": ("", ["api", "_key = \"", ("an", 30), ("d", 1), ("a", 1)]),
 "http-basic-auth": ("", ["Authori", "zation: Basic ", ("basic", ["svc:", ("an", 18), ("d", 1), ("a", 1)])]),
 "http-bearer-token": ("", ["Authori", "zation: Bearer ", ("an", 30), ("d", 1), ("a", 1)]),
 "curl-user-password": ("", ["cu", "rl -u deploy:", ("an", 14), ("d", 1), ("a", 1)]),
 "xml-key-value": ("", ['<add key="ClearText', 'Password" value="', ("an", 16), ("d", 1), ("a", 1)]),
}


# Every other branch of a rule's alternation, and every other prefix its
# issuer hands out, one spec each: SPECS exercises one branch per rule, and a
# branch nothing exercises can break silently (stage B, v0.11.1: `glc_`,
# `sntrys_`, `fm1_` and `whsec_` with `/` went untested). The corpus harness
# reads these; the suite reads SPECS alone, so its rows stay as they were.
VARIANTS = {
 "aws-access-key-id": [("KEY=", [p, ("UD", 16)]) for p in ("AS" "IA", "AB" "IA", "AC" "CA", "A3" "TX")],
 "github-token": [("KEY=", ["gh", p + "_", ("an-crc", 36)]) for p in "ousr"],
 "gitlab-token": [("KEY=", ["gl", p + "-", ("an-_", 26)]) for p in
                  ("ptt", "rt", "dt", "soat", "cbt", "ft", "imt", "agent", "oas")]
                 + [("KEY=", ["GR13", "48941", ("an-_", 20)])],
 "slack-token": [("KEY=", ["xo", "x" + p + "-", ("d", 12), "-", ("d", 13), "-", ("an", 32)]) for p in "paeors"]
                + [("KEY=", ["xa", "pp-1-", ("UD", 11), "-", ("d", 13), "-", ("hex", 64)])],
 "slack-webhook": [("URL=https://", ["hooks", ".slack-gov.com/services/T", ("UD", 10), "/B", ("UD", 10), "/", ("an", 24)]),
                   ("URL=https://", ["hooks", ".slack.com/workflows/T", ("UD", 10), "/A", ("UD", 10), "/", ("d", 18), "/", ("an", 24)]),
                   ("URL=https://", ["hooks", ".slack.com/triggers/T", ("UD", 10), "/", ("d", 13), "/", ("hex", 32)])],
 "discord-webhook": [("URL=https://", ["discord", "app.com/api/webhooks/", ("d", 19), "/", ("an-_", 68)]),
                     ("URL=https://", ["discord", ".com/api/v10/webhooks/", ("d", 19), "/", ("an-_", 68)])],
 "teams-webhook": [("URL=https://acme", [".webhook", ".office.com/webhookb2/"] + GUID + ["@"] + GUID
                    + ["/IncomingWebhook/", ("hex", 32), "/"] + GUID + ["/V2", ("an-_", 44)]),
                   ("URL=https://", ["outlook", ".office.com/webhook/"] + GUID + ["@"] + GUID
                    + ["/IncomingWebhook/", ("hex", 32), "/"] + GUID)],
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


# Formats each issuer documents that the rules missed until v0.12.0 (stage
# B′, re-sourced from the issuers), and every other branch of a rule added
# since: the suite reads these too (`credential_specs.py --variants`), one
# line each, and each must hit its own rule exactly once.
ISSUER_VARIANTS = {
 "github-token": [("KEY=", ["gh", "r_", ("an", 76)])],
 "npm-token": [("KEY=", ["np", "m_", ("an", 40)])],
 "groq-key": [("KEY=", ["gs", "k_", ("an", 56)])],
 "perplexity-key": [("KEY=", ["pp", "lx-", ("an", 52)])],
 "xai-key": [("KEY=", ["xa", "i-", ("an", 84)])],
 "gitlab-token": [("KEY=", ["gl", p + "-", ("an-_", 26)]) for p in ("rtr", "rct", "ffct", "wt", "iamrt", "iamac")],
 "slack-token": [("KEY=", ["xw", "fp-", ("d", 12), "-", ("d", 13), "-", ("an", 32)])],
 "stripe-key": [("KEY=", ["sk", "_org_", ("an", 40)])],
 "webhook-signing-secret": [("KEY=", ["wh", "sk_", ("b64", 86), "=="])],
 "google-api-key": [("KEY=", ["AQ", ".Ab8R", ("an-_", 46)])],
 "pypi-token": [("KEY=", ["pypi-", "AgEObG9jYWxob3N0", ("an-_", 90)])],
 "shopify-token": [("KEY=", ["shp", "at_", ("an", 32)])],
 "jwt": [("KEY=", ["gh", "s_", ("d", 7), "_", "eyJhbGciOiJSUzI1NiJ9", ".", "eyJ", ("an", 200), ".", ("an-_", 342)])],
 "age-secret-key": [("KEY=", ["AGE-", "SECRET-KEY-PQ-1", ("bech", 58)])],
 "vault-token": [("KEY=", ["hv", "r.", ("an", 24)]), ("KEY=", ["hv", "s.", ("an", 24)])],
 "terraform-cloud-token": [("KEY=", [("an", 14), ".hc", "p.", ("an-_", 50)])],
 "doppler-token": [("KEY=", ["dp", ".said.", ("an", 43)]), ("KEY=", ["dp", ".st.", ("lan", 10), ".", ("an", 43)])],
 "linear-api-key": [("KEY=", ["lin", "_oauth_", ("an", 40)])],
 "sentry-token": [("KEY=", ["sntr", "yc_", ("b64", 120), "_", ("b64", 43)]),
                  ("KEY=", ["sntr", "ys_", ("b64", 120), "_", ("b64", 43)]),
                  ("KEY=", ["sntr", "yh_", ("an-_", 43)])]
                 + [("KEY=", ["sntr", "y" + p + "_", ("hex", 64)]) for p in "ai"],
 "databricks-token": [("KEY=", [p, ("hexh", 32)]) for p in ("do" "se", "dsa" "pi", "dk" "ea")],
 "atlassian-token": [("KEY=", ["ATA", "TT3", ("an-_", 102)])],
 "notion-token": [("KEY=", ["nt", "n_", ("an", 46)]), ("KEY=", ["sec", "ret_", ("an", 43)])],
 "1password-token": [("KEY=", ["ops", "_eyJ", ("an-_", 140)])],
 "dynatrace-token": [("KEY=", ["dt0", "s01.", ("UD", 24), ".", ("UD", 64)])],
 "heroku-key": [("KEY=", ["HRKU", "-"] + GUID), ("KEY=", ["HRKU", "-", ("an-_", 60)])],
 "supabase-key": [("KEY=", ["sb", "p_" + p + "_", ("hex", 40)]) for p in ("oauth", "v0")],
 "azure-storage-key": [("X;", ["Storage", "Key = ", ("b64", 86), "=="]), ("X;", ["account", "key=", ("b64", 86), "=="]),
                       ("KEY=", [("b64", 76), "+AS", "t", ("b64", 5), "Q=="])],
 "azure-ad-client-secret": [("KEY=", ["a-", ("an", 1), "8", "Q", "~", ("an", 34)])],
 "new-relic-key": [("KEY=", ["NR", "AK-", ("an", 27)]), ("KEY=", ["NR", "AA-", ("UD", 27)]),
                   ("KEY=", ["NR", "IQ-", ("an-_", 32)]), ("KEY=", ["NR", "RA-", ("hex", 42)]),
                   ("KEY=", ["NR", "SP-", ("a", 2), ("hex", 33)]), ("KEY=", [("hex", 36), "NR", "AL"]),
                   ("KEY=", ["eu01", "xx", ("hex", 30), "NR", "AL"])],
 "mapbox-secret-token": [("KEY=", ["tk", ".eyJ", ("an-_", 80)]), ("KEY=", ["sk", ".eyJh", ("an-_", 80)])],
 "azure-cask-key": [("KEY=", [("an", 52), "JQ", "QJ9" + c, ("an", 1), ("AL", 1), ("an", 16), ("a", 1), ("an", 9), "=="])
                    for c in "9DH"],
 "azure-identifiable-key": [("KEY=", [("b64", 76), s[:2], s[2:], ("b64", 5), ("AQgw", 1), "=="])
                            for s in ("ACDb", "+ABa", "+AMC", "APIM")]
                           + [("KEY=", [("b64", 33), s[:2], s[2:], ("AP", 1), ("b64", 5), "="])
                              for s in ("+ASb", "+ARm", "AIoT", "AzCa", "AZEG")]
                           + [("KEY=", [("b64", 42), "+A", "CR", ("AD", 1), ("b64", 5)]),
                              ("KEY=", [("an", 42), "Az", "Se", ("AD", 1), ("an", 5)]),
                              ("KEY=", [("an-_", 44), "Az", "Fu", ("an-_", 5), ("AQgw", 1), "=="])],
 "nuget-key": [("KEY=", ["OY", "2", ("b32U", 43)])],
 "cloudflare-api-token": [("KEY=", ["cf", p + "_", ("an", 48)]) for p in ("at", "k", "ast")],
 "circleci-token": [("KEY=", ["CCIP", "RJ_", ("b58", 21), "_", ("hex", 40)])],
 "sourcegraph-token": [("KEY=", ["sg", "p_lo" "cal_", ("hex", 40)]), ("KEY=", ["sg", "p_", ("hex", 40)])]
                      + [("KEY=", [p[0], p[1:] + "_", ("hex", 64)]) for p in ("sgd", "slk", "sgs")],
 "docker-swarm-token": [("KEY=", ["SWM", "TKN-2-1-", ("lan", 50), "-", ("lan", 25)]),
                        ("KEY=", ["SWM", "KEY-1-", ("b64", 43)])],
}


# Path rules match a tracked file's NAME, never content: each stand-in is a
# path that rule alone finds, as an empty file.
PATH_SPECS = {
    "pkcs12-file": ["certs/client.p12", "Server.PFX", "deploy/keys/signing.Pfx", "a b/key.P12"],
}


# One stand-in per rule whose body takes `/` (bin/leakcheck's CRED_SLASH),
# from the branch that takes it: rule id -> its index in variants(), or a
# spec. glc_ unpadded: a padded key's match ends at its `==`, before any
# tail, so the padded variant tests nothing here.
SLASH = {"webhook-signing-secret": 1, "grafana-token": ["gl", "c_", ("b64", 64)], "sentry-token": 3,
         "1password-token": 0, "flyio-token": 2, "jwt": 0}


def variants(cid):
    """Every spec of a rule, SPECS' first."""
    return [SPECS[cid]] + VARIANTS.get(cid, []) + ISSUER_VARIANTS.get(cid, [])


def suite_rows():
    """(rule id, the line holding the stand-in, the exact match), one per
    rule, in table order, from the suite's fixed seed: the rows the suite has
    always read, byte for byte."""
    r = random.Random(20261105)
    for cid, (before, spec) in SPECS.items():
        m = gen(spec, r)
        yield cid, before + m, m


def slash_rows():
    """(rule id, stand-in), one per SLASH rule, seeded."""
    r = random.Random(20261117)
    for cid, i in SLASH.items():
        yield cid, gen(variants(cid)[i][1] if isinstance(i, int) else i, r)


def issuer_rows():
    """(rule id, line, match), one per ISSUER_VARIANTS spec, seeded."""
    r = random.Random(20261116)
    for cid, vs in ISSUER_VARIANTS.items():
        for before, spec in vs:
            m = gen(spec, r)
            yield cid, before + m, m


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--slash"]:
        for cid, m in slash_rows():
            print(cid, m, sep="\t")
        sys.exit(0)
    if sys.argv[1:] == ["--paths"]:
        for cid, names in PATH_SPECS.items():
            for name in names:
                print(cid, name, sep="\t")
        sys.exit(0)
    rows = issuer_rows() if sys.argv[1:] == ["--variants"] else suite_rows()
    for cid, line, m in rows:
        print(cid, line, m, sep="\t")

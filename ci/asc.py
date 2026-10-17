#!/usr/bin/env python3
"""Stem Eye CI -- the App Store Connect API, standard library only (ES256 signed by the openssl on the Mac).

  asc.py ids  <bundle id> <name> [<bundle id> <name> ...]   register the app ids that are missing
  asc.py app  <bundle id>                                     is there an App Store Connect app record for it?

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file). Exit 0 = fine, 1 = something to fix (said in plain words).
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_rs(der):
    """an ECDSA signature in DER (SEQUENCE {INTEGER r, INTEGER s}) -> r, s"""
    if der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("bad DER integer")
        n = der[i + 1]
        out.append(int.from_bytes(der[i + 2:i + 2 + n], "big"))
        i += 2 + n
    return out


def token():
    kid, iss, path = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID"), os.environ.get("ASC_KEY_PATH")
    if not (kid and iss and path and os.path.exists(path)):
        sys.exit("asc.py: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) are needed")
    now = int(time.time())
    head = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    body = {"iss": iss, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    si = b64u(json.dumps(head, separators=(",", ":")).encode()) + "." + b64u(json.dumps(body, separators=(",", ":")).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=si.encode(), capture_output=True, check=True).stdout
    r, s = der_rs(der)
    return si + "." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def call(method, path, tok, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode("utf8", "replace")}


def errors(j):
    return "; ".join((e.get("title", "") + ": " + e.get("detail", "")) for e in j.get("errors", [])) or json.dumps(j)[:300]


def bundle_exists(tok, ident):
    code, j = call("GET", "/bundleIds?" + urllib.parse.urlencode({"filter[identifier]": ident, "limit": "200"}), tok)
    if code == 401:
        sys.exit("App Store Connect refused the API key (401): check ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8")
    if code != 200:
        sys.exit("App Store Connect: could not list app ids (%d): %s" % (code, errors(j)))
    return any(d.get("attributes", {}).get("identifier") == ident for d in j.get("data", []))


def cmd_ids(pairs):
    tok = token()
    for ident, name in pairs:
        if bundle_exists(tok, ident):
            print("app id %s: already registered" % ident)
            continue
        code, j = call("POST", "/bundleIds", tok, {"data": {"type": "bundleIds", "attributes": {"identifier": ident, "name": name, "platform": "IOS"}}})
        if code in (200, 201):
            print("app id %s: registered (%s)" % (ident, name))
        elif code == 409 and bundle_exists(tok, ident):
            print("app id %s: already registered" % ident)
        else:
            sys.exit("app id %s: Apple said %d: %s" % (ident, code, errors(j)))


def cmd_app(ident):
    tok = token()
    code, j = call("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": ident}), tok)
    if code != 200:
        sys.exit("App Store Connect: could not list apps (%d): %s" % (code, errors(j)))
    apps = [d for d in j.get("data", []) if d.get("attributes", {}).get("bundleId") == ident]
    if apps:
        a = apps[0]["attributes"]
        print("App Store Connect app: %s (%s)" % (a.get("name"), ident))
        return 0
    print("::error::No App Store Connect app for %s yet. Make it once: App Store Connect > Apps > + > New App > iOS, "
          "any name (e.g. 'Stem Eye'), bundle ID %s, SKU stemeye. Then run this workflow again." % (ident, ident))
    return 1


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "ids" and len(sys.argv) % 2 == 0:
        cmd_ids(list(zip(sys.argv[2::2], sys.argv[3::2])))
    elif len(sys.argv) == 3 and sys.argv[1] == "app":
        sys.exit(cmd_app(sys.argv[2]))
    else:
        sys.exit(__doc__)

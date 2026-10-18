"""External TestFlight: one public-link group for Ate.

  status      print the app's TestFlight state (read-only)
  setup       create/refresh the external group, beta app info and review details,
              then distribute the latest build (idempotent)
  distribute  add the newest processed build to the group and submit it for beta review
  auto        what a push runs: status, then setup once the TF_CONTACT_PHONE secret exists

Auth: the same App Store Connect API key the Beta workflow uploads with
(ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8). Copy and contact fields come from env;
the contact phone is a repo secret so it stays out of this public repo.
"""
import base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request

import jwt  # PyJWT[crypto]

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.eamongracias.ate"
GROUP_NAME = "Public link"


def key_pem():
    raw = os.environ["ASC_KEY_P8"]
    if "BEGIN PRIVATE KEY" in raw:
        return raw
    return base64.b64decode("".join(raw.split())).decode()


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
        key_pem(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None, params=None):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        print(f"::error::{method} {path} -> {e.code}: {e.read().decode()}")
        raise SystemExit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"::error::{name} is empty")
    return v


def app():
    data = call("GET", "/v1/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not data:
        sys.exit(f"::error::No App Store Connect app for {BUNDLE_ID}")
    return data[0]


def group(app_id):
    for g in call("GET", f"/v1/apps/{app_id}/betaGroups", params={"limit": 200})["data"]:
        if g["attributes"]["name"] == GROUP_NAME:
            return g
    return None


def builds(app_id, limit=5, version=None):
    params = {"filter[app]": app_id, "sort": "-uploadedDate", "limit": limit, "include": "buildBetaDetail"}
    if version:
        params["filter[version]"] = version
    return call("GET", "/v1/builds", params=params)


def summary(text):
    print(text)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as f:
        f.write(text + "\n")


def status():
    a = app()
    app_id = a["id"]
    print("app", app_id, json.dumps(a["attributes"]))
    for g in call("GET", f"/v1/apps/{app_id}/betaGroups", params={"limit": 200})["data"]:
        print("group", g["id"], json.dumps(g["attributes"]))
    detail = call("GET", f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]["attributes"]
    print("review detail", json.dumps({k: (bool(v) if k in ("contactPhone", "demoAccountPassword") else v)
                                       for k, v in detail.items()}))
    for loc in call("GET", f"/v1/apps/{app_id}/betaAppLocalizations")["data"]:
        print("beta app localization", json.dumps(loc["attributes"]))
    b = builds(app_id)
    details = {d["id"]: d["attributes"] for d in b.get("included", [])}
    for x in b["data"]:
        at = x["attributes"]
        bd = details.get(x["relationships"]["buildBetaDetail"]["data"]["id"], {})
        print("build", at["version"], at["processingState"], "expired" if at["expired"] else "",
              "encryption:", at.get("usesNonExemptEncryption"), "external:", bd.get("externalBuildState"))


def setup():
    a = app()
    app_id, locale = a["id"], a["attributes"]["primaryLocale"]

    info = {
        "description": env("TF_DESCRIPTION"),
        "feedbackEmail": env("TF_CONTACT_EMAIL"),
        "privacyPolicyUrl": env("TF_PRIVACY_URL"),
    }
    locs = call("GET", f"/v1/apps/{app_id}/betaAppLocalizations")["data"]
    mine = next((l for l in locs if l["attributes"]["locale"] == locale), None)
    if mine:
        call("PATCH", f"/v1/betaAppLocalizations/{mine['id']}",
             {"data": {"type": "betaAppLocalizations", "id": mine["id"], "attributes": info}})
    else:
        call("POST", "/v1/betaAppLocalizations", {"data": {
            "type": "betaAppLocalizations", "attributes": {"locale": locale, **info},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    print("beta app info set for", locale)

    detail = call("GET", f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]
    call("PATCH", f"/v1/betaAppReviewDetails/{detail['id']}", {"data": {
        "type": "betaAppReviewDetails", "id": detail["id"], "attributes": {
            "contactFirstName": env("TF_CONTACT_FIRST"), "contactLastName": env("TF_CONTACT_LAST"),
            "contactPhone": env("TF_CONTACT_PHONE"), "contactEmail": env("TF_CONTACT_EMAIL"),
            "demoAccountRequired": False, "notes": env("TF_REVIEW_NOTES")}}})
    print("beta review details set")

    g = group(app_id)
    attrs = {"publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True}
    if g:
        call("PATCH", f"/v1/betaGroups/{g['id']}", {"data": {"type": "betaGroups", "id": g["id"], "attributes": attrs}})
    else:
        call("POST", "/v1/betaGroups", {"data": {
            "type": "betaGroups", "attributes": {"name": GROUP_NAME, **attrs},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    print("group ready")
    distribute()


def distribute():
    a = app()
    app_id, locale = a["id"], a["attributes"]["primaryLocale"]
    g = group(app_id)
    if not g:
        print("::notice::No public-link group yet; nothing to distribute")
        return
    # TF_BUILD_NUMBER picks the build Beta just uploaded; it can take a while to appear and
    # process, so wait up to TF_WAIT_SECONDS. Without it, the newest build is used.
    version = os.environ.get("TF_BUILD_NUMBER", "").strip() or None
    deadline = time.time() + int(os.environ.get("TF_WAIT_SECONDS") or "0")
    while True:
        found = builds(app_id, 1, version)["data"]
        latest = found[0] if found else None
        if (latest and latest["attributes"]["processingState"] == "VALID") or time.time() > deadline:
            break
        print("waiting for build", version or "", latest and latest["attributes"]["processingState"])
        time.sleep(60)
    if not latest:
        sys.exit(f"::error::Build {version} never appeared in App Store Connect")
    at = latest["attributes"]
    if at["processingState"] != "VALID" or at["expired"]:
        sys.exit(f"::error::Build {at['version']} is {at['processingState']}; not distributing")
    build_id = latest["id"]

    call("POST", f"/v1/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": build_id}]})
    whats_new = os.environ.get("TF_WHATS_NEW", "").strip()
    if whats_new:
        bl = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
        mine = next((l for l in bl if l["attributes"]["locale"] == locale), None)
        if mine:
            call("PATCH", f"/v1/betaBuildLocalizations/{mine['id']}", {"data": {
                "type": "betaBuildLocalizations", "id": mine["id"], "attributes": {"whatsNew": whats_new}}})
        else:
            call("POST", "/v1/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": whats_new},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})

    state = call("GET", f"/v1/builds/{build_id}/buildBetaDetail")["data"]["attributes"].get("externalBuildState")
    if state == "READY_FOR_BETA_SUBMISSION":
        call("POST", "/v1/betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        state = "submitted for beta review"
    g = group(app_id)["attributes"]
    summary(f"### External TestFlight\n\n- build {at['version']}: {state}\n"
            f"- public link: {g.get('publicLink')} (enabled: {g.get('publicLinkEnabled')})")


def auto():
    status()
    if os.environ.get("TF_CONTACT_PHONE", "").strip():
        setup()
    else:
        print("::warning::TF_CONTACT_PHONE secret not set; setup skipped")


if __name__ == "__main__":
    {"status": status, "setup": setup, "distribute": distribute, "auto": auto}[sys.argv[1]]()

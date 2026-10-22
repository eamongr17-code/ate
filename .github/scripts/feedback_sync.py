"""Feedback sync: tester reports → issues in the private repo eamongr17-code/ate-feedback.

What the hourly Feedback workflow runs. Two sources, one inbox:

  app         rows in public.feedback with status 'new' (the bug button's sheet, 0082). Each one's
              screenshots are copied into the repo, then deleted from the private bucket.
  testflight  TestFlight's own screenshot and crash feedback, read through the App Store Connect API
              with the key the Beta workflow uploads with. Skipped when the ASC_* secrets are absent.

Every report becomes one issue labelled triage:new, unless the same tester sent the same words in the
last 14 days and that issue is still open: then it is a comment on that issue. The triage task
(a scheduled Claude session) takes it from there.

Env: SUPABASE_ACCESS_TOKEN, PROJECT_REF, FEEDBACK_GITHUB_TOKEN, FEEDBACK_REPO (owner/name),
     optionally ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, and ENV_LABEL (e.g. "staging").
Nothing here changes the schema; it only reads new reports and marks them filed.
"""
import base64, datetime, json, os, sys, time, urllib.error, urllib.parse, urllib.request

BUNDLE_ID = "com.eamongracias.ate"
BUCKET = "feedback-screenshots"
BATCH = 50  # reports per run; the hourly schedule drains a backlog in a few runs


class HTTPFail(Exception):
    def __init__(self, code, text):
        super().__init__(f"{code}: {text[:300]}")
        self.code = code


def http(method, url, headers=None, body=None, raw=False):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    req = urllib.request.Request(url, method=method, data=data)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if body is not None and not isinstance(body, bytes):
        req.add_header("Content-Type", "application/json")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                payload = r.read()
                if raw:
                    return payload
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            if e.code >= 500 and attempt < 2:
                time.sleep(2 ** attempt)
                continue
            raise HTTPFail(e.code, text)
        except urllib.error.URLError:
            if attempt < 2:
                time.sleep(2 ** attempt)
                continue
            raise


# ---------------------------------------------------------------------------- Supabase


class Supabase:
    def __init__(self, ref, access_token):
        keys = http("GET", f"https://api.supabase.com/v1/projects/{ref}/api-keys?reveal=true",
                    {"Authorization": f"Bearer {access_token}"})
        key = next((k["api_key"] for k in keys if k.get("name") == "service_role"), None) \
            or next((k["api_key"] for k in keys if k.get("type") == "secret"), None)
        if not key:
            sys.exit("::error::No service key on the project")
        print(f"::add-mask::{key}")
        self.base = f"https://{ref}.supabase.co"
        self.h = {"apikey": key, "Authorization": f"Bearer {key}"}

    def rest(self, method, path, body=None, prefer=None):
        h = dict(self.h)
        if prefer:
            h["Prefer"] = prefer
        return http(method, f"{self.base}/rest/v1/{path}", h, body)

    def screenshot(self, path):
        return http("GET", f"{self.base}/storage/v1/object/{BUCKET}/{urllib.parse.quote(path)}", self.h, raw=True)

    def delete_screenshots(self, paths):
        if paths:
            http("DELETE", f"{self.base}/storage/v1/object/{BUCKET}", self.h, {"prefixes": paths})


# ---------------------------------------------------------------------------- GitHub


class Repo:
    def __init__(self, name, token):
        self.name = name
        self.h = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                  "X-GitHub-Api-Version": "2022-11-28"}

    def api(self, method, path, body=None):
        return http(method, f"https://api.github.com/repos/{self.name}{path}", self.h, body)

    def put_file(self, path, content, message):
        try:
            self.api("PUT", f"/contents/{urllib.parse.quote(path)}",
                     {"message": message, "content": base64.b64encode(content).decode()})
        except HTTPFail as e:
            if e.code != 422:  # 422: already there from an earlier, interrupted run
                raise
        return f"https://github.com/{self.name}/blob/HEAD/{path}?raw=true"

    def ensure_labels(self, labels):
        for name, color in labels:
            try:
                self.api("POST", "/labels", {"name": name, "color": color})
            except HTTPFail as e:
                if e.code != 422:
                    raise

    def open_issue(self, title, body, labels):
        return self.api("POST", "/issues", {"title": title, "body": body, "labels": labels})["number"]

    def is_open(self, number):
        return self.api("GET", f"/issues/{number}")["state"] == "open"

    def comment(self, number, body):
        self.api("POST", f"/issues/{number}/comments", {"body": body})


LABELS = [("triage:new", "fbca04"), ("source:app", "1d76db"), ("source:testflight", "5319e7"),
          ("crash", "b60205"), ("staging", "c5def5")]


def title_of(body):
    line = next((l.strip() for l in body.splitlines() if l.strip()), "Feedback")
    return line if len(line) <= 72 else line[:69].rstrip() + "…"


def details(rows):
    out = ["", "| | |", "|---|---|"]
    for k, v in rows:
        if v:
            out.append(f"| {k} | {v} |")
    return "\n".join(out)


def quote(body):
    return "\n".join("> " + l for l in body.splitlines())


# ---------------------------------------------------------------------------- app reports


def sync_app(db, repo, env_labels):
    try:
        rows = db.rest("GET", f"feedback?status=eq.new&source=eq.app&order=created_at.asc&limit={BATCH}"
                              "&select=id,user_id,body,screenshots,build,device,os_version,screens,fingerprint,created_at")
    except HTTPFail as e:
        if e.code == 404:  # 0082 not applied to this database yet
            print("::notice::feedback table not there yet (Prod apply pending)")
            return None
        raise
    if not rows:
        print("app: nothing new")
        return 0
    ids = ",".join(sorted({r["user_id"] for r in rows}))
    handles = {p["id"]: p.get("username") for p in db.rest("GET", f"profiles?id=in.({ids})&select=id,username")}
    since = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=14)).isoformat()
    filed = 0
    for r in rows:
        try:
            links = []
            for i, path in enumerate(r["screenshots"], 1):
                ext = path.rsplit(".", 1)[-1].lower() if "." in path else "jpg"
                links.append(repo.put_file(f"screenshots/{r['id']}/{i}.{ext}", db.screenshot(path),
                                           f"Screenshot {i} for feedback {r['id']}"))
            who = handles.get(r["user_id"])
            meta = details([("From", f"@{who}" if who else r["user_id"][:8]), ("Build", r["build"]),
                            ("Device", r["device"]), ("iOS", r["os_version"]), ("Sent", r["created_at"][:16].replace("T", " ") + " UTC"),
                            ("Last screens", " → ".join(r["screens"][-8:]))])
            shots = "\n".join(f"![screenshot {i}]({u})" for i, u in enumerate(links, 1))
            text = f"{quote(r['body'])}\n{meta}\n\n{shots}\n\n<!-- feedback:{r['id']} -->"

            # the same tester, the same words, an issue still open: one more voice on it
            prior = db.rest("GET", f"feedback?fingerprint=eq.{r['fingerprint']}&status=eq.filed"
                                   f"&created_at=gte.{urllib.parse.quote(since)}&order=created_at.desc&limit=1&select=issue_number")
            number = prior[0]["issue_number"] if prior and prior[0].get("issue_number") else None
            if number and repo.is_open(number):
                repo.comment(number, "Sent again:\n\n" + text)
            else:
                number = repo.open_issue(title_of(r["body"]), text, ["triage:new", "source:app", *env_labels])

            repo_paths = [u.split("/blob/HEAD/")[1].split("?")[0] for u in links]
            db.rest("PATCH", f"feedback?id=eq.{r['id']}",
                    {"status": "filed", "issue_number": number, "screenshots": repo_paths,
                     "filed_at": datetime.datetime.now(datetime.timezone.utc).isoformat()})
            db.delete_screenshots(r["screenshots"])
            filed += 1
            print(f"app: {r['id']} → #{number}")
        except (HTTPFail, urllib.error.URLError) as e:
            # left as 'new': the next run tries it again
            print(f"::warning::feedback {r['id']} not filed: {e}")
    return filed


# ---------------------------------------------------------------------------- TestFlight


def asc_token():
    import jwt  # PyJWT[crypto]
    raw = os.environ["ASC_KEY_P8"]
    pem = raw if "BEGIN PRIVATE KEY" in raw else base64.b64decode("".join(raw.split())).decode()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      pem, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def sync_testflight(db, repo, env_labels):
    if not all(os.environ.get(k) for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8")):
        print("testflight: no App Store Connect key, skipped")
        return 0
    h = {"Authorization": "Bearer " + asc_token()}
    asc = lambda path, params=None: http("GET", "https://api.appstoreconnect.apple.com" + path
                                         + ("?" + urllib.parse.urlencode(params) if params else ""), h)
    apps = asc("/v1/apps", {"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        print("::warning::testflight: app not found")
        return 0
    app_id = apps[0]["id"]
    subs = []
    for kind in ("betaFeedbackScreenshotSubmissions", "betaFeedbackCrashSubmissions"):
        try:
            res = asc(f"/v1/apps/{app_id}/{kind}", {"limit": 50, "include": "build", "fields[builds]": "version"})
        except HTTPFail as e:
            print(f"::warning::testflight: {kind} unreadable ({e})")
            continue
        builds = {b["id"]: b["attributes"].get("version") for b in res.get("included", []) if b.get("type") == "builds"}
        for s in res.get("data", []):
            bid = ((s.get("relationships", {}).get("build") or {}).get("data") or {}).get("id")
            subs.append((kind, s, builds.get(bid)))
    if not subs:
        print("testflight: nothing")
        return 0
    known = set()
    ext = [s["id"] for _, s, _ in subs]
    for i in range(0, len(ext), 40):
        chunk = ",".join(urllib.parse.quote(x) for x in ext[i:i + 40])
        known |= {r["external_id"] for r in db.rest("GET", f"feedback?external_id=in.({chunk})&select=external_id")}
    filed = 0
    for kind, s, build in subs:
        if s["id"] in known:
            continue
        a = s.get("attributes", {})
        crash = kind == "betaFeedbackCrashSubmissions"
        try:
            paths, links = [], []
            for i, shot in enumerate(a.get("screenshots") or [], 1):
                url = shot.get("url")
                if not url:
                    continue
                path = f"testflight/{s['id']}/{i}.png"
                links.append(repo.put_file(path, http("GET", url, raw=True), f"TestFlight screenshot {i}"))
                paths.append(path)
            log_link = None
            if crash:
                try:
                    log = asc(f"/v1/betaFeedbackCrashSubmissions/{s['id']}/crashLog")["data"]["attributes"].get("logText")
                    if log:
                        log_link = repo.put_file(f"testflight/{s['id']}/crash.txt", log.encode(), "TestFlight crash log")
                except HTTPFail as e:
                    print(f"::warning::crash log {s['id']}: {e}")
            body = (a.get("comment") or "").strip() or ("(crash, no comment)" if crash else "(no comment)")
            meta = details([("From", "TestFlight tester"), ("Build", build), ("Device", a.get("deviceModel")),
                            ("iOS", a.get("osVersion")), ("Sent", (a.get("createdDate") or "")[:16].replace("T", " ")),
                            ("Battery", f"{a['batteryPercentage']}%" if a.get("batteryPercentage") is not None else None),
                            ("Connection", a.get("connectionType"))])
            extra = "\n".join(f"![screenshot {i}]({u})" for i, u in enumerate(links, 1))
            if log_link:
                extra += f"\n\n[Crash log]({log_link.replace('?raw=true', '')})"
            text = f"{quote(body)}\n{meta}\n\n{extra}\n\n<!-- testflight:{s['id']} -->"
            title = ("Crash: " if crash else "") + title_of(body)
            labels = ["triage:new", "source:testflight", *(["crash"] if crash else []), *env_labels]
            number = repo.open_issue(title, text, labels)
            db.rest("POST", "feedback", {
                "source": "testflight", "external_id": s["id"], "body": body[:4000], "screenshots": paths,
                "build": build, "device": a.get("deviceModel"), "os_version": a.get("osVersion"),
                "fingerprint": "testflight:" + s["id"], "status": "filed", "issue_number": number,
                "filed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            }, prefer="resolution=ignore-duplicates")
            filed += 1
            print(f"testflight: {s['id']} → #{number}")
        except (HTTPFail, urllib.error.URLError) as e:
            print(f"::warning::testflight {s['id']} not filed: {e}")
    return filed


def main():
    for k in ("SUPABASE_ACCESS_TOKEN", "PROJECT_REF", "FEEDBACK_GITHUB_TOKEN", "FEEDBACK_REPO"):
        if not os.environ.get(k, "").strip():
            sys.exit(f"::error::{k} is empty")
    env_labels = [os.environ["ENV_LABEL"]] if os.environ.get("ENV_LABEL") else []
    db = Supabase(os.environ["PROJECT_REF"], os.environ["SUPABASE_ACCESS_TOKEN"])
    repo = Repo(os.environ["FEEDBACK_REPO"], os.environ["FEEDBACK_GITHUB_TOKEN"])
    repo.ensure_labels(LABELS)
    n = sync_app(db, repo, env_labels)
    if n is None:
        return
    if not env_labels:  # TestFlight feedback is prod's: Beta builds point at prod
        n += sync_testflight(db, repo, env_labels)
    print(f"filed {n}")


if __name__ == "__main__":
    main()
